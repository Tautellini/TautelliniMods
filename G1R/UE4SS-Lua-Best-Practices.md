# UE4SS Lua Modding Best Practices

Our source of truth for writing UE4SS Lua mods. General guidance, not tied to any one
mod. Companion to `LuaModdingSurface.md` (what is moddable in this game) and `README.md`
(engine and game facts).

## Prefer the current Lua API

- **Always use UE4SS's current Lua API, not the deprecated calls.** When two functions do the
  same job, pick the newer one. Use the game-thread Delayed Action System
  (`LoopInGameThreadWithDelay`, `ExecuteInGameThreadWithDelay`,
  `RetriggerableExecuteInGameThreadWithDelay`, `CancelDelayedAction`) over `LoopAsync` /
  `ExecuteAsync` with a nested `ExecuteInGameThread`. In this repo, route periodic and delayed
  work through `kit.async` (see Periodic and deferred work). It picks the current API and falls
  back only where a build lacks it.
- **Check the API reference before reaching for an old pattern.** A flat, searchable copy of the
  full UE4SS docs lives at `G1R/reference/UE4SS-Documentation.md`, parsed from
  `tools/UE4SS Documentation.pdf` (kept local, regenerate with `tools/parse_ue4ss_docs.py`). The
  PDF and `docs.ue4ss.com` are authoritative. Confirm a function exists and how it is called there
  before assuming the old approach is the only option. That assumption is what kept us on
  `LoopAsync` long after the better API had already shipped.

## Thread model

UE4SS does not run all Lua on one thread, and Lua is not thread-safe. Know where a
callback runs before it touches game state or shared data.

| Callback / API | Thread |
|---|---|
| `RegisterHook` (UFunction) | Game thread (fires inside `ProcessEvent`) |
| `NotifyOnNewObject` | Game thread (deferred) |
| `RegisterInitGameStatePostHook` | Game thread |
| `RegisterConsoleCommandHandler` | Game thread |
| `RegisterKeyBind` | UE4SS event-loop thread, NOT the game thread |
| `LoopAsync`, `ExecuteAsync`, `ExecuteWithDelay` | A dedicated async thread, separate Lua state |
| `ExecuteInGameThread`, `LoopInGameThreadWithDelay` | Game thread (drained on the engine tick) |

Only touch game objects from a game-thread callback. From a keybind or an async loop,
do the minimum and hand off to the game thread (see Periodic and deferred work).

## Mod structure and isolation

- **Each mod runs in its own Lua state.** `_G`, `package.loaded`, and module tables are
  not shared between mods. The only cross-mod channel is UE4SS shared variables
  (`ModRef:SetSharedVariable` / `GetSharedVariable`), which carry scalars only. Vendor
  shared libraries into each mod rather than relying on a shared module instance.
- **Capture stdlib and engine globals as locals at load.** Another mod can overwrite a
  shared global at any time. Never write a global yourself; do not install `strict.lua`.
- **All registration lives in `main.lua`'s tail, never in a required module**, and each
  hook / keybind / notify / loop is registered exactly once.
- **Path resolution:** UE4SS adds `{Scripts}/?.lua`. Dotted requires resolve dots to
  slashes, so it is always file-per-module (`require("core.session")` loads
  `core/session.lua`); there is no `init.lua` fallback.

## Engine access

- **Route all UObject access through one cached getter layer** that re-validates with
  `:IsValid()` on every call and re-acquires on staleness. Capture the result; do not
  poll `FindAllOf` per tick (it is expensive and causes hitches).
- `FindAllOf` returns `nil` (not `{}`) on a miss and cannot find class-default objects;
  nil-check it.
- Reflected properties are readable and writable. Two write targets: class defaults
  (`StaticFindObject("/Script/X.Default__Y")`) affect everything spawned afterwards;
  live instances (`FindAllOf`, or an object handed to a `NotifyOnNewObject` callback)
  affect one object.
- Native UFunctions are callable from Lua (`obj:SomeFunction(args)`); a Lua table
  marshals as a struct argument, and return values come back as Lua values.
- Quirks: a `TMap` read returns a copy, so mutations do not stick; `TArray` is 1-based
  in Lua; read an `FName` with `:ToString()`; construct an `FName` with `FNAME_Find` for
  a lookup (the default is `FNAME_Add`, which adds a new global name-table entry); keep
  `FName` / `FString` construction out of per-tick paths.
- Never key behavior on `getmetatable(obj) == SomeClass`.

## Native safety

- **`pcall` does not catch native access violations.** Wrapping is necessary but not
  sufficient; the first defense is never doing the dangerous thing.
- **`:IsValid()` before every deref of a cached UObject**, at use time, not just at
  capture. `IsValid` reads an object-table slot and never derefs, so it is itself safe.
- **Object lifecycle:** actors go pending-kill (`IsValid` false) the moment their scene
  ends, but subobjects (material instances, components) only become unreferenced and
  stay valid until the next GC. Key liveness on an actor, and on a world change
  (`RegisterInitGameStatePostHook`) drop every cached handle without touching it, since a
  GC purge can leave the wrappers dangling.
- Some reflection operations native-crash on a perfectly valid object (iterating certain
  reflected containers, reading instance properties or calling `GetCDO()` on class
  objects of a scripting-VM type). Avoid them; `pcall` will not save you.

## Garbage collection

- **A large resident Lua table poisons GC timing and can cause intermittent native
  crashes.** Lua's GC walks every live object each cycle, so a table with N entries is N
  objects of work. A heavy GC pass can race UE4SS's object marshaling, and the result is
  an access violation deep in UE4SS dispatch frames, BEFORE your callback runs, that
  `pcall` cannot catch. It looks exactly like a UE4SS bug and is easy to misattribute.
  Measured in LockpickSettings 3.2.x: a ~1.29M-element integer array left resident made
  opening a chest / starting a lock crash intermittently; freeing it removed the crash.
