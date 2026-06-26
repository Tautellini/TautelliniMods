# Contributing to TautelliniMods

How our code must look and how we work on it. This governs the **Lua mods**
(UE4SS scripts for Gothic 1 Remake): style, module shape, error handling,
hot-reload discipline, tests.

It does **not** restate engine behavior. Game and engine facts (what is
moddable, what crashes, the minigame canon, the model graveyard) live in:

- `G1R/README.md` (engine safety facts, read before any mod code)
- `G1R/LuaModdingSurface.md` (the moddable surface, the safety bible, the
  banned-operations list)

When code touches the engine, it obeys those two files. This file says how to
write the code around them. When a fact and this file seem to disagree, the
two G1R docs win; fix this file.

---

## 1. General engineering principles

Language-agnostic, but we hold to them tightly because this codebase pays for
slips in native crashes that no `pcall` catches.

- **Small functions, single responsibility.** A function does one thing. If you
  cannot name it without "and", split it.
- **One concern per file.** A module is the solver, or the geometry, or the
  engine access layer, not a mix.
- **Composition over inheritance.** Build behavior by holding helpers, not by
  subclassing. See section 3.
- **Clear names over comments.** Then comment **why**, never **what**. The code
  already says what. Record the reasoning that the code cannot: which wrong
  model this replaced, which measurement forced it. The existing `main.lua` is
  the reference for comment density and tone.
- **Keep the model graveyard.** Every disproven theory gets recorded (in code
  comments and in `LuaModdingSurface.md`) so nobody retries it.
- **Measurement-first, but canon is not relitigated on one noisy read.** Live
  state is measured, never assumed from mined data. But a single measurement
  that contradicts established canon (the goal is the rail center, the lock
  auto-opens) means the **measurement** is suspect, not the canon. The code
  takes two strikes before disabling a feature, never one.
- **Fail loudly, never wordlessly.** A feature that disables itself logs one
  clear line saying which feature and why. A silent boost with no session
  banner once cost a debugging round; do not repeat it.
- **Idempotent state mutations.** Writing the same value twice is a no-op.
  The tries boost recognizes already-boosted values and leaves them alone;
  nothing stacks across saves or reloads. Hold this for every write.
- **Deterministic, test-pinned behavior.** The solver's output is fixed by the
  inputs and is checked against an independent oracle (section 7). No
  gameplay-driven heuristic may silently mutate another feature's output.

---

## 2. The Lua class and module conventions

This is the heart of the refactor. Read it before adding a file.

### Classes: metatable + methods, only for things with state

Use a class **only** when the thing has state or identity over time:
`Session` (one live minigame), `Solver` (a resumable search), `Geometry`
(a calibrated rail frame), `Tinter` (the live tint bookkeeping). A class with
no per-instance state is cargo-cult; make it a module instead.

Copy-pasteable skeleton:

```lua
local setmetatable = setmetatable

local Solver = {}
Solver.__index = Solver         -- set ONCE at load, never mutate after

function Solver.new(deps)
    local self = setmetatable({}, Solver)
    self.place = {}             -- FRESH per-instance tables, never a shared default
    self.log   = deps.log       -- inject the logger, never name a global
    return self
end

function Solver:plan(state)     -- colon defines and calls, injects self
    ...
end

return Solver                   -- every class/module file ends with return
```

Rules:

- `__index` is set once at load. Never reassign it after; class identity is
  already reload-fragile (section 6).
- Per-instance tables are created **fresh in `new`**. A table written as a
  field default on the class table is shared by every instance and will be
  clobbered across sessions.
- Methods use the colon. `function C:m()` injects `self`; call as `obj:m()`.

### Modules: a plain table of functions, for stateless facades

Stateless surfaces are modules, not classes: the kit's `engine`, `num`, `color`,
`log`, `boot`, and the mod's `core.engine_lock` adapter and `tries.boost`. They
are a plain table of functions and hold no mutable instance state.

```lua
local engine = {}
function engine.findAllOf(name) ... end
return engine
```

### Flat composition, no inheritance trees

`Session` HAS-A `Solver`, a `Tinter`, a `Geometry`. It does not extend any of
them. We do not build base classes. Deep `__index` chains add a lookup per hop
in hot code, and they tangle reload identity. If shared behavior
emerges across classes, factor a plain helper **module** and have both call it.

