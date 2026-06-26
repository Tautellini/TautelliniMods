# Technical Debt: LockpickSettings

A register of known shortcuts and the investigation needed to retire them. Add
new items as TD-N. Related: `../README.md`, `../LuaModdingSurface.md`,
`../reference/blob-format-notes.md`.

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

## TD-2: the connection graph is shipped data; make the live model self-correct

**Settled, not a shortcut.** The mod ships `data/lockgraphs.lua` and reads it
directly; it does not read the game's live data at runtime. A runtime live decode
of `PrecompiledScript_Shipping.Cache` was built and shipped (3.0.4-3.0.7) but
failed for too many players, so it was reverted (3.0.8). The decoder survives as
the dev-side regen tool `tools/livegraphs.lua`. Full record: the CLAUDE.md hard
rule, memory `lockpick-livegraphs-fallback`, and that tool. Accepted consequence:
the mod is not automatically compatible with a new game version or a lock-layout
mod, so we regenerate the data on a game update.

**Why live is the only alternative, and why it is closed** (resolved 2026-06-09
against the full 62 MB object dump): the connection graph is neither readable nor
capturable from the running game. `GothicLockConfig` exposes only `m_UniqueName`
plus the write-only `AddPiece`/`AddConnection`; the `LockConnections` /
`LockOneConnection` structs are reflected but wired to no property or function;
and the build calls cannot be hooked (AngelScript bypasses UFunction dispatch,
confirmed against `HookProcessInternal` and `HookCallFunctionByNameWithArguments`,
both enabled). So the graph exists at runtime only in the compiled `.Cache` and in
the lock's AngelScript-private memory, neither reachable by Lua.

**The real open debt** (make the runtime model self-correct, since the export has
extraction errors like the `BT_Chest_02_Lock` oscillation):
- Edge-learning should ADD, not only prune. Today the model trusts the export as a
  superset and only prunes; `BT_Chest_02_Lock` is the opposite, an
  under-approximation where a move drags a piece the model lacks and the learner
  cannot recover. Detect "an unpredicted partner moved" and add that edge live.
  (Deliberately probing to map a whole lock was rejected: it costs pick durability
  and is unreliable.)
- Audit the export against live observation (piece-count mismatches like the 7-vs-6
  in TD-1, refused model-valid moves) to find where authored graphs disagree with
  reality, and whether a per-lock data fix or a self-correcting learner is the cure.
- Read rotations more directly if safe: each piece's `m_RuntimeRootComponent`
  relative rotation may replace the MPC-slot snap math (mind the part-actor crash
  history in `../LuaModdingSurface.md`).
