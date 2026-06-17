# CLAUDE.md

Agent rules for this repo. The full prose is in **`CONTRIBUTING.md`** (code
style, Lua class conventions, hot reload, testing); engine and game facts are
in **`G1R/README.md`** and **`G1R/LuaModdingSurface.md`** (the safety bible).
Read those before writing mod code. They win on any conflict; fix the doc, not
the rule.

## General Response Guidance
- keep short responses that get to the point fast
- explain only when being asked to, keep it short otherwise

## General Code Guidance
- use variable and function names that are human readable and understandable
- only write comments where absolutely necessary
- when you see something does not comply with the guidance or general best practices, fix it right away

## Hard rules (do not break)

- **The solver is MOVE-AND-PRESERVE.** `nextmove/solver.lua` and the search math
  must stay byte-identical in behavior. Never "improve" the algorithm, the
  base-7 encoding, the greedy variants, the bucket deque, or the budgets while
  refactoring. After any change to it, run the tests AND `tools/sim_planner.py`.
- **Pure files name zero UE4SS globals.** `nextmove/solver.lua`,
  `nextmove/geometry.lua`, and the kit's `num.lua`/`color.lua` must load under
  bare LuaJIT. ALL engine access goes through the kit's `engine.lua` primitives,
  re-exported by the mod adapter `core/engine_lock.lua` (every call
  `pcall`-wrapped); registration globals (`RegisterHook`, `NotifyOnNewObject`,
  `RegisterKeyBind`, `LoopAsync`, `Key`, ...) live only in `main.lua`'s tail.
- **`pcall` does not catch native access violations.** Wrapping is necessary
  but not sufficient: never call the banned operations (no TMap iteration, no
  instance props off chest classes, no `K2_GetActorLocation` on the broken
  part-actor path). For the AngelScript layer, the rule is now PRECISE
  (re-measured 2026-06-13): `GetCDO()` on an `ASClass` is a HARD CRASH, never call
  it; `ForEachProperty` enumeration is BLIND to AS data fields (returns 0); but
  `StaticFindObject("/Script/Angelscript.Default__X")` plus reading data fields BY
  NAME (`cdo.m_Field`, names from the offline object dump) WORKS and returns real
  values. Treat AS-config reads as DEV-SIDE extraction only (read live, bake to
  data) until proven safe across player environments, the original blanket ban was
  a shipping decision after the 3.0.x live-decode crashed for too many players. See
  `LuaModdingSurface.md` and [[g1r-angelscript-modding]].
- **Foldered `Scripts/`, dotted requires, tests out of `Scripts/`.** Root holds
  only `main.lua` + `config.lua`; the rest is in `core/`, `util/`, `data/`, and
  one folder per feature (`tries/`, `nextmove/`, `connections/`). Everything is
  `require`d by DOTTED name (`require("core.session")`,
  `require("nextmove.solver")`). UE4SS adds only `{Scripts}/?.lua`, which
  resolves dots to slashes, so it is always file-per-module: never rely on
  `require("foo")` finding `foo/init.lua`. `deploy.ps1` copies `Scripts/`
  RECURSIVELY; tests/specs/docs live elsewhere (`tests/` is a sibling dir).
