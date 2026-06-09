# Technical Debt: LockpickSettings

A register of known shortcuts and the investigation needed to retire them. Add
new items as TD-N. Related: `plans/auto-solve-hotkey.md`, `../README.md`,
`../LuaModdingSurface.md`, `../reference/blob-format-notes.md`.

## TD-1: collect pieces from the game's `m_LockPieceData`, not `FindAllOf`

**The debt.** The mod gathers the minigame's piece actors through a fallback
cascade: fresh `NotifyOnNewObject` spawns, then
`LockPickSubsystem.m_PendingLockPieces`, then `FindAllOf("GothicLockPieceActor")`.
The `FindAllOf` last resort can return stale actors from earlier minigames, which
we paper over with spawn-time and age gates. The game already holds a clean,
per-minigame list we ignore.

**The refactor (high level).** In `core/session.lua` `Session.start`, build the
piece set from `scene.m_LockPieceData` (the per-lock array of
`{m_Plate, m_Bar, m_Latch}` actors), keyed by `m_PieceId`, limited to the graph's
piece ids, taking the MID off the plate actor. Keep the current cascade only as a
fallback for when `m_LockPieceData` is not ready, and re-confirm the anchor
geometry still derives from the new source. This touches play-verified
measurement code, so keep behaviour MOVE-AND-PRESERVE and run the Lua tests plus
an in-game smoke test (chests and doors).

**Findings (in-game probe, `BT_Tower_Door_Lock`, 2026-06-09).**
- `m_LockPieceData` is populated and clean at session start, keyed by `m_PieceId`.
- The plate actor carries the `m_MaterialInstanceDynamic`; bar and latch do not.
- It can hold more entries than the graph (7 actors, ids 0..6, for a 6-piece
  graph: a non-puzzle element), so filter to the graph's piece ids.
- It lives on `LockPickSubsystem.m_LockSceneActor`, which the session already
  caches as `s.scene`. Reflected and safe to read.
- Not a current bug, a robustness upgrade: it removes the contamination-prone
  `FindAllOf` path.

## Investigation plan: toward a fully live-data lock model

The bigger goal behind TD-1: reconstruct the whole lock from in-game reads and
drop the offline-extracted connection data in `data/lockgraphs.lua` (and its
extraction errors, for example the `BT_Chest_02_Lock` oscillation), so the mod
relies on what the game actually holds instead of workaround calculations.

**Where we already stand.**
- Live-readable today: piece rotations (via MPC `Slot_i` plus the snap math), the
  bar-column anchor and geometry, the piece actors (`m_LockPieceData`), and
  selection (the glow). The live STATE is reconstructable from the game.
- Not live-readable (confirmed by enumerating the whole lock surface in the
  object dump): the CONNECTION GRAPH. `GothicLockConfig` exposes only
  `m_UniqueName` plus the write-only `AddPiece`/`AddConnection`; the
  `LockConnections`/`LockOneConnection` structs are reflected but referenced by no
  property or function; and `AddConnection` cannot be hooked (AngelScript calls it
  through its own binding table, bypassing UFunction dispatch). The connections
  are the one thing we still take from the export.

So "fully live" comes down to getting the connections from the game. What to
investigate and fact-check next:

1. **Exhaustively rule out a reflected accessor.** We checked the obvious lock
   classes. Next: grep the dump for any property or function whose type is
   `LockConnections`/`LockOneConnection` (by struct address), any getter-shaped
   function (`Get*Connection*`, `Get*LockData*`) across ALL classes, and the
   per-lock AS subclasses' members (only spot-checked so far). Goal: a definitive
   yes/no on "nothing reflected returns the graph".

2. **Re-test hookability of the build calls.** Hooking `AddConnection` saw zero
   calls (AS bypass). Before concluding it is unobservable, fact-check the
   alternatives: does `RegisterCustomEvent` (which hooks by name) catch it? Do
   `HookProcessInternal` / `HookCallFunctionByNameWithArguments` (both enabled in
   `UE4SS-settings.ini`) see AS-native calls? If any do, we can capture the exact
   connections at lock-build time, which is the ideal source.

3. **Quantify mapping-by-observation.** Connections are inferable by moving a
   piece and watching the drag set and its directions (the solver already prunes
   this way). Measure: how many probe moves to fully map a typical lock, and can
   it be done at zero durability cost (only both-ways-movable pieces)? If a lock
   maps in a few free moves, a "learn the graph, then solve" mode could drop the
   export per lock.

4. **Make edge-learning ADD, not only prune.** Today the model assumes the export
   is a superset and only prunes. The `BT_Chest_02_Lock` bug is the opposite, an
   under-approximation: a move drags a piece the model lacks, and the learner
   cannot recover. Investigate detecting "an unpredicted partner moved" and adding
   that edge live. This self-corrects extraction errors while keeping the export
   as a prior, and also addresses the mover-misidentification suspected on
   `BT_Chest_02_Lock`.

5. **Read rotations more directly, if safe.** The current rotation is computed:
   read MPC slot positions, then snap to integers around a derived bar-column
   anchor. The piece actors carry `m_RuntimeRootComponent` (a transform). Fact
   check whether its relative rotation yields the pin rotation directly and
   safely, which could replace the snap math (mind the part-actor crash history in
   `../LuaModdingSurface.md`).

6. **Audit the export against live observation.** Use `m_LockPieceData`'s piece
   count and the observed drags to flag locks where the authored graph disagrees
   with reality (piece-count mismatches like the 7-vs-6 above, or refused
   model-valid moves). A small debug-gated in-game audit that logs disagreements
   would show how widespread the `BT_Chest_02_Lock` class of error is, and whether
   a per-lock data fix or a self-correcting learner is the better cure.

**Likely outcome.** Items 1 and 2 decide whether the connections can ever be read
or captured directly. If both are no (the current evidence leans that way), items
3 to 6 are the realistic path: keep the export as a prior, but add live learning
and an audit so the runtime no longer fully trusts it. That, with TD-1, gets us to
"mostly live and self-correcting" rather than "fully live", which is probably the
honest ceiling given the engine.
