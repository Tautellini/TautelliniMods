# FastTravelAnywhere

Fast travel for Gothic 1 Remake. Open the world map, point at where you want to go, and press a
key to teleport there. Plus a quick-travel list of useful spots in the in-game menu. Shipped as the
UE4SS Lua mod `FastTravelAnywhere`.

> **Known limits.** The world map works at any resolution and aspect ratio. City/area maps are not
> wired up yet, and the cursor is read from the mouse (a controller-driven map cursor is not picked up).

## What it does

- **On-map teleport.** While the world map is open, hover the cursor over a destination and press
  **`T`**. You fast-travel there using the game's own travel, so you land on valid ground, and the
  map closes behind you the way the game's fast-travel does.
- **Immersive Mode (opt-in).** Turn it on to make fast travel cost ore (Erzbrocken) by distance.
  While the map is open, a small panel in its upper-right shows the distance, the ore cost (red when
  you cannot afford it), and the estimated travel time. If you cannot pay, the jump is refused.
  Optionally the in-game clock advances by the distance travelled. The cost curve and the time ratio
  are configurable. Off by default, so the mod is plain free fast travel until you turn it on.
- **Quick travel.** A curated list of locations (Old Camp, New Camp, Swamp Camp, the mines, ...)
  appears as one-press buttons in the SharedModMenu, so you can jump to a known spot without opening
  the map. Charged the same way when Immersive Mode is on.

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
| Make travel cost ore and show the readout | Toggle **Immersive Mode** in the menu (default off) |
| Advance the clock on a jump | Toggle **Advance Time** in the menu (Immersive Mode) |
| Tune the ore cost and travel time | **Ore Cost / 100m**, **Min/Max Ore Cost**, **Time / 100m** sliders |

## Configure

Edit `Scripts/config.lua`:

- `hotkey`: the on-map teleport key (default `"T"`). Changing it needs a game restart.
- `onMapTeleport`: start with the on-map teleport on or off (the menu toggle overrides this).
- `immersiveMode`: make fast travel cost ore and show the on-map readout (default off; the menu
  toggle overrides this). The whole immersive feature is gated on this.
- `oreCostPer100m`: ore charged per 100 m of straight-line distance (default `3`).
- `oreCostMin` / `oreCostMax`: floor and cap on the ore cost (default `3` / `50`), so short hops stay
  worth charging and cross-map jumps stay payable.
- `currencyItem`: the ore item class (default `"ItMi_Orenugget"`, the Gothic ore nugget).
- `advanceTime`: advance the in-game clock on a paid teleport (default on; Immersive Mode only).
- `timeMinutesPer100m`: in-game minutes added per 100 m when `advanceTime` is on (default `20`).
- `maxTimeAdvanceMin`: cap on how many minutes one jump may advance the clock (default `180`).
- `teleportCooldown`: minimum seconds between teleports (default `1.0`).
- `captureCoords`: dev aid. When `true`, **Shift + the hotkey** logs your current position as a
  ready-to-paste `locations.lua` entry, so you can curate the quick-travel list.
- `debug`: log every teleport step.

### Adding your own quick-travel spots

Set `captureCoords = true`, stand where you want a destination, and press **Shift+`T`**. The UE4SS
log prints a line like:

```
CAPTURE  { name = "?", x = 146088, y = -69089 },
```

Paste it into `Scripts/data/locations.lua`, give it a name, and reload.
