# Auto-Solve on Hotkey

Spec for adding an auto-solver to the G1R LockpickSettings mod. The mod already
plans the full route and reads live state; this feature makes it *act* on the
lock. Written 2026-06-08 after a feasibility survey and a grilling pass.

## Goal

Let the player drive the lockpick minigame to "open" without doing the moves by
hand. Two levels of automation on two binds:

- **One step (F6):** execute exactly the next solver move, then stop.
- **Full-auto (Shift+F6):** run the whole route to unlock, then stop on its own.

The solver and live-state reads already exist. This feature adds the missing
half: turning a computed move into an executed press, with a confirm loop so the
bot's internal state never silently diverges from the lock.

## Scope

### In

- A press primitive in the engine adapter that calls the `AbilityTask_LockPick`
  input UFunctions on the live task (the only viable act-path; see Background).
- A new `autosolve` feature module owning the act-loop: resolve next move,
  pre-check legality, map direction to a physical key, drive selection to the
  target pin, press, confirm by re-reading, and (full-auto) repeat.
- Two configurable hotkeys wired in `main.lua`'s tail, following the F7/F8
  template (debounce, `ExecuteInGameThread`, feature-health gate, banner line,
  hot-reload reset entry).

### Out (v1)

- A hard durability guard that pre-learns edges before acting. We accept some
  risk instead (see Risk posture).
- Sub-settle "burst" pacing beyond opportunistic fire-and-confirm.
- Any on-screen progress UI beyond the existing banner and console lines.
- Auto-triggering without a hotkey (no "solve as soon as a lock opens").
- Touching the solver or geometry. They stay MOVE-AND-PRESERVE and
  byte-identical in behavior.

## Background (settled facts, do not re-litigate)

- `nextmove/solver.lua` produces a deterministic full route to the all-center
  goal and surfaces the next step via `Solver:plan(s)` returning
  `{piece = 0-based id, dir = +1|-1}`. `s.nextMove` already holds the current
  best move. `Solver:moveValid(s, x, d)` pre-checks rail/edge legality.
- `session.lua` re-reads live piece positions every ~400ms, snaps to integer
  rotations around the bar-column anchor, and assembles the exact solver input.
  The planner can run against the live session at any moment.
- `hint.lua` already maps `{piece, dir}` to a physical press direction through
  `inputToAxis` / `screenRight` / `sign` (green = left, blue = right).
- The press path is **proven**: an early `G1R/LockProbe` build moved the lock on
  an F-key press. We treat the press UFunction as a working primitive. The first
  real F6 press in this feature doubles as its own confirmation; we only revisit
  a standalone probe if that first press misbehaves.
- Selection (which row a Left/Right press acts on) lives only on the GPU. There
  is no reflected property. It is inferred from the glow, which flaps around
  animations, so selection must be driven by Up/Down presses and reconfirmed by
  re-reading the glow after each step.

## User-facing behavior

### One step (F6)

1. Player presses F6 on a live lock.
2. The bot resolves the next move, drives selection to that pin, presses, and
   confirms the pin moved as predicted.
3. It logs one line naming the move it made, then stops.
4. If state is unusable (see Bad-state policy), it does nothing and logs one
   line saying why.

### Full-auto (Shift+F6)

1. First Shift+F6 starts a run. The bot executes moves one after another,
   **as fast as each press is honored** (it does not wait a fixed settle gate
   between moves; it confirms each press landed and fires the next immediately).
2. The run **stops automatically** the moment the lock is solved.
3. A second Shift+F6 **cancels** an in-progress run.
4. On a deviation (a refused move, a no-op press, or the pin not moving as
   predicted), the bot **re-reads live state, replans from there, and continues
   once**. A second consecutive deviation stops the run with one log line.
5. On bad state at any point, it aborts the run and logs one line.

F6 during a full-auto run is not a control for the run; it remains the
single-step bind. (Open question O3 covers whether F6 should also cancel.)

## Architecture

Follows the repo's hard rules: pure files stay UE4SS-global-free; all engine
access goes through `core/engine_lock.lua` (every call `pcall`-wrapped);
registration lives only in `main.lua`'s tail; fail loud under two-strikes.

### New: press primitive in `core/engine_lock.lua`

The single new write/act seam. One wrapper that calls the `AbilityTask_LockPick`
input UFunction for a given direction (`UpPressed` / `DownPressed` /
`LeftPressed` / `RightPressed`). Requirements:

