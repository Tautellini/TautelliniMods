# LockpickSettings

Makes Gothic 1 Remake lockpicking easier without touching anything the game
persists. Deployed into the game as UE4SS Lua mod `EasyLockpicking`
(historical name, see deploy mapping in `tools/deploy.ps1`).

## Current state: v7.1 "tries only"

- When the lockpicking minigame starts, `LockpickDurability` is raised to
  vanilla + extraTries; when it ends, the exact vanilla value is restored.
  Saves and stored stats stay 100% vanilla
- Config in `Scripts/config.lua`: `extraTriesByVanilla` (per skill tier,
  keyed by the tier's vanilla durability; only Untrained = 4 known so far)
  and `extraTriesDefault` for unknown tiers
- Keys ingame: CTRL+ALT+F6 status, CTRL+R hot-reload after config edits

## Parked / future

- Connection thinning (fewer coupled levels): not reachable from Lua,
  needs a C++ MinHook detour on the `GothicLockConfig::AddConnection` exec
  body. Alternative with small save footprint: clamp chest
  `m_LockDifficulty` so easier lock templates get assigned on first pick
- Tier values for Skilled/Master durability: unknown, the mod logs them
  when encountered ("unknown tier" log line), then add to config

## History

v1-v2 diagnostics, v3 stat curve (rejected: stats), v4-v6 difficulty clamp
(rejected: wants generated-lock easing), v7 research (found the AS hook
crash + that locks are never saved), v7.1 tries-only (current).
Full spec: SPEC.md