- **The shared kit is generic-only, vendored per mod.** One repo source at
  `G1R/shared/kit/` (`kit.lua` umbrella -> `{ version, log, num, color, engine,
  boot, menu }`). It holds ZERO mod-domain literals (a CI grep in the kit's own
  `tests/` fails the build on `Slot_`, `HighlightColor`, `m_Lock`, `MPC_`, ...).
  Engine primitives, num, color, log, boot, menu go in the kit; the engine
  ADAPTER, palette, session/tinter, features, and data stay in the mod.
  `deploy.ps1` vendors a private copy into each `<Mod>/shared/kit/`, so every
  build is self-contained (we do NOT use UE4SS's global `Mods/shared`). Each mod
  runs in its OWN ISOLATED Lua state (measured 2026-06-14: `_G`, `package.loaded`,
  and even the kit table differ across mods; the old "single state, first-require
  wins" claim was wrong), so vendoring is REQUIRED, not just tidy. The kit API is
  ADDITIVE-ONLY within a major (a breaking change becomes `kit2`). The ONLY
  cross-mod channel is UE4SS shared variables (`ModRef:SetSharedVariable`/`Get`,
  scalars only); `kit.menu` is the bridge for that, see [[g1r-mod-isolation-shared-vars]].
- **Hot reload is in `main.lua` only.** `main.lua` self-adds its own `shared/`
  to `package.path` (computed from its own file location) before any require.
  Keep the single reset block: nil every module by its EXACT dotted require name
  plus `"kit"` in `package.loaded`, and FULL-SWEEP `ue4ss_loaded_modules`
  (`for k in pairs(reg) do reg[k]=nil end`). That cache is keyed by absolute
  path, so the old bare-name nil there was a silent no-op. Keep the
  registration-with-debounce in the tail. Never register from a required module.
  Never key behavior on `getmetatable(obj) == Class`.
- **Capture stdlib + OOP primitives as locals at the top of every file**
  (`ipairs`, `setmetatable`, `math`, ...); never write a global; do not install
  `strict.lua`.
- **Measurement-first, but two strikes not one.** A single noisy read that
  contradicts canon means the measurement is suspect; disable a feature only
  after repeated contradiction, and log one clear line when you do.
- **The mod SHIPS the lock graphs and reads them directly.** `data/lockgraphs.lua`
  is the state of truth (`require "data.lockgraphs"`, 416 graphs). The mod does NOT
  read the game's live data at runtime: a live decode of
  `PrecompiledScript_Shipping.Cache` was tried (3.0.4-3.0.7) but failed for too many
  players (Steam/Windows included), so it was dropped. Accepted consequence: the mod
  is NOT automatically compatible with a new game version or with mods that change
  lock layouts; we maintain the data. REGENERATE `data/lockgraphs.lua` on a game
  update with the dev-side decoder `tools/livegraphs.lua` (auto-calibrating
  in-process port of `tools/extract_locks.py`; run `tools/verify_livegraphs.lua` to
  emit the body, wrap in `return { ... }`). `reference/lock-graphs.lua` stays a
  plain regex-parseable data literal (the Python sims and `test_solver.lua` parse
  it; do not let a formatter reflow it), the dev-side oracle regenerated by
  `extract_locks.py`.

## Workflow

- Edit sources here, never the deployed copy under the game folder.
- **Probes must be hot-reload-safe and never crash live play.** They are reloaded
  with CTRL+R while the user plays on real savegames, so the act of (re)loading
  must be inert: no banned native op at load time (pcall does not catch native
  AVs, so do not call them), every cached deref `:IsValid()`-gated, all
  hooks/keybinds registered ONCE behind a global flag, and any risky discovery put
  behind an explicit keybind, never auto-run. See `CONTRIBUTING.md` section 5.
- **All dev probes live in ONE mod: `G1R/TautelliniDevProbe`.** A probe is a module
  in `Scripts/probes/<name>.lua` returning `function(ctx) ... return spec end`
  (`spec = { name, keys = {{key, mod, desc, fn}}, hooks = {{path, tag, cb}}, autorun }`);
  add it to the `MODULES` list in that mod's `main.lua`, which registers each key/hook
  ONCE and detects key conflicts. Do NOT create a standalone per-probe mod (it is its
  own enabled.txt + deploy + isolated Lua state and easy to forget). When a probe's
  feature ships, GRADUATE it into its real mod and drop it from `MODULES`. Pick keys
  clear of in-use ones (F4/F5/F9 save/load, F6/F7/F8 LockpickSettings, F2 + numpad +
  LMB SharedModMenu, F11 window, F1 archery, F12 asread).
- Run `G1R/LockpickSettings/tests/run.ps1` before committing solver/geometry
  changes; it needs LuaJIT (see `CONTRIBUTING.md` section 6).
- House naming: `PascalCase` for classes and load-time consts, `camelCase` for
  functions and locals, `UPPER_SNAKE` for primitive literals. Not `snake_case`.
- Do not use the "—" character or AI-typical phrasing in code, comments, or docs
  (matches the global preference).
- **Write it as a product other mod authors read.** SharedModMenu and the shared kit are
  CONSUMED by other modders, so the whole repo is held to that bar: code clean and readable
  at a glance, small focused functions, self-explanatory names over cleverness, and an
  obvious public surface (`kit.menu.register`, the item spec, per-mod `config.lua`). Comments
  are SPARSE and EXACTLY on point: a function gets one only when intent or a non-obvious
  constraint is not already clear from the code, and then a single tight line, never a
  paragraph and never a restatement of the code. Public APIs get a short usage example in the
  mod's README. Prefer deleting a comment to letting it drift out of date.
- Ask before creating a git worktree.
