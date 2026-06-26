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

## Lua runtime (UE4SS)

- UE4SS (the live 3.0.1 Beta and the experimental 3.0.1-968) embeds **PUC-Rio
  Lua 5.4.7, NOT LuaJIT**. Proof: the `$LuaVersion: Lua 5.4.7 ... PUC-Rio`
  string sits in UE4SS.dll, the DLL carries the `lua/5.4/?.lua` search paths
  and zero LuaJIT fingerprints, and no `jit` table is reachable from Lua
  (probed via require / `_G` / package.loaded / package.preload / getfenv(0))
- Consequences vs the old LuaJIT assumption: integers and floats are SEPARATE
  number subtypes (5.4), the collector is the 5.4 incremental GC, and there is
  no JIT at all. Any "JIT miscompiled the solver" theory is therefore a dead
  end; we lost ~10 rounds to it before measuring the runtime
- TEST AGAINST 5.4, never LuaJIT. LuaJIT is Lua 5.1 semantics and masks a class
  of live bugs. A built `lua.exe` lives at `tools/lua54/` (gitignored, build per
  CONTRIBUTING.md); every `tests/run.ps1` prefers it. The solver stays
  byte-identical under both Luas, so logic tests pass on either, but only 5.4
  reproduces the runtime the game actually loads

## What is SAFE from Lua (verified)

- `NotifyOnNewObject` (also on AS classes like `/Script/Angelscript.IoChestDefault`)
- `FindAllOf` / property reads and writes on reflected properties
- `RegisterInitGameStatePostHook`, `LoopAsync`, `ExecuteWithDelay`,
  `ExecuteInGameThread`, `RegisterKeyBind`
- `RegisterHook` on plain ENGINE natives (e.g. PlayerController:ClientRestart)

## What does NOT work (re-verified 2026-06-06, clean conditions)

- `RegisterHook` on G1R natives fires ONLY for engine-dispatched calls.
  AngelScript calls its bound natives directly through the binding
  table (Binds.Cache), bypassing UFunction dispatch: hooks on
  GothicLockConfig:AddPiece/AddConnection register fine and saw zero
  calls across a full world load (416 locks instanced). BUT calls that
  arrive through the engine (input dispatch, ProcessEvent) DO fire:
  hooks on AbilityTask_LockPick:UpPressed/DownPressed/LeftPressed/
  RightPressed fire reliably for keyboard AND controller input
  (verified in-game). Rule of thumb: hook G1R natives only where the
  caller is the engine, never where the caller is script logic, AND
  never where YOUR OWN code is the originating caller even via the
  engine (a hook on a UFunction your driver presses fires reentrantly
  inside your async tick and stomps the shared Lua stack; see the
  #1180 note below). An
  earlier load crash blamed on these hooks did not reproduce and likely
  belonged to the 2026-06-06 instability (frame generation, stale UE4SS
  after a game patch)
- Reading instance properties off AS CLASS objects (e.g. the per-chest
  classes in RandomLockSubsystem.m_RegisteredChests) returns reflection
  garbage and access-violates; `GetCDO()`/`StaticFindObject` on them
  crash natively. `pcall` does NOT catch native access violations
- Lifecycle: ACTORS go pending-kill (IsValid() false) the moment their
  scene ends, but subobjects like MaterialInstanceDynamic merely become
  unreferenced and stay "valid" until the next GC. A polling session
  keyed on MID validity outlives its minigame, and the GC purge of a
  SAVE LOAD leaves the Lua wrappers dangling: the next touch is a
  native AV. Key liveness on an actor, and additionally kill all
  sessions in RegisterInitGameStatePostHook without touching any stored
  wrapper
- UE4SS TMap property access returns a COPY: `:Empty()` etc. do not
  stick. TMap ITERATION via reflection is also suspected of native
  access violations under unclear conditions (a session-start ForEach
  over GothicLockSceneActor:m_RotationToBarOffset correlates with two
  early-session AV crashes); pcall cannot catch native AVs, so avoid
  TMap iteration in shipped mods unless unavoidable
- DEFERRED-CALLBACK ABORT (upstream RE-UE4SS bug, issue #1180): fanning out
  overlapping deferred work via `LoopAsync`/`ExecuteWithDelay` -> `ExecuteInGameThread`,
  or per-keypress `ExecuteInGameThread`, can crash inside
  `process_simple_actions -> get_function_ref` when a queued callback feeds the
  cross-thread queue from inside its own drain. The throw is UE4SS C++ outside any Lua
  frame, so `pcall` cannot catch it. Two signatures, one cause: an `abort()` stack and a
  delayed `0xC0000374` heap corruption; the abort can be SILENT (exit `0x40000015`, no
  dump), so validate a fix by sustained F6/F7 stress, not by absence of dumps. The fix:
  ONE long-lived game-thread driver (route through `kit.async`) draining a plain-Lua
  queue, keybinds flag-only, no nested deferral. Full mechanism, the proven fix, and the
  per-mod audit live in `UE4SS-Lua-Best-Practices.md`. Dumps:
  `%LOCALAPPDATA%/G1R/Saved/Crashes/UECC-*/` and `%LOCALAPPDATA%/CrashDumps/`
  (parse with `tools/parse_minidump.py`)
- SELF-TRIGGERED-HOOK REENTRANCY is the #1180 trigger we kept missing (measured
  2026-06-24, the dense-lock Old Camp castle): a `RegisterHook` on a UFunction YOUR OWN
  code triggers. LockpickSettings drove a lock with `obj:RightPressed()` from its queued
  tick; the game then dispatched `TryOpenLock` / `MemorizeLockpick`, re-entering the
  shared Lua stack to run our hook mid-callback. So the one-game-thread driver is
  NECESSARY BUT NOT SUFFICIENT: also never hook a UFunction your own driven input
  triggers, read that state by MEASUREMENT instead (we detect open from the settled
  all-pins-at-the-bar-column read). Manual play never hit it (the player's keypress
  dispatches from the engine's own input frame, not nested in our async callback). Same
  lesson that earlier removed the Up/Down/Left/Right hooks, applied to the open hooks.