### The purity rule

`Solver` and `Geometry` (and pure helpers like the kit's `num`) must name
**zero** UE4SS globals, so the identical file loads under bare Lua 5.4 for tests.

- **All** engine access goes through the kit's `engine.lua` primitives,
  re-exported by the mod's `core/engine_lock.lua` adapter (where the domain
  literals live): `FindAllOf`, `FName`, `K2_*` reads/writes, property
  reads/writes, `RegisterHook`, `NotifyOnNewObject`, hooks, MPC reads. Every
  engine call is `pcall`-wrapped.
- The pure classes receive the engine layer and the logger as **injected
  dependencies** (`Solver.new{ log = ..., engine = ... }`). A pure file that
  writes `FindAllOf` or `print` directly is a bug: it cannot be tested and it
  cannot be reasoned about for crash safety.

### Naming (deliberate, so reviewers stop churning it)

This is our house style. It is intentional and not up for re-litigation per PR:

| Case | Meaning |
|---|---|
| `PascalCase` | a class, or a load-time-immutable singleton/const: `Config`, `BaseTries`, `SEARCH_VARIANTS`, the class tables |
| `camelCase` | local functions and mutable locals: `boostTries`, `lockName` |
| `UPPER_SNAKE` | primitive literal constants only |

`snake_case` is **not** our default, even though the Lua community defaults to
it. Engine field names (`m_Lock`, `K2_GetComponentLocation`) keep their own
casing because the engine owns them.

### State isolation and global hygiene (this is not optional)

