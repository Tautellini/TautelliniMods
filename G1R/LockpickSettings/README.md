# LockpickSettings

More lockpick tries, a next-move hint, a connection display, an
auto-solver, an optional immersive mode and ore rewards for Gothic 1
Remake, shipped as the UE4SS Lua mod `LockpickSettings`.

## The minigame rules (canon, player-verified 2026-06-07)

These are the ground-truth game rules. When any observation appears to
contradict them, the MEASUREMENT is wrong, not the rules; one full day
of debugging was spent relitigating the goal because drifting
measurements made pins-at-center look like a non-win. Do not repeat
that.

- Every lock has N pieces on horizontal rails; each piece's PIN has
  exactly 7 possible positions
- THE GOAL IS ALWAYS ALL PINS ON POSITION 4 (the center), for every
  lock. There is no per-lock goal column and no confirm input: the
  lock opens BY ITSELF the instant the last correct move lands
- The controls are inverted: pressing LEFT moves a pin RIGHT and vice
  versa (the mod's direction colors encode the PRESS to make, measured
  against observed pin motion, so the inversion is transparent)
- Connections drag partner pieces atomically and directionally per the
  mined graph; a move is refused entirely (NOTHING moves, the piece
  shakes) when the moved pin or any dragged pin would leave its rail
- A REFUSED MOVE COUNTS AS A FAIL and costs pick durability; at zero
  the pick breaks and the lock re-scrambles mid-session
- Starting positions can equal the authored layout (locks do not
  necessarily re-scramble per attempt; a mid-session break DOES
  re-scramble)
- The game removes the FIRST round(LockpickPrecision) connections of the
  lock's authored-order list at minigame setup (confirmed by reversing the
  minigame). LockpickPrecision is the 0/1/2 skill value and is not raised
  mid-minigame or on a broken pick, so this is 0, 1, or 2 connections; the
  mined graphs are the full, unpruned set

## What it does

When the lockpicking minigame starts, the mod raises your lockpick
durability (failures before the pick breaks) from the vanilla tier value
to vanilla + bonus:

| Skill tier | Vanilla tries | With mod (default) |
|------------|---------------|--------------------|
| Untrained  | 2             | 7                  |
| Trained    | 4             | 14                 |
| Master     | 6             | 26                 |

Higher tiers get a bigger bonus (default 5/10/20 on top of vanilla), so
skill progression keeps mattering.

It also offers two optional assists, both off by default and toggleable
ingame at any time (even mid-pick; the mod follows every lock from its
start, the keys only switch the highlights):

- Next-move hint (`showNextMove`, F7): the piece you should move next
  lights up, green when the correct press is LEFT, blue when it is
  RIGHT, recomputed after every move from the lock's live state. The
  direction colors are derived from the lock's fixed geometry and the
  camera. YELLOW means honest uncertainty: either the direction is not
  measurable yet (rare, resolves within a second), or the hinted move
  is an anchor probe on a low-information scramble, it may click or
  may be refused with a shake, and either outcome teaches the solver
  the lock's exact frame. Routes
  are planned greedily (frame stability over optimality), so early
  hints can look like a detour but end at an open lock. When a
  scrambled start hides where the rail center is, the solver may aim
  one beside it once, notice the lock did not open, correct itself and
  continue; pins walking one extra round is that correction at work,
  not a malfunction. The master perk (removing connections when a pick
  breaks) keeps its full value
- Connection display (`showConnections`, F8): the pieces connected to
  your currently selected piece light up, purple when they travel the
  SAME direction as the selected piece, red when they travel OPPOSITE.
  Selection is tracked from the minigame's own input events (keyboard
  and controller), re-anchors on every actual move, and resyncs each
  tick from the game's own selected-look material signature. Caveat:
  the display shows the authored layout; connections the game silently
  removed at runtime keep showing until a move disproves them and the
  mod prunes them

### Auto-solve, Immersive Mode and Rewards

- Auto-solve (`autoSolveHotkey`, F6): press F6 during a lock to have the
  mod solve it for you in a couple of seconds (press again to cancel).
  Shift+F6 toggles full-auto, which solves every lock the moment it
  opens. The solve still earns the lockpicking achievement. Off by
  default. It can optionally spend a flat number of lockpicks per solve
  (`autoSolveLockpickCost`, 0 = free). With fewer than that in your pack
  the auto-solver does nothing and the tooltip says why
- Immersive Mode (`immersiveMode`, off by default): makes the F6
  auto-solve COST lockpicks and REQUIRE skill, both scaled by the lock's
  difficulty (its connection count). A small panel on the minigame shows
  the lock's difficulty, your lockpicks, the pick cost and the skill it
  needs, turning red when you cannot meet it. A solve you cannot afford
  or lack the skill for is refused. While it is on, the Shift+F6
  full-auto mode is disabled, so there is no free clearing of every
  lock. The skill demanded comes from two connection thresholds
  (`skilledAtConnections`, `masterAtConnections`). The lockpick cost
  comes from `lockpicksPerConnection`, clamped to `lockpickCostMin` and
  `lockpickCostMax`. Every one of these, plus the durability and the two
  assists, is also editable ingame in the SharedModMenu
