# UE4SS Lua Modding Best Practices

Our source of truth for writing UE4SS Lua mods. General guidance, not tied to any one
mod. Companion to `LuaModdingSurface.md` (what is moddable in this game) and `README.md`
(engine and game facts).

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
  `ExecuteWithDelay` (async) or `ExecuteInGameThreadWithDelay` (game thread). `LoopAsync`
  and `ExecuteAsync` are the older async variants and must marshal with
  `ExecuteInGameThread` before touching game objects.
- Known engine bug: the internal action queue behind all of these had a reentrancy defect
  (RE-UE4SS issue #1180, fixed in PR #1201, 2026-06-14) that can crash under heavy or
  overlapping deferred work on builds before the fix. The abort happens in UE4SS C++ and
  `pcall` cannot catch it. The remedy is to update UE4SS; this is an engine bug, not
  something to architect the mod around.

## Hot reload (CTRL+R)

- A reload destroys the Lua state (`lua_close`) and builds a new one; a clean reload
  removes the mod's hooks, keybinds, and async loops before re-running `main.lua`.
- Guard anyway: register keybinds behind `IsKeyBindRegistered`, hooks and notifies behind
  an install flag, and retire long-lived loops with a generation token (bump a `_G`
  counter each load; the old loop sees a newer value and stops or cancels itself).
- Prefer a full restart after deploying a mod that registers hooks or keybinds.

## References

- RE-UE4SS source and docs: `github.com/UE4SS-RE/RE-UE4SS`, `docs.ue4ss.com`
- Deferred-queue stability bug and fix: issue #1180, PR #1201 (with #1268 / #1269 / #1271)
- `UEHelpers.lua` (the shared cached-getter access layer; the reference for engine access)
