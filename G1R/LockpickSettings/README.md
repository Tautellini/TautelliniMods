# LockpickSettings

More lockpick tries for Gothic 1 Remake, shipped as the UE4SS Lua mod
`LockpickSettings`.

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

## Configuration

Edit `Scripts/config.lua`, then restart the game or press CTRL+R ingame:

- `baseTries`: vanilla tries per tier. Used to recognize the tier at
  minigame start and as the base the bonus is added to. Only update these
  if a game patch changes the vanilla values
- `extraTries`: the bonus added on top of the base (default 10)

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
- Deliberately minimal: no hotkeys, no polling loops, no function hooks.
  UE4SS script hooks crash against this game's AngelScript layer, and a
  boost-and-restore design would need exactly that machinery to detect
  the end of the minigame
- The raised value is written to the attribute and can end up in saves.
  This is harmless: at the next minigame start it is recognized and left
  alone, and the game appears to re-derive durability from the skill tier
  when a save loads, so stats return to vanilla without the mod

## Troubleshooting

Check `G1R\Binaries\Win64\ue4ss\UE4SS.log` for `[LockpickSettings]` lines:

- On game start: `Loaded: untrained 2->12, trained 4->14, master 6->16`
- On each pick attempt: `Minigame: trained tier, tries 4 -> 14`
- `durability X not a known tier, leaving it alone`: a game patch likely
  changed the vanilla tier values; update `baseTries` in the config
