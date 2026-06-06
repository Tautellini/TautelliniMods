# EasyLockpicking v7 — Transient Lock Easing

Spec agreed 2026-06-06. Supersedes the v6 difficulty-clamp approach, which is to be removed.

## Goal

Make the Gothic 1 Remake lockpicking minigame easier without changing anything the game persists. In the user's words: "We dont really want to patch destrucitvely, but instead we need to make sure that generated locks are easier to solve, by reducing the maximum connections and boosting up the accepted failures before a lockpick breaks."

## Scope

**In:**
1. **Connection thinning** — locks keep their vanilla generated structure in the save, but each minigame session transiently disables a fraction of the level-to-level couplings. "Scale down relatively" with a config value driving the kept fraction.
2. **Failure budget** — more accepted failures before the lockpick breaks, applied transiently per lock attempt. Never written to savegames (user: persistence was the problem with stat changes, not the mechanism).
3. Both values **scale with skill tier** (Untrained gets the most help, Master the least), so skill progression keeps mattering.
4. Configuration via `Scripts/config.lua` + CTRL+R hot reload. User: "Config file is enough after all."

**Out:**
- Visual highlighting of connected levels — dropped entirely by user decision.
- In-game menu (UMG/ImGui) — dropped; config file suffices.
- Any modification of player attributes that can persist (no LockpickDurability/Precision writes that survive the minigame).
- Any modification of designer-placed world data (chest `m_LockDifficulty`, quest locks) — the v6 clamp gets removed.

## Hard constraints

- **Saves must stay vanilla.** A savegame produced with the mod installed must be byte-equivalent in lock/stat content to one produced without it. Uninstalling the mod returns every lock and stat to 100% vanilla behavior.
- **Reload stability.** The same chest must present the same (thinned) lock on every reload: thinning must be deterministic, keyed on stable lock identity (e.g. lock name hash + config ratio), never random per session.
- **No polling loops** for the core path; event-driven (existing safe hooks: object construction notify, InitGameState post-hook, native UFunction hooks like the verified ClientRestart pattern). The AngelScript-colliding hooks (ProcessInternal/ProcessLocalScriptFunction/ProcessEvent etc.) stay disabled.

## Phase 1: Feasibility research (go/no-go gate)

The lock runtime data (pieces, connections) has shown **zero reflected properties** so far; only `GothicLockConfig:AddPiece/AddConnection` (native UFunctions, callable/hookable) and the structs `GothicLockPieceData`, `LockConnections`, `LockOneConnection` are known to exist. Before any implementation:

1. Instrument `AddPiece`/`AddConnection` with native pre/post hooks; trigger lock generation in game; learn ID/Rotation/Direction semantics and when generation runs (once per lock vs per minigame session).
2. Dump the live minigame object tree (`LockPickSubsystem.m_PendingLockPieces`, `GothicLockPieceActor`, scene actor) while a lock is open; find where per-session coupling data lives and whether it is writable from Lua.
3. Find the break-decision path (candidates: `AnimNotify_BreakLockPick`, `AbilityTask_LockPick` fail delegates, durability attribute reads) and identify a transient intervention point for the failure budget.
4. Triage the exit crash (UE4SS.log + crash dumps); occurred once so far, user quit normally. Non-blocking, watch it.

**Gate:** If connection thinning is not reachable from Lua, STOP and reassess together (user decision: no fallback shipping; a C++ UE4SS mod is the discussion point then).

## Architecture (post-gate intent)

- UE4SS Lua mod, same install location (`ue4ss/Mods/EasyLockpicking`).
- Connection thinning: deterministic keep/drop per connection at minigame session setup, driven by `keepRatio[tier]`.
- Failure budget: transient bump active only between minigame start and end (task delegates / actor lifecycle), guaranteed restored on session end AND on InitGameState (belt and suspenders against autosave edge cases). If a cancel-free hook point exists that avoids touching the attribute entirely, prefer it.
- Skill tier detection: read which `GE_Skill_Picklock_*` tier is active (or infer from vanilla attribute values 4/1 = current tier baseline) at minigame start.
- v6 code (chest clamp, lock regeneration/migration, CTRL+ALT+F7) is deleted.

## Configuration surface (`Scripts/config.lua`)

```lua
return {
    -- fraction of generated couplings that stay active, per skill tier
    keepRatio = { untrained = 0.4, skilled = 0.6, master = 0.8 },
    -- extra accepted failures before the pick breaks, per skill tier
    extraFailures = { untrained = 6, skilled = 3, master = 1 },
}
```

Defaults above were agreed as the starting point ("Scale with skill tier"). Exact numbers are tunable after playtesting; CTRL+R applies live.

## Performance notes

- No per-frame work. Hooks fire on lock generation / minigame open+close only.
- Native UFunction hooks verified harmless in this game (ClientRestart hook ran through the freeze AND the stable session).

## Open questions

- Where exactly per-session coupling state lives (phase 1 answers this).
- Whether durability can be avoided entirely for the failure budget (preferred) or needs the transient-bump-with-restore pattern.
- Real value range of lock difficulty / tier attribute values for Skilled and Master (only Untrained 4/1 observed so far).
- Exit crash root cause (once so far; UE4SS shutdown order is a known suspect in general).

## Done criteria (v1)

- Picking a previously hard chest shows noticeably fewer coupled levels, identical layout on every reload of the same save.
- Breaking a pick requires (vanilla tolerance + configured extra) failures at the configured tier.
- A save made with the mod active, loaded WITHOUT the mod, shows full-difficulty vanilla locks and vanilla stats (the acid test).
- Config edits apply via CTRL+R without restart.
- No freezes, no new crash patterns across several sessions.
