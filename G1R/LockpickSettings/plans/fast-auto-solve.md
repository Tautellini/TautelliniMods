# Fast Auto-Solve (Ctrl+F6)

Spec for a fast full-auto mode. The existing full-auto (Shift+F6) solves
correctly but slowly: one move per ~400 ms settled tick, each waiting out the
piece glide. When the player has handed the lock to the solver and makes no
further input, the run is fully deterministic, so the route can be executed as
fast as the game honors the moves. Fast mode trades the conservative cadence for
speed while keeping the SAME correctness and durability safety. Written
2026-06-09 after a design pass. Companion: `auto-solve-hotkey.md`, `../README.md`.

## Goal

`Ctrl+F6` (STRG+F6) toggles a fast full-auto that drives the lock to open as fast
as the moves are honored, by (a) collapsing the move animation and (b) firing the
next move the instant the previous one snaps, not on a fixed timer. A second
`Ctrl+F6` cancels; it stops by itself on open. `F6` (step) and `Shift+F6`
(adaptive full-auto) are unchanged.

## Decided (this design pass)

- **Fire-on-snap cadence.** The next move fires the instant the previous settles,
  NOT on a fixed gate/timer. With animations collapsed this is effectively
  back-to-back.
- **Collapse the animation** by cranking `GothicLockSceneActor.
  m_LockPieceInterpolationSpeed` (a reflected, writable float) for the run, and
  restoring it on stop. Read it back to learn whether the game re-asserts it.
- **Reuse the precomputed route while it holds**; do not recompute from scratch
  every move (the solver already caches and advances `s.plan`).
- **Recalculate the instant a planned move is impossible on the live lock** (a
  refused shake, or the observed post-move state diverges from the route's
  prediction). This is the existing deviation->replan path, run at speed.
- **Bounded rounds.** Allow a few replan rounds (`FAST_ROUNDS`); if still
  unsolved, STOP cleanly with one log line. The existing cycle detector
  (`CYCLE_LIMIT`) still catches oscillation.
- **Safety intact.** Never press a model-illegal move; a refused move is a FAIL
  that costs durability, so keep the same shake detection and refusal handling as
  Shift+F6. The durability boost cushions the rare under-approximation refusal.
- **MOVE-AND-PRESERVE.** The solver, geometry and snap math are untouched; the
  full route already exists in the solver. Fast mode is a driver mode + a cadence
  change + one engine write.

## Background (settled, do not re-litigate)

- `nextmove/solver.lua` already produces a full deterministic route to the
  all-center goal and caches it (`s.plan`), surfacing the next step via
  `Solver:plan(s)`. "Compute one path" is already done.
- The live edge model is an UPPER BOUND: the game removes ~`LockpickPrecision`
  connections at runtime. A removed edge makes a planned move drag FEWER pieces,
  so the move still executes (it is not refused) but the state can DIVERGE from
  the route. A missing edge (rare extraction error) is the opposite: an
  unpredicted drag that can refuse a move and cost durability.
- Input presses are the only act path; selection lives only on the GPU and is
  driven by Up/Down with a glow re-read confirm.
- The cadence today is the 400 ms `LoopAsync` poll; the snap math runs inside it
  but the cadence is NOT the measurement.

## Architecture

### Engine: interpolation control (`core/engine_lock.lua`)

A new pcall-wrapped primitive to set and restore the scene actor's interpolation
speed (and possibly `m_UseConstantInterpolationSpeed` / `m_ShakeSpeed`), liveness
checked per call. The original value is captured at fast-run start and restored on
stop/teardown so normal play is unaffected. If the game re-asserts the value, the
fast loop rewrites it each tick.

### Cadence: a tight fast-mode loop

In fast mode the session drives a TIGHT settle loop (target ~30-50 ms, cached
references only, no `FindAllOf`) instead of waiting on the 400 ms poll. Settle =
slots stable for one tick. This is a cadence change, not a measurement change. It
must be profiled for hitches; the existing poll already does cached slot reads at
2.5x/s, this pushes the same reads faster for the short duration of a solve.

### Driver: a fast mode (`autosolve/driver.lua`)

Reuse the existing state machine. In fast mode, per snap: confirm the last move
matched the route's prediction (else replan from the observed state, which also
prunes the learned-dead edge), drive selection to the next piece, press. Fire the
next the instant the slots settle. Bounded by `FAST_ROUNDS` replans; stop on
goal, on the round limit, on a cycle, or on bad state. All the Shift+F6 safety
(shake = refusal, model-legal check, selection-needs-glow) carries over.

### main.lua tail (registration)

A `Ctrl+F6` bind (config `autoSolveFastModifier = "CONTROL"` on the auto-solve
key, or a dedicated `autoSolveFastHotkey`), debounced, deferred via
`ExecuteInGameThread`, arming the fast driver against `liveSession`. Teardown
restores the interpolation speed (rides the session lifecycle, like the existing
auto-solve seam).

## Open questions, empirical (probe BEFORE building the mode)

1. **LINCHPIN -- RESOLVED (AnimSpeedProbe, play-confirmed 2026-06-09): YES.**
   Writing `m_LockPieceInterpolationSpeed` collapses the glide to an instant snap.
   The write succeeds (reflected, `ok=true`) and the value STICKS: read back 1000
   twelve seconds and several moves later, the game does NOT re-assert it. So the
   fast mode writes a large value ONCE at run start and restores on stop, no
   per-tick rewrite. Baseline is `20.0` with `m_UseConstantInterpolationSpeed =
   true` (units/sec); `m_ShakeSpeed=50` / `m_ShakeDuration=0.5` can collapse the
   refusal shake too. So the cadence, not the animation, is now the only thing
   between us and "super fast".
2. Are back-to-back presses honored once a piece snaps, or dropped mid-transition?
   (The unresolved O4 from `auto-solve-hotkey.md`.)
3. Selection driving at speed: does the glow re-read confirm keep up at a ~30 ms
   cadence, or does fast mode need a different selection-confirm?
4. Does the credited-unlock still fire when the open is triggered by rapid
   injected presses?
5. Does a ~30 ms cached-read poll cause hitches?

## Open questions, decisions

- `FAST_ROUNDS` before giving up (start 3-4).
- The interpolation speed value, and whether to also speed `m_ShakeSpeed`.
- On give-up: stop with a line, or fall back to the adaptive Shift+F6 loop to
  finish? (Leaning: stop, the player can re-arm.)
- Whether fast mode also collapses the final OPEN animation (cosmetic).

## Done criteria

- `Ctrl+F6` solves a model-matching lock visibly faster than `Shift+F6`, replans
  on divergence, stops after `FAST_ROUNDS` unsolvable rounds, and restores the
  interpolation speed on stop.
- No extra durability loss versus `Shift+F6`; no crash across use, save-load and
  hot reload.
- Solver and geometry untouched (no `tools/sim_planner.py` regression).
- Validation is an in-game smoke test: the linchpin probe first, then the mode.
