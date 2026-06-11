# Wetterwerk

Weather control for Gothic 1 Remake. Take command of the sky over the Colony: set
any weather on demand, freeze it where you like, and balance the rotation with
presets from calm to stormy. Cloud coverage, fog, rain, wind and thunder are all
reachable.

G1R's sky is **Ultra Dynamic Sky**, driven by the game's own
`GothicUltraDynamicControlerAS` (`GetCurrentWeather` / `SetCurrentWeatherImmediate`
/ `GetCurrentWeatherSettings`), so this is a pure UE4SS Lua mod: no game files
modified, the game's own weather cycle resumes when you unload. The feasibility
probe lives at `G1R/WeatherProbe/`.

## Status

`0.1.0-alpha`, built, NOT yet play-verified. The control layer, the UE4SS ImGui
menu, the hotkeys and the config are written and the Lua test suite is green
(`tests/run.ps1`). The in-game confirm-probes the spec lists (the index->name map,
which flag the game honors for the lock, atmosphere-write persistence) are still
open, so the runtime parts are robust to the unknowns rather than tuned to a
measured value. See "What needs in-game verification" below.

## Layout

```
Wetterwerk/
  README.md          this file
  nexus-page/        the live Nexus mod page (description + images); see its README
  plans/             the v1 spec (weather-control.md)
  enabled.txt        activates the mod under ue4ss\Mods
  Scripts/
    main.lua         orchestrator: kit bootstrap, hot-reload reset, ALL registration
    config.lua       hotkeys, on-load behavior, which atmosphere knobs to show
    core/
      engine_weather.lua   the domain adapter (the one file with the UDS literals)
    weather/
      presets.lua    preset name -> leaf/label (pure, tested)
      control.lua    the live Control: handles, name map, Hold watchdog
    ui/
      menu.lua       the UE4SS ImGui tab (the swappable v1 front-end)
    data/
      atmosphere.lua the atmosphere-knob catalog (pure, tested)
  tests/             tinytest + check_load + unit tests; never shipped
```

The mod follows the LockpickSettings conventions (CONTRIBUTING.md): foldered
`Scripts/` with dotted requires, the vendored shared kit, the engine adapter as
the only home for the Gothic literals, all registration in `main.lua`'s tail, and
pure files (`presets`, `atmosphere`) that load under bare LuaJIT for the tests.

## Install

1. Have UE4SS installed for Gothic 1 Remake (the same setup the other mods use).
2. Deploy: `powershell -File tools\deploy.ps1 -Mod Wetterwerk` (copies `Scripts/`
   and vendors the kit into `Wetterwerk\shared\kit\`). Or `-Mod All`.
3. The hotkeys work immediately. For the on-screen MENU you must enable the UE4SS
   GUI console: set `GuiConsoleEnabled = 1` in `UE4SS-settings.ini`, then open the
   overlay in-game and pick the `Wetterwerk` tab.

**Frame Generation caveat.** The UE4SS GUI hooks D3D Present, which on this game
has interacted badly with Frame Generation (GPU freeze). If you run Frame
Generation, either turn it off while using the menu, or skip the menu entirely and
use the hotkeys (they need no GUI). The v2 plan moves the menu to a game-rendered
SharedModMenu page, which drops this caveat.

## Usage

- **Hotkeys** (default; all configurable in `config.lua`, chosen clear of
  LockpickSettings' F6/F7/F8):
  - `F9` cycle to the next weather preset
  - `F10` toggle **Hold** (pin the weather; the game stops changing it)
  - cycle-previous is bound to nothing by default (`weatherPrevHotkey`)
- **Menu** (`Wetterwerk` tab): the current preset, Previous / Next / Hold buttons,
  a button per preset, and the atmosphere section.
- **Hold** pins the weather to the current preset. A light watchdog re-asserts that
  preset whenever the game drifts off it, and it asks the game to stop its own
  cycle. Toggle Hold off to hand the sky back to the game.

## Atmosphere knobs (experimental, off by default)

The menu lists a few atmosphere values (cloud, fog, rain, wind, thunder by
default). They show as a **read-only readout** unless you set
`enableAtmosphereWrites = true` in `config.lua`. With writes on they become live
sliders that take effect **only while Hold is engaged**: the live weather lerps
toward the active preset, so an override has to be re-asserted to win that lerp,
which the Hold watchdog does each poll. This is the part still being verified
in-game, hence off by default; preset switching and Hold are the solid core.

## What needs in-game verification

The spec's open probes, to confirm on a real session:

- **Index -> preset-name map.** Names are learned lazily as presets are visited
  (and the count is read from the controller's list). Confirm the count and that
  the leaf labels read cleanly.
- **The lock lever.** Hold both flips the known flags (`Randomize Weather`,
  `Enable Logic`) and runs the drift watchdog, so it should hold regardless of
  which flag the game honors. Confirm the weather actually stops changing.
- **Atmosphere persistence.** Confirm the override (with writes on, Hold engaged)
  reaches and holds the value without visible oscillation; tune the `Intended`
  targets in `data/atmosphere.lua` if a knob fights back.

The page art is generated from the shared house style at the repo root: the
Wetterwerk template group in `brand/templates/wetterwerk/` plus the light-blue
"Azur" accent in `brand/themes/wetterwerk.css`, rendered by
`brand/render-wetterwerk.ps1`. See `nexus-page/README.md` for the render-and-copy
flow and where each image goes on Nexus.
