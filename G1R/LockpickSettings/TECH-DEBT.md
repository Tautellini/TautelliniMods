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

1. **Exhaustively rule out a reflected accessor. RESOLVED (full
   `UE4SS_ObjectDump.txt`, 62 MB, 2026-06-09): nothing reflected returns the
   graph.** Searched the complete dump, not just the distilled `reference/`
   files:
   - The `LockConnections` (struct addr `12273A480`) and `LockOneConnection`
     (`12273A3C0`) ScriptStructs are referenced by ZERO property, return value or
     parameter anywhere in the dump (no `[ss:]` points at either). They are orphan
     types: defined, never wired to anything readable.
   - `GothicLockConfig`'s entire surface is one `NameProperty` (`m_UniqueName`)
     plus the two write-only natives `AddPiece(ID, Rotation)` and
     `AddConnection(ID, connectedId, Direction)`. All int params, no struct
     return.
   - The 341 named `*_Lock` AS subclasses and the 70 `Test_Lock_Difficulty_*`
     subclasses carry NO own reflected members; the graph lives only in their
     `__InitDefaults` bytecode (the offline extractor's source).
   - No getter-shaped function (`Get*Connection*`, `Get*LockData*`) exists on any
     G1R or lock class; the only dump matches are unrelated engine subsystems
     (Interchange, OnlineSubsystem, Niagara).
   So a reflected READ of the connection graph is conclusively ruled out. The one
   remaining way to get connections from the running game directly is to CAPTURE
   them at build time, which is item 2.

2. **Re-test hookability of the build calls.** Hooking `AddConnection` saw zero
   calls (AS bypass). Before concluding it is unobservable, fact-check the
   alternatives: does `RegisterCustomEvent` (which hooks by name) catch it? Do
   `HookProcessInternal` / `HookCallFunctionByNameWithArguments` (both enabled in
   `UE4SS-settings.ini`) see AS-native calls? If any do, we can capture the exact
   connections at lock-build time, which is the ideal source.

   **RESOLVED (in-game run 2026-06-09): not capturable either.** Confirmed
   `HookProcessInternal`, `HookProcessLocalScriptFunction` and
   `HookCallFunctionByNameWithArguments` are all `= 1` in this build's
   `UE4SS-settings.ini`. The dev-only mod `G1R/LockBuildProbe` armed every
   Lua-level capture seam at once (a `RegisterHook` on both `AddPiece` and
   `AddConnection`, which with those three flags on also tests the alternate
   dispatch points, plus a name-based `RegisterCustomEvent` on each) and counted
   every fire. Read-only: it never calls the write-only natives. Result across a
   fresh launch: all four seams armed OK at boot, four seconds BEFORE the first
   world load, yet two world loads, a minigame start and a manual check all
   reported `AddPiece=0 AddConnection=0` on every seam. The arm-before-instance
   timing rules out a missed window, so no UFunction-dispatch seam UE4SS can hook
   sees these calls. The zero is equally consistent with the AS-native bypass and
   with the calls running at AS module load (CDO init) before any Lua arms;
   neither reopens a Lua capture path, so the distinction is moot.

   **Conclusion (items 1 + 2): connections cannot be read OR captured from the
   running game.** The offline `lockgraphs.lua` export stays the only source for
   the graph. The realistic path is items 3 to 6 below: keep the export as a
   prior, add live learning and an audit so the runtime stops fully trusting it.

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

## Decision (2026-06-09): source the graph live from the game's own `.Cache`

Items 1 and 2 are both resolved no: the connection graph cannot be read (not
reflected) or captured (the build calls bypass every hookable dispatch point).
This session also closed the rest of the pure-Lua surface: the runtime lock
classes (scene actor, piece actors, subsystem) hold no adjacency in any shape;
`DebugConsoleCommands` and `GothicInputMarvinCheatManager` have zero reflected
members in the shipping build; and the Hazelight `AngelscriptCode` libraries
expose no generic "read an AS property / call an AS function by name" bridge, with
no AS debug-server class present. So the graph exists at runtime only in (a) the
game's compiled script cache file and (b) the instanced lock's AngelScript-private
memory, neither reachable by Lua reflection or hooks.

The chosen direction is NOT the move-learning of items 3 and 4 (rejected: it costs
durability and is unreliable). It is to **drop the bundled `data/lockgraphs.lua`
and decode the graph in-process from the game's own
`PrecompiledScript_Shipping.Cache` at runtime**, so the mod ships no lock data and
adapts to any mod that changes layouts via AS source plus to game patches.

**Proven (2026-06-09).** `tools/decode_locks.lua` is a faithful LuaJIT port of
`tools/extract_locks.py`. Run on the game's `.Cache`, it reproduces all 416 lock
graphs BYTE-IDENTICAL to the shipped `data/lockgraphs.lua` (verified by diff).
This confirms the decode runs entirely in the UE4SS runtime (LuaJIT), with no
Python and no external process. The whole-file read took ~6 s but is pure I/O on
122 MB; all lock data sits in 37.7M-42.2M, so the mod reads only that ~4.5 MB
slice (sub-second). The two native pointers are hardcoded in the proof; the
shipping port should auto-calibrate them per build for patch-robustness.

Remaining to ship (Approach A): confirm UE4SS Lua exposes file IO (one-line
in-game check), add a `.Cache`-reading data-source module that returns the same
`{ [name] = {pieces, connections} }` table the mod already consumes (path derived
from `main.lua`'s own location, region-limited read, optional load-time slicing),
decide the fallback when the file is unreadable (disable the hint vs. keep a
vendored snapshot), and keep the Python and Lua decoders as cross-check oracles.

**Field update (2026-06-09, shipped 3.0.6).** The live decode works for most
players but FAILS for some (logged `could not read the lock graphs from the game
cache`). The per-user root cause is still being gathered: 3.0.6 makes that error
self-diagnosing (it now logs the resolved `cachePath`, whether the file opened at
all, and the specific reason), so a failing log shows file-problem
(missing/permission/wrong path, e.g. a different distribution) vs decode-problem (a
game build whose bytecode the calibration does not match). The deferred fallback
decision above is now settled: KEEP A VENDORED SNAPSHOT.
`data/lockgraphs_fallback.lua` (byte-faithful to a verified live decode, 416
graphs) loads only when the live decode AND the self-written cache both fail. Load
order is live -> self-cache -> bundled fallback, so working players and
layout-mod players are unaffected (live still preferred); a failing-decode player
on a divergent layout is unsupported until the bundle is refreshed (accepted).

**Reversal (2026-06-09, shipped 3.0.8).** The live decode kept failing for too many
players (multiple on Steam/Windows, where neither a path nor permission story fits),
so the layered approach was abandoned: **the mod no longer reads live data at all.**
It ships `data/lockgraphs.lua` as the sole source of truth and reads it directly,
and we maintain it. The in-process decoder moved out of the shipped mod to
`tools/livegraphs.lua` (a dev/regen tool, kept because it is the cleanest way to
regenerate the shipped data on a game update). Accepted: the mod is NOT
automatically compatible with a new game version or with other lock-layout mods;
both require a refreshed `data/lockgraphs.lua`. The live-decode work remains
recorded above and in the tool, in case the approach is ever revisited.

The separate "wild calculations for piece positions" concern is item 5 (read each
piece's `m_RuntimeRootComponent` rotation directly instead of the MPC-slot snap
math); a distinct track, independent of where the graph comes from.
