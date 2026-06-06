# LockpickSettings

More lockpick tries and a connection-memory assist for Gothic 1 Remake,
shipped as the UE4SS Lua mod `LockpickSettings`.

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

It also offers a next-move hint (`showNextMove`): the piece you should
move next lights up, green when the correct turn is LEFT, blue when it
is RIGHT, recomputed after every move from the lock's live state. It is
entirely state-driven: no input tracking, identical behavior with
keyboard and controller. Tracking runs from the start of every lock;
the hotkey only toggles the paint, so switching it on mid-pick is
exact. The master perk (removing connections when a pick breaks) keeps
its full value.

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
- The next-move hint uses lock layouts shipped in
  `Scripts/lockgraphs.lua`, extracted offline from the game's compiled
  AngelScript blob (`tools/extract_locks.py`); the running game exposes
  no readable graph. Live piece positions come from the game's
  `MPC_Lockpicking` material collection (Slot_i = world position of
  piece i), the goal rotation from the scene's `m_RotationToBarOffset`,
  and a budgeted BFS finds the shortest move sequence. A lean poll tick
  (2.5x/s, cached references only) detects settled moves, prunes
  connections the game deactivated, replans, and re-asserts the green
  tint via the piece's dynamic material parameter `HighlightColor`.
  Everything dies with the minigame scene
- No hotkeys, no function hooks. G1R/AS natives cannot be intercepted
  from Lua (hooks register but never fire, see the modding guide), and a
  boost-and-restore design would need exactly that machinery to detect
  the end of the minigame
- The raised value is written to the attribute and can end up in saves.
  This is harmless: at the next minigame start it is recognized and left
  alone, and the game appears to re-derive durability from the skill tier
  when a save loads, so stats return to vanilla without the mod

## Troubleshooting

Check `G1R\Binaries\Win64\ue4ss\UE4SS.log` for `[LockpickSettings]` lines:

- On game start: `Loaded: untrained 2->12, trained 4->14, master 6->16,
  connection view on`
- On each pick attempt: `Minigame: trained tier, tries 4 -> 14`
- On each discovered connection: `Connection discovered, tinting group
  (color 1)`
- `durability X not a known tier, leaving it alone`: a game patch likely
  changed the vanilla tier values; update `baseTries` in the config
- `Connection view error, stopping`: the watcher shut itself down (a
  game patch may have changed the scene classes); picking continues
  unaffected without tints