- Every call `pcall`-wrapped.
- Liveness checked on the **live actor per call**, never on a cached
  `FreshTask.obj` (actors go pending-kill the instant the scene ends; a
  save-load GC purge leaves dangling wrappers).
- Returns a clear ok/not-ok result so the driver can branch.
- Stays a thin engine primitive. The kit (`shared/kit/engine.lua`) stays generic
  and read-only; this domain primitive lives in the mod, not the kit.

### New: `autosolve/driver.lua` (feature module, not a pure file)

A tick-driven state machine (`idle` / `selecting` / `moving`). It does NOT run
its own loop and never stalls the game thread: `main` arms it by setting
`liveSession.autopilot = driver`, and the session calls `driver:step(s)` ONCE per
SETTLED tick (the tick early-returns during motion, so a step only lands when the
previous move has demonstrably settled). May use the `engine_lock` adapter; never
names a UE4SS global. Owns:

- **Resolve next move** by calling `s.solver:plan(s)` directly each idle step, so
  it works regardless of the hint toggle.
- **Map `dir` to a physical key** with `pressDir = move.dir *
  (s.inputToAxis or s.screenRight) * s.sign` (the exact inverse of `hint.lua`).
  `screenRight` from geometry is normally present, so direction is usually known
  at once.
- **Drive selection** to `move.piece` with Up/Down presses. With a readable glow
  (`s.selectedSig`) it fires all needed steps at once and confirms via
  `s:resyncSelection()` next tick; without a glow it steps one per tick so the
  input-counted row stays in sync (the count debounces on rapid presses).
- **Press** Left/Right, then confirm on a later settled tick by comparing the
  target piece's measured rotation against the expected `preRot + move.dir`
  (`MOVE_GRACE` settled checks before declaring a no-op).
- **Single-step vs full-auto**: single stops after one move (or one deviation);
  full-auto replans once on deviation, stops on a second consecutive one, cancels
  on a repeat hotkey, and auto-stops at goal.
- **Wait-then-nudge** when no move is ready, then **abort + one log line** on
  unusable state. No silent retries. A nudge counts as success on EITHER observed
  sign (it exists to make progress and reveal direction, so it is never a
  deviation).
- **Does NOT touch the shared hint flag.** It plans on its own. Running with the
  hint on (F7) additionally paints the driven piece and enables the session's
  refusal self-healing, but neither is required. (An earlier draft forced the
  flag on per-run; review found that leaks the user's preference across locks on
  the success path, so the force was removed.)
- **Selection requires an observable glow.** The glow follows the game's own
  handler (not the UE4SS hook), so confirming it does not depend on a
  Lua-initiated press re-entering the input hook. When the selected look is not
  distinctive (`selectedSig` nil) the driver cannot confirm selection from
  reality, so it aborts honestly rather than trust input counting.
- **Inert-input diagnostic.** If nothing the run pressed has ever moved a piece,
  the no-effect log says programmatic input may be inert on this build (the
  documented input-state-dependent case), distinct from a normal refusal.
- **Bind each run to its session** (`freshen`) so a run left set from a previous
  or stopped lock cannot make the next hotkey read as a cancel.

Tunables (hardcoded in the driver): `WAIT_TICKS`, `NUDGE_MAX_FULL` /
`NUDGE_MAX_SINGLE`, `SELECT_TICKS`, `MOVE_GRACE`, `DEVIATION_MAX`.

### `core/session.lua` (two additive seams, no measurement change)

- `Session:resyncSelection()`: read-only helper that calls the existing private
  `selSync` (glow truth) and returns `s.selectedRow`, for the driver to confirm a
  selection drive.
- One call at the very end of `tick()` (after `retint`): if `s.autopilot` is set,
  `pcall` `s.autopilot:step(s)`; on error, disengage auto-solve without killing
  the session. Nil autopilot means zero behavior change. This is the seam that
  makes the driver tick-driven instead of a second loop, reusing the session's
  settle detection, glow sync and move processing rather than re-implementing
  them.

### `main.lua` tail (registration only)

- Two debounced binds (0.3s `os.clock()` debounce each, mandatory because hot
  reload accumulates handlers): F6 to single-step, Shift+F6 (key + modifier from
  `config.lua`) to toggle full-auto. Real work deferred via `ExecuteInGameThread`;
  the handler only arms the driver against `liveSession`. Gated on the NextMove
  feature being healthy (`AutoSolveBroken`).
- The driver instance is main-owned and reads the current task through the
  main-owned `FreshTask` cache (a `getTask` closure); teardown rides the existing
  session lifecycle (the seam stops being called when the session stops; the
  `RegisterInitGameStatePostHook` backstop already nils `liveSession`).
