# Gothic 1 Remake (G1R) Modding Guide

Hard-won facts about this game's tech. Read before writing any mod code.
State as of Build 8336 (CL 168089), June 2026.

## Engine

- Unreal Engine **5.4.3**, IoStore packaging (`G1R-Windows.ucas` ~29 GB)
- Gameplay logic largely in **AngelScript** (Hazelight-style plugin).
  `G1R\Script\PrecompiledScript_Shipping.Cache` (122 MB) is the compiled
  script blob, `Binds.Cache` the C++/script binding table
- Skills/stats via **GameplayAbilities (GAS)**: GameplayEffects + AttributeSets
- Gothic naming survives: items like `ItKe_Lockpick`, talent enum
  `NPC_TALENT_PICKLOCK`, interactive object classes `Io*` (IoChestDefault, IoDoor01)
- No anti-cheat. Single player. Exit crash with UE4SS installed is a known
  cosmetic teardown issue (access violation after everything is saved)

## UE4SS setup that works here

UE4SS experimental v3.0.1-953 in `G1R\Binaries\Win64` (dwmapi.dll + ue4ss\).
**Critical settings** (UE4SS-settings.ini), or the game hard-freezes at save load:

```ini
HookProcessInternal = 0
HookProcessLocalScriptFunction = 0
HookUObjectProcessEvent = 0
HookCallFunctionByNameWithArguments = 0
HookAActorTick = 0
GuiConsoleEnabled = 0
bUseUObjectArrayCache = false
```

These collide with the AngelScript VM dispatch. Keep them off.

## What is SAFE from Lua (verified)

- `NotifyOnNewObject` (also on AS classes like `/Script/Angelscript.IoChestDefault`)
- `FindAllOf` / property reads and writes on reflected properties
- `RegisterInitGameStatePostHook`, `LoopAsync`, `ExecuteWithDelay`,
  `ExecuteInGameThread`, `RegisterKeyBind`
- `RegisterHook` on plain ENGINE natives (e.g. PlayerController:ClientRestart)

## What CRASHES (verified the hard way)

- `RegisterHook` on G1R/AS-bound native UFunctions
  (GothicLockConfig:AddPiece/AddConnection, AbilityTask_LockPick:TryOpenLock):
  infinite recursion between the UE4SS detour and the AS binding layer,
  dies ~55s into load. Assume ALL G1R natives are unhookable from Lua
- UE4SS TMap property access returns a COPY: `:Empty()` etc. do not stick

## Research workflow

1. CTRL+J ingame = full object dump to `ue4ss\UE4SS_ObjectDump.txt` (~60 MB)
2. Grep it for classes/properties; `[o: X]` = member offset, `[f: X]` = native
   function body address (per-session base, stable image offset per build)
3. CTRL+NUM_6 = .usmap dump for FModel asset inspection if ever needed
4. Reflected property = reachable from Lua. Everything else needs C++

## Lockpicking system map (for LockpickSettings)

- `AttributeSet_Lockpicking` on the PlayerState: `LockpickDurability`
  (failures before pick breaks, Untrained vanilla = 4), `LockpickPrecision`
  (hint quality, Untrained vanilla = 1). Tier GEs: GE_Skill_Picklock_Untrained/Skilled/Master
- Minigame: `AbilityTask_LockPick` (5 levels, align red pins, connections
  couple level movement; edge fail costs durability)
- Locks defined by `GothicLockConfig` (pieces + connections, built eagerly
  for all ~416 world locks at load, NEVER saved: save stores only
  `m_UnlockedLocks`). Chests: `m_LockDifficulty` int drives which template
  is assigned on first pick (assignment persists via `m_OriginalLock`)
- Connection data is fully unreflected: thinning requires a C++ detour on
  the AddConnection exec body (parked; see LockpickSettings/SPEC.md)