- **`require` caches its return value in `package.loaded` for the whole session.** A data
  module that `return`s a giant table keeps that table alive forever. If you only need it
  to build a compact form, convert it, then drop the cache and reclaim it now:

      local t = require("data.big")        -- huge table, now cached in package.loaded
      local blob = pack(t)                 -- the compact form you actually keep
      package.loaded["data.big"] = nil     -- release the giant table...
      collectgarbage("collect")            -- ...and reclaim it this frame

- **For resident data, prefer one big object over many small ones.** A multi-MB Lua
  STRING is a single GC object and is cheap to scan; the same bytes as a per-element TABLE
  are millions of objects the GC re-scans every cycle. Keep shipped blobs as strings once
  loaded, not as arrays.

## Hooks, notifications, input

- **`RegisterHook`:** the UFunction must already exist in memory when you register, so
  register lazily after the owning class is loaded; anything not under `/Script/` should
  be installed from a lifecycle hook, not at file load. A hook fires only when the
  ENGINE dispatches the UFunction. Calls a scripting VM (AngelScript, Blueprint internal
  calls) makes through its own binding table bypass UFunction dispatch and will not fire
  your hook.
- **`NotifyOnNewObject`:** register once per class (duplicate registrations are a
  documented perf hazard); the callback runs on the game thread. Prefer it over polling
  for reacting to spawns.
- **`RegisterKeyBind`:** runs on the event-loop thread, not the game thread, and fires
  only while the game or console is focused. Marshal any game-object work to the game
  thread with `ExecuteInGameThread`, and debounce rapid repeats.
- **Wrap every callback body in `pcall`** so a Lua error never propagates into UE4SS C++.
- **Console handlers:** the output device passed to a `RegisterConsoleCommandHandler`
  callback is valid only for that synchronous call. Do the work and write output inline;
  never defer the work and write to the device later (it is freed by then).

## Periodic and deferred work

- To touch game objects from an async context (a keybind handler, a `LoopAsync` body),
  marshal the work to the game thread with `ExecuteInGameThread`. Only touch game objects
  on the game thread.
- For periodic game-thread work use `LoopInGameThreadWithDelay`; for a one-shot delay use
  `ExecuteInGameThreadWithDelay` (game thread) or `ExecuteWithDelay` (async). The game-thread
  timers run the callback ON the game thread, so they need NO nested `ExecuteInGameThread`.
  `LoopAsync` and `ExecuteAsync` are the deprecated async variants and must marshal with
  `ExecuteInGameThread` before touching game objects. The game-thread timers have shipped in
  this UE4SS for a long time (confirmed 2026-06-26); the repo just built around `LoopAsync`
  historically and only adopted them once the failure mode below forced the issue.
- Use the kit: `kit.async.gameLoop(ms, decide)` and `kit.async.gameDelay(ms, fn)` (kit 1.7.0+)
  prefer the game-thread timers and fall back to `LoopAsync` + `ExecuteInGameThread` where a
  build lacks them. `decide()` returns the work function when a tick is due, `true` to stop the
  loop, or nil. Route new periodic and delayed work through these, not raw `LoopAsync`.
- Known engine bug: the deferred action queue behind `LoopAsync` + `ExecuteInGameThread` has a
  reentrancy defect (RE-UE4SS issue #1180). The trigger is nested deferral: feeding that
  cross-thread queue from inside its own drain. On older builds it ABORTS the game (UE4SS C++,
  `pcall` cannot catch it). On the current build the abort is gone, but the failure is not: UE4SS
  catches the bad callback ref (`[Lua::Registry::get_function_ref] Ref was not function ...
  removing hook!`) and drops the SHARED Lua engine-tick hook (`UE4SS.EngineTick.LuaModImpl`),
  which silences EVERY mod's loops and timers until a restart. You cannot catch that from Lua
  either, it is above the Lua frame. The real fix is to not nest: run periodic and delayed work
  on the game thread (the timers above, via `kit.async`). Also never `RegisterHook` a UFunction
  your own code triggers, the part we kept missing (2026-06-24). Your driver pressing
  `RightPressed()` from inside a queued callback re-dispatches the hooked functions and re-enters
  the shared Lua stack mid-callback. Read that state by measurement instead. See `G1R/README.md`.

## Hot reload (CTRL+R)

- A reload destroys the Lua state (`lua_close`) and builds a new one; a clean reload
  removes the mod's hooks, keybinds, and async loops before re-running `main.lua`.
- Guard anyway: register keybinds behind `IsKeyBindRegistered`, hooks and notifies behind
  an install flag, and retire long-lived loops with a generation token (bump a `_G`
  counter each load; the old loop sees a newer value and stops or cancels itself).
- Prefer a full restart after deploying a mod that registers hooks or keybinds.

## References

- RE-UE4SS source and docs: `github.com/UE4SS-RE/RE-UE4SS`, `docs.ue4ss.com`
- Parsed UE4SS docs (this repo, searchable): `G1R/reference/UE4SS-Documentation.md`
  (from the local `tools/UE4SS Documentation.pdf`, regenerate with `tools/parse_ue4ss_docs.py`)
- Deferred-queue stability bug and fix: issue #1180, PR #1201 (with #1268 / #1269 / #1271)
- Delayed Action System (game-thread timers): PR #1128 (`LoopInGameThreadWithDelay`,
  `ExecuteInGameThreadWithDelay`, and the `*AfterFrames` variants)
- `UEHelpers.lua` (the shared cached-getter access layer; the reference for engine access)