UE4SS runs each mod in its **own** PUC Lua 5.4 state (measured 2026-06-14: `_G`,
`package.loaded`, and even the kit table differ across mods; the old "one shared
LuaJIT 2.1 state, first-`require`-wins" model was wrong). Shared libraries are
therefore **vendored** per mod (section 5), and the rules below keep your own
state clean and reload-safe, not defend against other mods.

- **Every file** captures the stdlib **and** the OOP primitives it uses as locals
  at load (a local read is faster than a global, and it survives a global being
  rebound across a hot reload):

  ```lua
  local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall
  local setmetatable, getmetatable = setmetatable, getmetatable
  local math, table, string = math, table, string
  ```

- **Never write a global.** A forgotten `local` leaks into `_G`, where our reload
  reset (which nils only known names) will not find it. Declare every name `local`.
- **Do not install `strict.lua`.** It mutates `_G`'s metatable, which fights
  UE4SS's own global injection and our hot-reload model.
- **Privacy is by convention.** There are no real private fields (section 4).
  Injected collaborators and config (`self.log`, `self.solver`, `self.flags`)
  are plain fields; reserve an underscore prefix (`self._scratch`) for internal
  state you specifically want to flag as off-limits to callers. It is a signal
  to readers, not enforcement.

---

## 3. Error handling (the Lua way)

Two channels, chosen by whether the caller can do something about it. If you
come from Kotlin: this is **not** exceptions everywhere.

- **Expected misses return `nil, msg`.** No lock name, an ambiguous geometry
  read, no graph for this lock: return `nil` plus a reason, and the caller
  disables that feature honestly and logs one line. This is normal control
  flow, as the current code already does on every "hint off for this lock" path.
- **`error` / `assert` only for broken invariants inside PURE code.** A piece id
  outside `0..N-1`, a base-7 digit out of range: that is a bug in our own
  logic, and a loud `error` under the test harness is exactly what we want.
- **No exception-for-control-flow.** Do not `error` to signal "feature off".
  Return `nil, msg`.

### `pcall` is necessary but not sufficient

**`pcall` does not catch native access violations.** Wrapping an engine call in
`pcall` is required, but it is the **second** line of defense, not the first.

The first defense is **never calling the banned operations**. The full list is
in `G1R/LuaModdingSurface.md`; the high points:

- No TMap **iteration** via reflection (correlated with early-session AVs;
  single-key `:Find` is verified safe).
- No `GetCDO` / `StaticFindObject` on AngelScript class objects.
- No instance property reads off chest classes (`m_RegisteredChests` entries).
- No `K2_GetActorLocation` on the broken part-actor decode path (use the
  component root read instead).

A `pcall` around any of those will **not** save the process. The rule is: do
not call them. The `pcall` is for the operations we have verified safe but want
to survive an unexpected nil or stale wrapper.

For that safe-but-stale case, prefer the shared helper over a hand-rolled
`pcall(function() if obj:IsValid() then ... end end)` at every site. The kit
provides (kit ≥ 1.1.0):

- `kit.engine.guard(obj, fn)` runs `fn(obj)` only when `obj` is a valid UObject,
  pcall-wrapped, returning the result or `nil`. This is the canonical "touch this
  object if it is still alive" call; route every cached deref through it.
- `kit.engine.isValid(obj)` the IsValid gate alone (nil / non-object safe).
- `kit.engine.try(fn)` a bare guarded call for work not centred on one UObject.

These encode the pattern; they do **not** bless the banned operations above (those
AV on a perfectly valid object). They guard the stale/destroyed-handle class only.

---

## 4. Kotlin / OOP gotchas

For a contributor coming from Kotlin or another OOP language. These bite.

- **No real private fields.** Privacy is the underscore convention only.
- **Arrays are 1-based.** `table.insert`, `ipairs`, `t[1]` all start at 1.
  - **The deliberate 0-based DOMAIN exception:** piece ids run `0 .. N-1`
    because they mirror the engine slot index (`Slot_0..6`) and the Python sims.
    The idiom is `for id = 0, n - 1` with `tbl[id] or {}` for safety. Do **not**
    "normalize" piece-id loops to 1-based; it would break parity with the
    engine and the oracle. (General-purpose lists stay 1-based.)
- **`0` and `""` are TRUTHY.** Only `nil` and `false` are falsy. Test
  explicitly: `if x ~= nil then`, `if x ~= 0 then`. A `if count then` where
  `count` can be `0` is a bug.
- **Avoid `a and b or c` when `b` can be falsy.** Rotation `0` is the legal goal
  value, so `cond and 0 or fallback` silently returns `fallback`. Use `if/else`
  wherever the middle value can be `0`, `false`, or `nil`.
- **`#` and `table.insert` are unreliable over tables with `nil` holes.** The
  search bucket queue avoids `#` on purpose: it appends contiguously from index
  1 or carries an explicit `.n` count, and addresses deques by head/tail. Do
  not call `#` on a sparse table.
- **No method overloading.** One function name, one function. Branch inside or
  give it a different name.
- **`table.freeze` does not exist in Lua 5.4.** Immutability is by
  convention: build the table once in `new` or at load, then do not mutate it.
- **Do not wrap hot-loop state in read-only `__newindex` proxies.** It is a perf
  and correctness footgun inside the ~1500-expansions-per-tick search budget.

---

## 5. File and module layout, and hot reload

### Layout

The per-mod `Scripts/` is **foldered**, and every module is `require`d by its
**dotted** path. UE4SS puts the mod's own Scripts dir on `package.path` as
`{Scripts}/?.lua`, and standard Lua maps the dots to slashes, so
`require("nextmove.solver")` resolves `Scripts/nextmove/solver.lua`. (Proven
locally under Lua 5.4 and consistent with UE4SS's own dotted-require `UEHelpers`;
an in-game smoke test on this exact build is still pending but the evidence is
strong.)

- **Root holds only `main.lua` + `config.lua`.** Everything else lives in a
  subfolder: `core/` (`engine_lock`, `session`, `tinter`), `util/` (`palette`),
  `data/` (`lockgraphs`), and **one folder per feature**: `tries/` (`boost`),
  `nextmove/` (`solver`, `geometry`, `hint`), `connections/` (`connections`).
- **Dotted requires only.** `require("core.session")`,
  `require("nextmove.solver")`, `require("util.palette")`,
  `require("data.lockgraphs")`. **Never rely on `require("foo")` finding
  `foo/init.lua`**: UE4SS adds only `?.lua`, so it is file-per-module, always.
- **`deploy.ps1` copies `Scripts/` RECURSIVELY** into the game (the old
  non-recursive copy silently dropped subfolders). Anything that must not ship
  (tests, specs, docs) must **not** live under `Scripts/`.
- **The require graph is a strict DAG**: pure leaves (the kit's `num`, plus
  `config`, `data.lockgraphs`) feed mid-level modules (`core.engine_lock`,
  `nextmove.geometry`, `nextmove.solver`, `core.tinter`) feed `core.session`
  feeds `main.lua`. A **circular** require returns a half-built table silently;
  there is no error, just wrong behavior. Keep it acyclic.

### The shared kit and the generic-vs-mod boundary

There is **one** shared library, the **kit**, with a single repo source at
`G1R/shared/kit/`. Its umbrella `kit.lua` `loadfile`s its siblings and returns
`{ version, log, num, color, engine, boot, async, menu }`:

- `version.lua` (the kit's semver), `log.lua` (`log.make("[Tag]")`),
  `num.lua` (`lookup`, `colorDist2`), `color.lua` (`colorFrom` decoder),
  `engine.lua` (the generic UE4SS primitives `liveInstances` + `readRootPos`,
  the `pcall`-safe idiom, the banned-ops header), `boot.lua` (`tryRequire`),
  `async.lua` (game-thread timers, #1180-safe; see section 5 of the best-practices
  doc), `menu.lua` (the cross-mod menu bridge over UE4SS shared variables).

**The litmus for where code goes:** generic and reusable by any future G1R mod
-> the kit. Mod-domain code stays in the mod. So the kit holds the engine
primitives, num, color, log, boot, async, menu; the mod keeps the engine **adapter**
(`core/engine_lock.lua`, which holds the `MPC_Lockpicking`/`Slot_`/
`HighlightColor`/`m_Lock` literals and re-exports the kit's
`liveInstances`/`readRootPos` so call sites stay identical), the palette,
session/tinter, the features, and the data. **The kit must NEVER hold a
mod-domain literal**; the kit's own `tests/` includes a leak guard that greps
every kit file for `Slot_`/`HighlightColor`/`m_Lock`/`MPC_`/`PlayerState` and
fails the build on any hit.

**Vendored, not global.** UE4SS also reserves `Mods/shared/` on every mod's
path, but **we do not use it**. Instead `deploy.ps1` vendors a private copy of
the kit under each `<Mod>/shared/kit/`, so every deployed mod and public ZIP is
self-contained with no shared-folder dependency. `main.lua` self-adds its own
`shared/` to `package.path` from its own file location (the BPModLoaderMod
pattern), then `require("kit")` returns the umbrella.

**Additive-API rule.** Each mod runs in its own isolated Lua state and vendors its
own kit copy, so a build is self-contained and there is no cross-mod version
conflict to manage. The kit's API is still **additive-only within a major
version**: a breaking change renames it (`kit2`), and consumers `assert
kit.version` against their minimum.

### Features are separately testable

Each feature folder is exercised on its own seam: `tries` ->
`boost.tierTables`; `nextmove` -> `solver` + `geometry` + `hint.color`;
`connections` -> `connections.partnerTints`. The `Tinter` is a pure
**mechanism**: it receives the hint-color and partner-tint policies **injected**
and knows no feature.

### Hot reload (CTRL+R)

CTRL+R **re-runs `main.lua` only**. On this G1R build, contrary to upstream
UE4SS docs (trust the project note in `G1R/README.md`):

- It does **not** re-require children. A stale child module keeps its old code.
- It does **not** tear down old keybinds, hooks, or notifies. They
  **accumulate**: each reload adds another live handler.

So three rules:

0. **`main.lua` self-adds its own `shared/` to `package.path` first**, from its
   own file location (the BPModLoaderMod pattern), so the vendored `require("kit")`
   resolves. This runs before the reset block and the first require.

1. **A single reset block near the top of `main.lua`** nils every module in
   **both** `package.loaded` and the `ue4ss_loaded_modules` table, **before the
   first require**. Two facts make this exact:

   - `package.loaded` is keyed by the **require string**, so the reset `MODULES`
     list must use the **dotted** names (plus `"kit"`). Nil-ing a parent does
     not nil its children, so list every module explicitly or your edits to a
     leaf are silently ignored.
   - `ue4ss_loaded_modules` is keyed by **absolute file path**, not module name.
     The old code nil-ed it by bare module name, which is a silent no-op. So do
     a **FULL SWEEP** of it instead.

   ```lua
   local MODULES = {
       "kit", "config", "core.engine_lock", "core.session", "core.tinter",
       "util.palette", "data.lockgraphs", "tries.boost",
       "nextmove.solver", "nextmove.geometry", "nextmove.hint",
       "connections.connections",
   }
   for _, m in ipairs(MODULES) do package.loaded[m] = nil end
   local reg = rawget(_G, "ue4ss_loaded_modules")
   if type(reg) == "table" then
       for k in pairs(reg) do reg[k] = nil end   -- full sweep: keyed by path
   end
   -- only NOW require the modules, each pcall-wrapped, degrading
   -- per-feature on failure (a broken nextmove/solver.lua must not kill boost)
   ```

2. **All registration stays in `main.lua`'s tail**, never inside a required
   module: `RegisterKeyBind`, `RegisterHook`, `NotifyOnNewObject`,
   `RegisterInitGameStatePostHook`, `LoopAsync`. Keep the existing debounce
   timestamps and the `PendingHooks` dedup. A registration inside a required
   module would multiply per reload (the module is fresh each boot, but the old
   handlers it installed still live).

3. **Class identity is reload-fragile.** A `Session` built before a reload has
   the old metatable; the new code's `getmetatable(obj) == Session` is `false`.
   So **evict and recreate** live objects on reload (the world-change backstop
   and the stale-session eviction at minigame start already do this). Never key
   behavior on `getmetatable(obj) == Class`.

### Probes must be hot-reload-safe and never crash live play

Probes (`G1R/*Probe/`) are developed by editing `main.lua` and hitting CTRL+R
**in a running game on a real savegame**. A probe that can crash on (re)load
forces a full restart and risks the play session, which defeats the point. So a
probe is held to the same native-safety bar as shipping code, and then some:

- **No risky native op at load/eval time, ever.** `pcall` does NOT catch a native
  access violation (section 3, and `G1R/LuaModdingSurface.md`). So do not merely
  wrap the banned operations, do not call them: no `GetCDO`/`StaticFindObject` on
  AngelScript (`/Script/Angelscript.*`) class objects, no instance-prop reads off
  AS/chest classes, no TMap iteration, no `K2_GetActorLocation` on the part-actor
  path. Prefer the SAFE reflected surface (native `/Script/G1R.*` classes, the GAS
  `AttributeSet_*`) and OBSERVE via hooks; treat AS class defaults as read-only-
  via-measurement, never poked directly.
- **Gate every cached-object deref on a fresh `:IsValid()`** at use time, not just
  at capture (the `engine.pressInput` / `engine.writeColor` doctrine). A handle
  read on one tick can be torn down by the next.
- **Register hooks/keybinds/notifies ONCE, behind a global flag**
  (`if not rawget(_G, "__myprobe_v3") then rawset(_G, "__myprobe_v3", true) ... end`).
  CTRL+R does not tear down handlers, it accumulates them; an unguarded
  `RegisterHook` at probe scope multiplies every reload until UE4SS aborts.
- **Keep the act of loading inert.** Auto-run only safe, cheap reads (or nothing);
  put any heavier or higher-risk discovery behind an explicit keybind the user
  presses deliberately, so a reload alone can never trigger it. Hooks need one
  restart to arm; that is the only restart a good probe should ever require.

---

## 6. Testing standards

### Runtime parity

The game runs **PUC-Rio Lua 5.4.7, NOT LuaJIT** (proof in `G1R/README.md`).
**Test under Lua 5.4**, not LuaJIT: LuaJIT is Lua 5.1 semantics, and 5.1-vs-5.4
deltas (separate integer/float subtypes, integer division, `#` on holes, `goto`,
bitwise ops) pass under LuaJIT yet behave differently in-game. The solver stays
byte-identical under both, so logic tests pass on either, but only 5.4 reproduces
the runtime the game actually loads.

Build the runtime once (gitignored `tools\lua54\`; the test runners prefer it,
then fall back to a `lua` on `PATH`): download `lua-5.4.7.tar.gz` from
`https://www.lua.org/ftp/` into `tools\`, extract, and compile `src\*.c` (except
`luac.c`) to `tools\lua54\lua.exe` with `cl` or `gcc`. This matches the UE4SS
runtime and changes nothing system-wide.

### Runner and placement

- **No third-party framework.** The runner is `tests/tinytest.lua`, a small
  in-repo file: it registers tests with `T.add(name, fn)`, fails by raising
  through the `T.*` asserts, and `os.exit(T.run())` returns the failure count.
  The only Lua the suite executes is our own code plus the shipped modules.
- **The kit has its own gate**, separate from any mod:
  `powershell -File G1R\shared\kit\tests\run.ps1` runs with **no mod present**.
  It covers the kit modules and the domain-leak guard (the grep that fails the
  build if any kit file holds a mod-domain literal). Keep the kit green on its
  own before touching consumers.
- Tests live in a **sibling `tests/` dir of the mod**, never under `Scripts/`
  (deploy would ship them). They reference modules by **dotted** name. The
  current suite: `tests/check_load.lua` (the kit plus every shipped mod module
  loads under dotted require and returns a table), `tests/test_solver.lua` (the
  real solver over all 416 locks), `tests/test_geometry.lua` (synthetic anchor
  recovery).
- Run the mod suite with `powershell -File G1R\LockpickSettings\tests\run.ps1`.
  Exit code is the number of failing suites.
- The pure modules (`nextmove/solver.lua`, `nextmove/geometry.lua`, the kit's
  `num.lua` and `color.lua`) **do** ship and stay UE4SS-global-free, so the
  **identical file** loads under both UE4SS and bare Lua 5.4. `check_load.lua`
  adds both `../Scripts` (dotted mod modules) and `../../shared` (the kit path,
  the same shape deploy vendors) to `package.path`.

### What to assert (behavioral parity, not "it runs")

- Every hinted move is **legal under the model the solver planned with**, and
  every committed route **reaches the center**; a state unsolvable even with one
  connection assumed dead **pauses honestly** (no route) rather than guessing.
- The multi-variant greedy route length stays within the **documented bound**
  vs a BFS oracle on full-model-solvable small locks (under 2x; the in-game
  worst over authored layouts is ~1.5x).
- The dead-edge phase machine works: the sweep finds a single-dead-edge route
  (`deadHypo` set), and a confirmed-unsolvable state latches `noRouteFor`.

Note the mined graphs are UPPER BOUNDS: the game prunes ~`LockpickPrecision`
connections at runtime, so 22 of 416 authored layouts are unsolvable as-mined.
The suite expects that (it replays under the solver's pruned model and treats a
no-route pause as success), so do not "fix" it by asserting every lock solves.

### The Python sims are an independent oracle

`tools/sim_planner.py` and `tools/sim_astar_faithful.py` mirror the search
machine in Python. Treat them as a cross-language **diagnostic**, not a strict
pass/fail gate: `sim_planner.py` deliberately reports the runtime-pruned locks
as "planner failed" and may flag a rare greedy outlier, so its exit code is not
the gate. What matters is the route-length and legality **stats**: if the Lua
solver and the Python mirror diverge on a lock's behavior, that is the
regression signal. The Lua `tests/run.ps1` is the gate.

### The solver refactor rule: MOVE-AND-PRESERVE

When the 2293-line `main.lua` is split into modules, the solver's behavior must
be **byte-identical**. Move it, do not "improve" the algorithm. The greedy
variants, the bucket queue, the base-7 encoding, the tie-breaks: all preserved
exactly, and the sims must still agree on all 416 locks afterward.

---

## 7. Workflow and process

Mirrors and extends the conventions in the repo `README.md` and `G1R/README.md`.

- **Edit sources in the repo.** Never edit the deployed copy under the game
  folder (`G1R\Binaries\Win64\ue4ss\Mods\`). The game only ever receives
  deployed builds.
- **Each mod gets a `SPEC.md`** (what and why) before non-trivial work. Once
  shipped, the mod's README becomes the source of truth and the spec is retired
  to git history.
- **Deploy** with `powershell -File tools\deploy.ps1 -Mod LockpickSettings`, or
  `-Mod All` to deploy every enabled mod. Deploy copies `Scripts/` recursively
  and vendors the kit into `<Mod>\shared\kit\` (the `shared/` folder gets no
  `enabled.txt`).
- **Hot-reload** with CTRL+R in a running game (mind section 5). Prefer a full
  restart after deploying changes to keybinds or hooks, since those accumulate.
- **Commit as you go.**
- **Before committing any solver change**, run the Lua test suite **and** the
  Python sims (`python tools/sim_planner.py`); both must pass. A divergence is a
  regression.
- **`lockgraphs.lua` stays a plain, regex-parseable data literal.** The Python
  sims parse it with regex (`tools/sim_planner.py`). Do not let a formatter
  reflow it, and do not change its shape.
</content>
</invoke>
