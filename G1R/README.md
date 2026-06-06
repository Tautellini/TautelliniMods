# Gothic 1 Remake (G1R) Modding Guide

Hard-won facts about this game's tech. Read before writing any mod code.

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