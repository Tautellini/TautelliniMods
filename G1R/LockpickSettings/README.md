# LockpickSettings

Makes Gothic 1 Remake lockpicking much easier with the least possible
machinery. Deployed into the game as UE4SS Lua mod `EasyLockpicking`
(historical name, see deploy mapping in `tools/deploy.ps1`).

## Current state: v8 "bare minimum"

- One behavior, configured at mod load via `Scripts/config.lua`:
  every time the lockpicking minigame starts, `LockpickDurability` is
  raised to at least `minTries` (default 14 = vanilla Untrained 4 + 10)
- The write is idempotent: if durability is already at or above the floor,
  nothing happens. Values can never stack or run away across sessions,
  saves or reloads, so no restore pass is needed
- Removed in v8 (freeze/crash suspects from v7.1): the `LoopAsync`
  session watcher, all `RegisterKeyBind` hotkeys, `ExecuteInGameThread`
  deferrals, the end-of-minigame restore
- Trade-off vs v7.1: the floored durability value (14) does get written
  to BaseValue and will appear in saves. Harmless, but a save made with
  the mod is no longer byte-identical to a vanilla one
- Config changes need a game restart (no hot reload, no hotkeys)

## Parked / future

- Connection thinning (fewer coupled levels): not reachable from Lua,
  needs a C++ MinHook detour on the `GothicLockConfig::AddConnection` exec
  body. Alternative with small save footprint: clamp chest
  `m_LockDifficulty` so easier lock templates get assigned on first pick

## History

v1-v2 diagnostics, v3 stat curve (rejected: stats), v4-v6 difficulty clamp
(rejected: wants generated-lock easing), v7 research (found the AS hook
crash + that locks are never saved), v7.1 tries-only with transient
boost+restore (froze/crashed: polling watcher + hotkeys), v8 bare-minimum
idempotent floor (current). v7 spec: SPEC.md (historical)