- Add `"autosolve.driver"` to the hot-reload reset block (nil it in
  `package.loaded` by its exact dotted name) AND to `tests/check_load.lua`.
- Add a banner segment listing the auto-solve binds.

### `config.lua`

- `autoSolveStepHotkey = "F6"`
- `autoSolveFullHotkey = "F6"`
- `autoSolveFullModifier = "SHIFT"` (`"SHIFT"`/`"CONTROL"`/`"ALT"`/`""`), resolved
  to `ModifierKey[...]` and passed as `RegisterKeyBind(Key, { mod }, cb)`.
- All configurable; empty string disables that bind.

## Configuration surface

| Key | Default | Effect |
| --- | --- | --- |
| `autoSolveStepHotkey` | `"F6"` | Single-move bind; empty disables |
| `autoSolveFullHotkey` + modifier | `Shift+F6` | Full-auto toggle; empty disables |

Pacing, deviation policy, and risk posture are hardcoded per the decisions
below; they are not config surface in v1.

## Risk posture (decided)

- **Act as soon as the planner has a move.** Do not wait for the edge model to
  be fully learned. The model is lossy and learned by observation, so an early
  auto-move can be refused and burn a pick. Accepted.
- **Recoverable wait-then-nudge** (planner still searching, or direction not yet
  calibrated): wait up to a maximum time for a real move to appear. If the budget
  elapses, play a small number of "possible" moves (legal per
  `Solver:moveValid` on the known model) to nudge the state and let direction
  calibrate from the observed result. Re-evaluate after the nudges. Two named
  constants: `AUTOSOLVE_WAIT_MS` (max wait) and `AUTOSOLVE_NUDGE_MAX` (how many
  possible moves to try). Both hardcoded in the driver in v1.
- **Hard abort + one log line.** Conditions that abort immediately, no nudge:
  bar-anchor read failed (`stateUnknown`), no mined graph for this lock at all
  (cannot compute any legal move), planner has latched no-route (provably
  unsolvable from here), or no legal "possible" move exists to nudge with. Fail
  loud, no silent retry. Consistent with two-strikes.
- **Native-call safety:** the press primitive is `pcall`-wrapped and
  liveness-checked per call. `pcall` does not catch native access violations, so
  liveness discipline is the real guard, not the wrap.
- **Hot-reload double-act:** binds and the run loop live only in `main.lua`'s
  tail with debounce, so CTRL+R cannot stack handlers or burn picks.

## Performance notes

- Single-step is one user-driven action; no hot path.
- Full-auto fires opportunistically (confirm-then-fire), not on a fixed timer,
  so it is bounded by how fast presses are honored and how fast reads settle.
  The confirm read reuses the existing snap pipeline; no new per-frame cost.

## Decisions and remaining unknowns

- **O1 (resolved):** no hard abort when the planner has not produced a move yet
  or direction is uncalibrated. Wait up to `AUTOSOLVE_WAIT_MS` for a real move;
  if none comes, play up to `AUTOSOLVE_NUDGE_MAX` legal "possible" moves to nudge
  the state and calibrate direction from the observed result, then re-evaluate.
  See the wait-then-nudge entry under Risk posture.
- **O2 (resolved):** selection is driven by Up/Down with a glow re-read confirm
  each step. Selection navigation is treated as free (no durability cost).
- **O3 (resolved):** F6 stays single-step-only. It does not cancel a full-auto
  run. Shift+F6 toggles full-auto off.
- **O4 (empirical, in-game only, still unknown):** whether back-to-back presses
  are honored or dropped mid-animation at the "as fast as honored" pace; whether
  the credited-unlock path still credits the right object when the open is
  triggered by injected presses. The deviation-replan loop is the mitigation if
  presses drop. We learn these at the smoke test.

## Done criteria

- F6 executes exactly the next solver move and stops, logging the move. On bad
  state it does nothing and logs why.
- Shift+F6 runs to open, firing as fast as presses are honored; replans once on
  a deviation and stops on a second consecutive deviation; cancels on a second
  Shift+F6; auto-stops and logs on a successful unlock.
- Selection re-targets correctly via glow confirm; no Left/Right press lands on
  the wrong pin in normal play.
- No crash across repeated use, save-load, and hot reloads. No double-act after
  CTRL+R.
- Solver and geometry untouched (no `tools/sim_planner.py` regression expected).
  Validation is an in-game smoke test of the press path, selection resync, the
  per-step confirm, the full-auto deviation replan, and teardown.
