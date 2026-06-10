# Wetterwerk - spec (v1)

A standalone, pure-Lua weather-control mod for Gothic 1 Remake. Control the weather
in-game: switch weather presets, lock it, and (optionally) tweak atmosphere values.
Confirmed feasible by the WeatherProbe (2026-06-10). Working name `Wetterwerk`
(folder `G1R/Wetterwerk`); adjust if desired.

## Goal

Let the player drive the weather: pick a preset (sunny / rain / storm / fog), stop
the game from changing it, and optionally nudge atmosphere values. No pak, no
Blueprint, the whole Ultra Dynamic Weather/Sky surface is reflected and reachable
from UE4SS Lua.

## UI plan (the release decision)

- **v1 ships with a UE4SS ImGui menu** (`RegisterImGuiTab`), because SharedModMenu
  is not finished and we want to release standalone now. Quote: "add that we want
  an UE4SS menu first, since the Mod Menu is not yet finished. I want to release the
  mod without it first. This just means people need to activate the UE4SS Gui."
  - This requires the user to enable the UE4SS GUI console
    (`GuiConsoleEnabled = 1` in `UE4SS-settings.ini`), documented in the install steps.
  - CAVEAT to document: the UE4SS GUI hooks D3D Present, which on this game has
    interacted badly with Frame Generation (GPU freeze). Tell users: enable the GUI,
    and if you run Frame Generation, turn it off, or just use the hotkeys (which work
    without the GUI).
- A **hotkey to cycle/set weather works without the GUI**, so players who do not want
  the overlay still get basic control.
- **v2 migrates the UI to SharedModMenu** (game-rendered, no GUI console, no FG
  caveat) once it exists. Only the front-end swaps; the Lua control layer is unchanged.

## Scope

In (v1):
- Standalone mod at `G1R/Wetterwerk`, pure Lua, vendored kit, no pak.
- Switch weather PRESETS via the controller (confirmed working).
- Read and SHOW the current preset's name (so the menu lists real names, not ints).
- Lock weather: stop the game's auto weather changes.
- A UE4SS ImGui tab: preset picker + lock toggle + a few atmosphere sliders.
- A hotkey to cycle presets (no GUI needed).
- `config.lua`: hotkey, default-on-load behavior, which sliders to expose, persist
  vs reset.

Out (v1):
- SharedModMenu integration (v2).
- Time-of-day / sky control (the sky actor is enumerable, so feasible; keep v1 to
  weather, add in v2 if wanted).
- New weather visuals (that would be content / a pak).

## Architecture (access points, all confirmed in-game)

- Find the live actors with `FindAllOf` (filter out Default__):
  - Controller: `FindAllOf("GothicUltraDynamicControlerAS")` ->
    `Gothic_Ultra_Dynamic_Controller_C` (`/Script/G1R.GothicUltraDynamicController`).
  - Weather actor: `FindAllOf("GothicUltraDynamicWeatherAS")` -> `Ultra_Dynamic_Weather_C`.
  - Sky actor: `FindAllOf("GothicUltraDynamicSkyAS")` -> `Ultra_Dynamic_Sky_C`.
  - The controller also exposes them as `["Ultra Dynamic Weather"]` / `["Ultra Dynamic Sky"]`.
- **Switch weather:** `controller:SetCurrentWeatherImmediate(n)` (one int arg; the
  2-arg form fails). `SetCurrentWeather(n)` also works. CALL ON THE GAME THREAD
  (`ExecuteInGameThread`), pcall-wrapped.
- **Read current:** `controller:GetCurrentWeather()` returns an int. The named preset
  is `weatherActor.Weather` -> a `UDS_Weather_Settings_C` asset, e.g.
  `.../Weather_Presets/Gothic_Pressets/Temperate_Decidious_Forest/Gothic_Forest_Sunny`.
  Read its full name and take the leaf for the label. Map every index -> name by
  setting it and reading back (a one-pass mapping, or do it live in the menu).
