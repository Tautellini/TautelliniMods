# CLAUDE.md

Agent rules for this repo. The full prose is in **`CONTRIBUTING.md`** (code
style, Lua class conventions, hot reload, testing); engine and game facts are
in **`G1R/README.md`** and **`G1R/LuaModdingSurface.md`** (the safety bible).
Read those before writing mod code. They win on any conflict; fix the doc, not
the rule.

## Hard rules (do not break)

- **The solver is MOVE-AND-PRESERVE.** `Scripts/solver.lua` and the search math
  must stay byte-identical in behavior. Never "improve" the algorithm, the
  base-7 encoding, the greedy variants, the bucket deque, or the budgets while
  refactoring. After any change to it, run the tests AND `tools/sim_planner.py`.
- **Pure files name zero UE4SS globals.** `solver.lua`, `geometry.lua`,
  `num.lua`, `colors.lua` must load under bare LuaJIT. ALL engine access goes
  through `Scripts/engine.lua` (every call `pcall`-wrapped); registration
  globals (`RegisterHook`, `NotifyOnNewObject`, `RegisterKeyBind`, `LoopAsync`,
  `Key`, ...) live only in `Scripts/main.lua`'s tail.
- **`pcall` does not catch native access violations.** Wrapping is necessary
  but not sufficient: never call the banned operations (no TMap iteration, no
  `GetCDO`/`StaticFindObject` on AS class objects, no instance props off chest
  classes, no `K2_GetActorLocation` on the broken part-actor path). See
  `LuaModdingSurface.md`.
- **Flat `Scripts/`, tests out of `Scripts/`.** `deploy.ps1` copies `Scripts/*`
  verbatim, and UE4SS has no subfolder `package.path`. Shipped Lua is flat and
  `require`d by bare name; tests/specs/docs live elsewhere (`tests/` is a
  sibling dir).
- **Hot reload is in `main.lua` only.** Keep the single reset block (nils every
  module in `package.loaded` AND `ue4ss_loaded_modules` before the first
  `require`) and the registration-with-debounce in the tail. Never register from
  a required module. Never key behavior on `getmetatable(obj) == Class`.
- **Capture stdlib + OOP primitives as locals at the top of every file**
  (`ipairs`, `setmetatable`, `math`, ...); never write a global; do not install
  `strict.lua`.
- **Measurement-first, but two strikes not one.** A single noisy read that
  contradicts canon means the measurement is suspect; disable a feature only
  after repeated contradiction, and log one clear line when you do.
- **`lockgraphs.lua` stays a plain regex-parseable data literal.** The Python
  sims parse it; do not let a formatter reflow it.

## Workflow

- Edit sources here, never the deployed copy under the game folder.
- Run `G1R/LockpickSettings/tests/run.ps1` before committing solver/geometry
  changes; it needs LuaJIT (see `CONTRIBUTING.md` section 6).
- House naming: `PascalCase` for classes and load-time consts, `camelCase` for
  functions and locals, `UPPER_SNAKE` for primitive literals. Not `snake_case`.
- Do not use the "—" character or AI-typical phrasing in code, comments, or docs
  (matches the global preference).
- Ask before creating a git worktree.