- Rewards (`oreReward`, off by default): give ore on a successful pick
  (by hand or auto), scaled by the lock's difficulty. The amount is
  `orePerConnection` per connection, clamped to `oreRewardMin` and
  `oreRewardMax`. The item added is `oreRewardItem`, an ore nugget by
  default

On-screen feedback is two layers: the panel on the minigame (the
immersive cost and skill, or the auto-solver's "not enough lockpicks"
status), and the pop-up notifications for lockpicks spent and ore found.
Each can be turned off in the menu's Configuration section
(`showTooltip`, `showNotifications`).

## Configuration

Edit `Scripts/config.lua`, then restart the game or press CTRL+R ingame:

- `extraTries`: the per-tier bonus added on top of the vanilla base
  (defaults: untrained 5, trained 10, master 20). The vanilla per-tier
  values (untrained 2, trained 4, master 6) are game constants and live
  in the code (`Scripts/tries/boost.lua`, as `boost.BASE_TRIES`), not in
  config, so 2/4/6 become 7/14/26 by default
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
- `debugSolver`: log solver internals to the UE4SS log (default true
  during the alpha, so bug reports carry a solver trace; set false for
  quiet play)

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

This copies `Scripts/` recursively (its `core/`, `util/`, `data/` and
feature subfolders) plus the `enabled.txt` activation marker to
`G1R\Binaries\Win64\ue4ss\Mods\LockpickSettings`, and vendors a private
copy of the shared library (the kit) into `<Mod>/shared/kit/`, so the
deployed mod is self-contained. UE4SS starts any mod folder containing
`enabled.txt`, no `mods.txt` entry needed. Requires a working UE4SS
setup, see the G1R modding guide (`../README.md`).

## How it works

- A single UE4SS `NotifyOnNewObject` callback on `AbilityTask_LockPick`
  fires when the minigame starts and adjusts `LockpickDurability` on the
  player's `AttributeSet_Lockpicking`
- The durability value itself identifies the skill tier: a vanilla base
  value gets raised, an already-raised value is recognized and left alone
  (idempotent, nothing can stack across sessions or saves), anything else
  is left untouched and logged
- The next-move hint uses the lock connection graphs the mod SHIPS in
  `data/lockgraphs.lua` (the state of truth, read at load). Decoding them live
  from the game's compiled AngelScript cache
  (`G1R/Script/PrecompiledScript_Shipping.Cache`) was tried but failed for too
  many players, so the data is bundled and maintained: the mod is not
  automatically compatible with a new game version or with other lock-layout
  mods, and the shipped data is regenerated on a game update with the dev tool
  `tools/livegraphs.lua`. The graph is the ONLY thing taken from the game's
  data. Everything else is measured live, because mined rotations
  cannot be trusted for the current state (a break re-scrambles, and a
  save reload can even swap a chest's entire lock config: the game
  assigns random locks per save-state): piece positions come from the
  `MPC_Lockpicking` material collection (the one read mechanism that
  never failed), the rail axis from the slot cloud itself, the step
  size fitted by grid-snapping, and the rotations snapped ABSOLUTELY
  onto that grid every settle
- The anchor (which rail column is the open center) is a DIRECT READ,
  not a guess. Every piece's bar part sits on one fixed column for the
  whole session, and that column IS the open column (measured 252/252
  over a full solved session). The mod reads those bar part roots,
  validates the column against the plate grid (it must put every piece
  on an in-range integer position), and adopts it. If the read fails or
  is ambiguous (no clear column, or two columns both fit), the mod
  honestly disables the next-move hint for that lock instead of
  guessing; the connection display still works there
- Planning runs on an integer-encoded persistent greedy best-first
  search (states are base-7 numbers), sliced across ticks with a
  budget, under
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

- On game start: `Loaded: untrained 2->7, trained 4->14, master 6->26,
  next-move hint off (416 lock graphs from bundled, toggle: F7), connection
  display off, toggle: F8` (`from bundled` = the shipped `data/lockgraphs.lua`,
  the only source; a live decode was tried and dropped, see How it works)
- On each pick attempt: `Minigame: trained tier, tries 4 -> 14`
- `durability X not a known tier, leaving it alone`: a game patch likely
  changed the vanilla tier values; update `boost.BASE_TRIES` in
  `Scripts/tries/boost.lua`
- `live lock state not readable, next-move hint disabled for this
  lock`: the geometry derivation rejected the measured positions (rare;
  the connection display still works there)
- `Solver: pins measured centered but the lock did not open,
  measurement distrusted, next-move hint disabled`: a measurement and
  the minigame canon disagreed, so the hint stops for this lock rather
  than fight it (connection display unaffected)
- `Edge X->Y inactive this session, pruned`: the game removed that
  connection at runtime (skill mechanic); the solver learned it from
  your moves, normal behavior
- `Next-move hint error, stopping`: the solver shut itself down for
  this lock; picking continues unaffected, the next lock starts fresh
- `debugSolver = true` logs the full solver internals (derived state,
  moved sets, plans, calibrations) for bug reports