- **Atmosphere knobs** (number properties on the weather actor; BP names have spaces,
  so `weatherActor["Cloud Coverage"]`): `Cloud Coverage`, `Intended Cloud Coverage`,
  `Fog`, `Base Fog Density`, `Rain`, `Snow`, `Thunder/Lightning`, `Dust`,
  `Wind Intensity`, `Gothic Wind Intensity`, `Wind Direction`, `Material Wetness`,
  plus a full temperature model and many particle/audio settings.
- **Lock weather:** controller/weather flags `Randomize Weather` (bool), `Enable Logic`
  (bool), and the controller's `Randomize Weather` / time settings. Exact lock lever
  TBD (a quick probe), most likely set `Randomize Weather = false` and re-assert the
  chosen preset, or flip `Enable Logic`.
- Property ENUMERATION works in this UE4SS build:
  `obj:GetClass():ForEachProperty(fn)` dumps every reflected property (the menu can
  use this to build the slider list, or we hardcode the chosen few).
- Conventions: engine access via the kit/adapter, pcall-wrapped, game thread; pure
  files name no globals; all `RegisterKeyBind`/`RegisterImGuiTab` in `main.lua` tail
  (same rules as LockpickSettings, see CONTRIBUTING.md).

## Configuration (`config.lua`)
- Cycle/open hotkey(s).
- Default behavior on load (do nothing / set a preset / lock).
- Which atmosphere sliders to expose in the menu.
- `persistAcrossSaves` (see Persistence).

## Persistence
- Weather is saved to the savegame (`FWeatherSaveGame`). Decide whether our forced
  weather should persist (could "stick" unexpectedly) or reset when leaving / on load.
  v1 default: do not fight the save, our override is a live action; the game's own
  save handles continuity. Confirm behavior in testing.

## The lerp caveat (atmosphere sliders)
- The weather actor LERPS toward the active preset (`Intended Cloud Coverage`,
  `Lerp to New Settings`). So PRESET switching is solid, but a raw write to e.g.
  `Cloud Coverage` may be pulled back. For custom atmosphere we set the
  `Intended ...` values and/or turn `Enable Logic` / `Randomize Weather` off and
  re-assert each tick. v1 can ship preset-switching + lock first and treat the raw
  sliders as a follow-up once the persistence approach is confirmed.

## Performance
- Idle until used. Setting weather is a one-shot call. A "lock" that re-asserts the
  preset would run on a light poll (like the lockpick session poll) or only react to
  the game's weather-change event; keep it lean.

## Risks / open questions (probes still to run)
- **Index -> preset-name map**: cycle `SetCurrentWeatherImmediate(0..N)` and read
  `weatherActor.Weather` after each (per biome). Confirm count and names.
- **Lock lever**: which flag actually stops the game changing the weather
  (`Randomize Weather` vs `Enable Logic` vs re-assert-on-change). Quick test.
- **Atmosphere write persistence**: `Intended X` vs raw `X` vs disabling logic.
- **Biome dependence**: presets are biome-organized (`DT_BiomeWeather`,
  `Default Biome`); confirm the index list is stable or per-biome.
- **GUI + Frame Generation freeze**: the v1 reason to move to SharedModMenu later.

## Done criteria (v1)
- Enable the UE4SS GUI, open the Wetterwerk tab, pick a preset -> the sky
  changes; toggle "lock weather" -> the game stops changing it.
- A hotkey cycles presets with the GUI off.
- Works fully standalone (no SharedModMenu).
- Install docs clearly state: enable the UE4SS GUI; Frame-Generation caveat.

## Delivery split / next steps
- Claude produces: the Lua mod (control layer + ImGui menu + hotkey + config),
  the README/Nexus page (blue-or-own design), and runs the remaining confirm-probes
  (index->name, lock lever, atmosphere persistence).
- Then v2: swap the ImGui front-end for a SharedModMenu page.

Findings recorded in memory `g1r-weather-control`. Dev probe: `G1R/WeatherProbe`
(throwaway, currently still deployed, F2 cycles weather).
