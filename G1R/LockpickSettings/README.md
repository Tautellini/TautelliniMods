# LockpickSettings

More lockpick tries, a next-move hint and a connection display for
Gothic 1 Remake, shipped as the UE4SS Lua mod `LockpickSettings`.

## What it does

When the lockpicking minigame starts, the mod raises your lockpick
durability (failures before the pick breaks) from the vanilla tier value
to vanilla + bonus:

| Skill tier | Vanilla tries | With mod (default) |
|------------|---------------|--------------------|
| Untrained  | 2             | 12                 |
| Trained    | 4             | 14                 |
| Master     | 6             | 16                 |

Every tier gets the same bonus, so skill progression keeps mattering.

It also offers two optional assists, both off by default and toggleable
ingame at any time (even mid-pick; the mod follows every lock from its
start, the keys only switch the highlights):

- Next-move hint (`showNextMove`, F7): the piece you should move next
  lights up, green when the correct turn is LEFT, blue when it is
  RIGHT, recomputed after every move from the lock's live state. The
  direction colors calibrate themselves from your first move. The
  master perk (removing connections when a pick breaks) keeps its
  full value
- Connection display (`showConnections`, F8): the pieces connected to
  your currently selected piece light up, purple when they travel the
  SAME direction as the selected piece, red when they travel OPPOSITE.
  Selection is tracked from the minigame's own input events (keyboard
  and controller), re-anchors on every actual move, and resyncs each
  tick from the game's own selected-look material signature. Caveat:
  the display shows the authored layout; connections the game silently
  removed at runtime keep showing until a move disproves them and the
  mod prunes them

## Configuration

Edit `Scripts/config.lua`, then restart the game or press CTRL+R ingame:

- `baseTries`: vanilla tries per tier. Used to recognize the tier at
  minigame start and as the base the bonus is added to. Only update these
  if a game patch changes the vanilla values
- `extraTries`: the bonus added on top of the base (default 10)
- `showNextMove`: next-move hint state at game start (default false)
- `nextMoveHotkey`: key that toggles the hint ingame, takes effect
  immediately even mid-minigame (default `"F7"`, `""` disables)
- `hintColorLeft` / `hintColorRight`: hint colors as `{r, g, b}`,
  encoding which way to turn the hinted lock (defaults: green = left,
  blue = right; set both equal for a plain directionless hint)
- `showConnections`: connection display state at game start (default
  false)
- `connectionsHotkey`: key that toggles the connection display
  (default `"F8"`, `""` disables)
- `partnerColorSame` / `partnerColorOpposite`: connected-pieces colors
  as `{r, g, b}`, by drag direction relative to the selected piece
  (defaults: purple = same, red = opposite)
- `debugSolver`: log solver internals to the UE4SS log (default false)

The hint tints the piece to move next green and replans after every
move from the lock's live state. Mined lock data can contain
connections the game removed at runtime (suspected skill/precision
mechanic); the mod prunes them as it observes your moves, so a hint can
occasionally be one move behind reality.

## Install / update

From the repo root:

```powershell
powershell -File tools\deploy.ps1 -Mod LockpickSettings
```

This copies `Scripts/` and the `enabled.txt` activation marker to
`G1R\Binaries\Win64\ue4ss\Mods\LockpickSettings` (UE4SS starts any mod
folder containing `enabled.txt`, no `mods.txt` entry needed). Requires
a working UE4SS setup, see the G1R modding guide (`../README.md`).

## How it works

- A single UE4SS `NotifyOnNewObject` callback on `AbilityTask_LockPick`
  fires when the minigame starts and adjusts `LockpickDurability` on the
  player's `AttributeSet_Lockpicking`
- The durability value itself identifies the skill tier: a vanilla base
  value gets raised, an already-raised value is recognized and left alone
  (idempotent, nothing can stack across sessions or saves), anything else
  is left untouched and logged
- The next-move hint uses the connection graphs shipped in
  `Scripts/lockgraphs.lua`, extracted offline from the game's compiled
  AngelScript blob (`tools/extract_locks.py`); the running game exposes
  no readable graph, and the graph is the ONLY thing taken from mined
  data. Everything else is measured live, because the game re-scrambles
  starting positions on every attempt: piece positions come from the
  `MPC_Lockpicking` material collection (the one read mechanism that
  never failed), the rail axis from the slot cloud itself (differencing
  adjacent-row differences cancels the row direction), the step size
  fitted by grid-snapping, and the rotations anchored by the integer
  offset that fits every piece on the rail
- Planning runs on an integer-encoded persistent bidirectional BFS
  (states are base-7 numbers), sliced across ticks with a budget, under
  the verified rules: atomic moves (rejected entirely if any dragged
  piece would leave its rail), no freezing, goal = all pieces centered.
  Connections the game deactivated at your skill level are learned and
  pruned from observed moves, and hypothesized dead when the full graph
  yields no plan. A lean poll tick (2.5x/s, cached references only)
  watches for settled moves and re-asserts all tints; everything dies
  with the minigame scene
- The assists listen READ-ONLY to the minigame task's own input
  handlers (Up/Down for selection, Left/Right to calibrate the hint
  colors against the observed pin movement); these engine-dispatched
  hooks fire for keyboard and controller. Nothing is intercepted or
  modified. AS-internal natives still cannot be hooked (they bypass
  UFunction dispatch, see the modding guide)
- The raised value is written to the attribute and can end up in saves.
  This is harmless: at the next minigame start it is recognized and left
  alone, and the game appears to re-derive durability from the skill tier
  when a save loads, so stats return to vanilla without the mod

## Troubleshooting

Check `G1R\Binaries\Win64\ue4ss\UE4SS.log` for `[LockpickSettings]` lines:

- On game start: `Loaded: untrained 2->12, trained 4->14, master 6->16,
  next-move hint off (416 lock graphs, toggle: F7), connection display
  off, toggle: F8`
- On each pick attempt: `Minigame: trained tier, tries 4 -> 14`
- `durability X not a known tier, leaving it alone`: a game patch likely
  changed the vanilla tier values; update `baseTries` in the config
- `live lock state not readable, next-move hint disabled for this
  lock`: the geometry derivation rejected the measured positions (rare;
  the connection display still works there)
- `Next-move hint error, stopping`: the solver shut itself down for
  this lock; picking continues unaffected, the next lock starts fresh
- `debugSolver = true` logs the full solver internals (derived state,
  moved sets, plans, calibrations) for bug reports
