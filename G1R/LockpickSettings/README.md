# LockpickSettings

Makes Gothic 1 Remake lockpicking much easier with the least possible
machinery. Deployed into the game as UE4SS Lua mod `EasyLockpicking`
(historical name, see deploy mapping in `tools/deploy.ps1`).

## Current state: v8.2 "per-tier"

- One behavior, configured at mod load via `Scripts/config.lua`:
  when the lockpicking minigame starts and `LockpickDurability` is at a
  known vanilla tier base (`baseTries`: Untrained 2, Trained 4, Master 6),
  it is raised to base + `extraTries` (default 10): 2/4/6 -> 12/14/16
- The durability value itself identifies the tier. Already-raised values
  (12/14/16) are recognized and left alone (idempotent), so values can
  never stack or run away across sessions, saves or reloads; no restore
  pass needed. Unrecognized values are left untouched and logged
- Removed in v8 (freeze/crash suspects from v7.1): the `LoopAsync`
  session watcher, all `RegisterKeyBind` hotkeys, `ExecuteInGameThread`
  deferrals, the end-of-minigame restore
- Trade-off vs v7.1: the raised durability value does get written to
  BaseValue and may appear in saves. Harmless, but a save made with the
  mod is no longer byte-identical to a vanilla one
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
idempotent floor (flattened all tiers to 14), v8.2 per-tier base+bonus
(current). v7 spec: SPEC.md (historical)
