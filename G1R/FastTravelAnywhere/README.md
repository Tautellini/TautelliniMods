# FastTravelAnywhere

Fast travel for Gothic 1 Remake. Open the world map, point at where you want to go, and press a
key to teleport there. Plus a quick-travel list of useful spots in the in-game menu. Shipped as the
UE4SS Lua mod `FastTravelAnywhere`.

> **Known limits.** The world map works at any resolution and aspect ratio. City/area maps are not
> wired up yet, and the cursor is read from the mouse (a controller-driven map cursor is not picked up).

## What it does

- **On-map teleport.** While the world map is open, hover the cursor over a destination and press
  **`T`**. You teleport there, dropped onto the ground (a downward trace finds the surface, so you
  do not fall through the world or land in the air).
- **Safe landing.** Before teleporting, the mod checks the click and lands on flat ground instead of
  a rock face. It keeps you on the exact click when that is already flat. When it is not, it widens
  the search in stages and moves you to the closest spot that is flat, open (not a ledge between
  rocks), and near the clicked elevation (so it never drops you into a canyon far below). If even the
  widened search turns up nothing safe, it skips the teleport rather than dropping you somewhere bad.
  All of this is on by default and every part can be toggled.
- **Quick travel.** A curated list of locations (Old Camp, New Camp, Swamp Camp, the mines, ...)
  appears as one-press buttons in the SharedModMenu, so you can jump to a known spot without opening
  the map.

The on-map placement is computed from your viewport and DPI scale, so it is accurate on any
resolution with no per-player setup.

## Requirements

- **UE4SS** installed for Gothic 1 Remake.
- **[SharedModMenu](https://github.com/Tautellini/TautelliniMods)** (optional) for the in-game menu
  tab. Without it the `T` hotkey still works; you just do not get the toggle and the quick-travel
  list.

## Install

Extract the zip into `...\Gothic 1 Remake\G1R\Binaries\Win64\ue4ss\Mods\` so you end up with
`Mods\FastTravelAnywhere\...`. Launch the game.

## Usage

| Action | How |
|---|---|
| Teleport to the cursor | Open the world map, hover a spot, press **`T`** |
| Quick travel | Open the SharedModMenu, pick a location under **Fast Travel** |
| Turn the on-map teleport off | Toggle **On-Map Teleport** in the menu (default on) |
| Land on the exact click | Toggle **Safe Landing** off in the menu (default on) |
| Only look right around the cursor | Toggle **Expand Search** off in the menu (default on) |
| Allow teleport onto steep ground | Toggle **Cancel If Unsafe** off in the menu (default on) |

## Configure

Edit `Scripts/config.lua`:

- `hotkey` — the on-map teleport key (default `"T"`). Changing it needs a game restart.
- `onMapTeleport` — start with the on-map teleport on or off (the menu toggle overrides this).
- `safeLanding` — land on flat ground near the click instead of the exact click (the menu toggle
  overrides this).
- `expandSearch` — when the close area is unsafe, widen the search in stages and use the closest flat
  spot found (the menu toggle overrides this).
- `maxSearchRange` — how far (cm) the expanded search may look. Default `3000` (30 m).
- `minFlatness` — how flat a surface must be to count as safe, `0`–`1` (1 = dead flat). Default
  `0.85`. Lower it to allow steeper landings, raise it to be pickier.
- `maxElevationDelta` — how far (cm) a landing spot may sit above or below the click, so it never
  drops you into a canyon far below where you pointed. Default `1500` (15 m).
- `cancelIfUnsafe` — with safe landing on, skip the teleport when even the widened search finds no
  flat ground, instead of forcing it onto a cliff (the menu toggle overrides this).
- `captureCoords` — dev aid. When `true`, **Shift + the hotkey** logs your current position as a
  ready-to-paste `locations.lua` entry, so you can curate the quick-travel list.
- `debug` — log every teleport step.

### Adding your own quick-travel spots

Set `captureCoords = true`, stand where you want a destination, and press **Shift+`T`**. The UE4SS
log prints a line like:

```
CAPTURE  { name = "?", x = 146088, y = -69089 },
```

Paste it into `Scripts/data/locations.lua`, give it a name, and reload.
