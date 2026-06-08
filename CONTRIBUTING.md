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

Stateless surfaces are modules, not classes: `engine` (the UE4SS access layer),
`boost`, `num`, `colors`. They are a plain table of functions and hold no
mutable instance state.

```lua
local engine = {}
function engine.findAllOf(name) ... end
return engine
```

### Flat composition, no inheritance trees

`Session` HAS-A `Solver`, a `Tinter`, a `Geometry`. It does not extend any of
them. We do not build base classes. Deep `__index` chains cost a LuaJIT guard
per hop in hot code, and they tangle reload identity. If shared behavior
emerges across classes, factor a plain helper **module** and have both call it.

### The purity rule

`Solver` and `Geometry` (and pure helpers like `num`) must name **zero** UE4SS
globals, so the identical file loads under bare LuaJIT for tests.

- **All** engine access goes through **one** file, `engine.lua`: `FindAllOf`,
  `FName`, `K2_*` reads/writes, property reads/writes, `RegisterHook`,
  `NotifyOnNewObject`, hooks, MPC reads. Every engine call in there is
  `pcall`-wrapped.
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

### Shared-state safety (this is not optional)

UE4SS runs **one** LuaJIT 2.1 state (Lua 5.1 semantics) across **all** mods.
Another mod can clobber a stdlib global mid-session: `ipairs` was seen replaced
by a table in the wild, crashing our loops.

- **Every file** captures the stdlib **and** the OOP primitives it uses as
  locals at load:

  ```lua
  local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall
  local setmetatable, getmetatable = setmetatable, getmetatable
  local math, table, string = math, table, string
  ```

- **Never write a global.** A forgotten `local` leaks into `_G`, where another
  mod can clobber it and where our own reload logic will not find it. Declare
  every name `local`.
- **Do not install `strict.lua`.** It mutates `_G`'s metatable, which other
  mods touch; it would break them and us.
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
- **`table.freeze` does not exist in LuaJIT 5.1.** Immutability is by
  convention: build the table once in `new` or at load, then do not mutate it.
- **Do not wrap hot-loop state in read-only `__newindex` proxies.** It is a perf
  and correctness footgun inside the ~1500-expansions-per-tick search budget.

---

## 5. File and module layout, and hot reload

### Layout

- **All shipped Lua stays FLAT in `Scripts/`.** UE4SS's `package.path` does not
  include subfolders, so every shipped module is `require`d by bare name
  (`require("solver")`).
- **`deploy.ps1` copies `Scripts/*` verbatim** into the game. Anything that must
  not ship (tests, specs, docs) must **not** live under `Scripts/`.
- **The require graph is a strict DAG**: pure leaves (`num`, `config`,
  `lockgraphs`) feed mid-level modules (`engine`, `geometry`, `solver`,
  `tinter`) feed `session` feeds `main.lua`. A **circular** require returns a
  half-built table silently; there is no error, just wrong behavior. Keep it
  acyclic.

### Hot reload (CTRL+R)

CTRL+R **re-runs `main.lua` only**. On this G1R build, contrary to upstream
UE4SS docs (trust the project note in `G1R/README.md`):

- It does **not** re-require children. A stale child module keeps its old code.
- It does **not** tear down old keybinds, hooks, or notifies. They
  **accumulate**: each reload adds another live handler.

So three rules:

1. **A single reset block at the very top of `main.lua`** nils every shipped
   module in **both** `package.loaded` and the `ue4ss_loaded_modules` table,
   **before the first require**. Nil-ing a parent does not nil its children, so
   list every module explicitly or your edits to a leaf are silently ignored:

   ```lua
   local MODULES = {
       "config", "lockgraphs", "num", "colors", "engine",
       "boost", "solver", "geometry", "tinter", "session",
   }
   for _, m in ipairs(MODULES) do
       package.loaded[m] = nil
       local reg = rawget(_G, "ue4ss_loaded_modules")
       if type(reg) == "table" then reg[m] = nil end
   end
   -- only NOW require the modules, each pcall-wrapped, degrading
   -- per-feature on failure (a broken solver.lua must not kill the boost)
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

---

## 6. Testing standards

### Runtime parity

The game runs **LuaJIT 2.1 (Lua 5.1 semantics)**. **Test under LuaJIT, not
Lua 5.4.** 5.1-vs-5.4 deltas (integer division, `#` on holes, `goto`, bitwise
ops) can pass on a 5.4 install and behave differently in-game.

Install LuaJIT once, either:

- drop a prebuilt `luajit.exe` + `lua51.dll` into `tools\luajit\` (gitignored;
  the test runner finds it there automatically), or
- via scoop (non-admin, prebuilt): `irm get.scoop.sh | iex` then
  `scoop install luajit` (the runner finds `luajit` on `PATH` first).

A self-contained way to fetch the prebuilt: download the MSYS2 package
`mingw-w64-x86_64-luajit-*.pkg.tar.zst` from `https://mirror.msys2.org/mingw/mingw64/`,
extract with `tar --zstd -xf`, and copy `mingw64\bin\luajit.exe` and
`lua51.dll` into `tools\luajit\`. This matches the UE4SS runtime exactly and
changes nothing system-wide.

### Runner and placement

- **No third-party framework.** The runner is `tests/tinytest.lua`, a small
  in-repo file: it registers tests with `T.add(name, fn)`, fails by raising
  through the `T.*` asserts, and `os.exit(T.run())` returns the failure count.
  The only Lua the suite executes is our own code plus the shipped modules.
- Tests live in a **sibling `tests/` dir of the mod**, never under `Scripts/`
  (deploy would ship them). The current suite: `tests/check_load.lua` (every
  module loads and returns a table), `tests/test_solver.lua` (the real solver
  over all 416 locks), `tests/test_geometry.lua` (synthetic anchor recovery).
- Run it all with `powershell -File G1R\LockpickSettings\tests\run.ps1`. Exit
  code is the number of failing suites.
- The pure modules (`solver.lua`, `geometry.lua`, `num.lua`, `colors.lua`)
  **do** ship and stay UE4SS-global-free, so the **identical file** loads under
  both UE4SS and bare LuaJIT. The harness adjusts `package.path` to require them
  from `../Scripts`.

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
- **Deploy** with `powershell -File tools\deploy.ps1 -Mod LockpickSettings`.
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
