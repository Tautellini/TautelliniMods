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

---

## v1 UI pivot: C++ ImGui per-mod tab (decided 2026-06-11)

The sections above assume a v1 "UE4SS ImGui menu via `RegisterImGuiTab`" from Lua.
Building the mod disproved that assumption against the real platform, so the UI
plan changed. The control DESIGN above (find the controller, `SetCurrentWeather
Immediate`, the Hold watchdog that re-asserts on drift, the preset name parse, the
atmosphere knobs) is unchanged; only the front-end and the language changed.

### What the platform actually supports (verified 2026-06-11)
- The live UE4SS is **v4.0.0-rc1**. It exposes **no Lua ImGui / GUI-tab API**.
  `RegisterImGuiTab` is absent from the DLL exports, the documented Lua
  global-functions list, AND the changelog ("Expose ImGui to C++ mods"). Triple
  confirmed. No UE4SS version restores a *Lua* ImGui menu (it has always been C++
  only; only nonstandard forks add Lua ImGui). Recorded in memory
  `g1r-ue4ss-v4-no-lua-imgui`.
- The only way to add an ImGui tab is a **C++ mod** (`register_tab` /
  `add_gui_tab`, see `Docs/guides/creating-gui-tabs-with-c++-mod.md`).

### The decision
- **Ship Wetterwerk as a C++ UE4SS mod with its own ImGui tab (Option B, per-mod
  tabs).** Not a shared menu mod, and not a C++/Lua bridge: for a single mod the
  whole thing is C++, so the tab's buttons call the weather control directly.
- **Unified open/close is free.** UE4SS has exactly ONE GUI console window;
  every `register_tab` tab lives in it. So multiple Tautellini C++ mods each
  registering their own tab all appear in that one window, opened and closed
  together. No shared component is needed to get "one trigger shows/hides them
  all"; it is inherent to UE4SS.
- **Frame-Generation caveat is render-mode dependent, and the default likely
  dodges it.** This install runs `RenderMode = ExternalThread`, `GraphicsAPI =
  opengl`, where the GUI console is a SEPARATE OpenGL window (per the install
  guide), not a D3D-Present overlay, so the FG present-hook freeze probably does
  not apply. The on-game overlay render modes (`EngineTick` /
  `GameViewportClientTick`) are where FG risk returns. Confirm in-game.
- **ABI fragility is the real cost.** The C++ dll is bound to UE4SS's ABI (and the
  exact bundled ImGui version). A UE4SS update can require a recompile and a
  re-ship; an ABI mismatch is a hard crash, not a graceful Lua degrade. Build
  against the matching UE4SS release.

### Status of the Lua scaffold (`Scripts/`, `tests/`)
Superseded for shipping, kept as REFERENCE. It is a tested, working statement of
the weather API surface and the control logic (the C++ mirrors it 1:1: engine
adapter -> `WeatherControl`, the Hold watchdog, the preset parse, the atmosphere
catalog). Do not deploy it as the product; the C++ tab is the product.

### Where the C++ mod lives
`G1R/Wetterwerk/cpp/` (CMake project + `dllmain.cpp` + `WeatherControl.*`), built
in Visual Studio 2022 against the RE-UE4SS source. See `cpp/BUILD.md` for the full
setup. Installs as `Mods/Wetterwerk/dlls/main.dll` + `enabled.txt`.

### Revised done criteria (v1)
- Build `main.dll` in VS2022; drop it in `Mods/Wetterwerk/dlls/`, enable the GUI
  console, open the **Wetterwerk** tab, pick a preset -> the sky changes; toggle
  Hold -> the game stops changing the weather.
- Multiple Tautellini C++ tabs share the one GUI window (open/close together).
- Pure standalone, no extra mod required.
- Confirm: the GUI console show/hide behavior on this build, and whether the
  default `ExternalThread + opengl` render mode avoids the FG freeze.

### What stays open (unchanged probes, now confirmed in C++)
The index->name map (count is a `presetCountFallback` until the live list length is
read in C++), the lock lever (Hold sets the flags AND runs the drift watchdog, so
it holds regardless), and atmosphere-write persistence (C++ v1 ships the read-only
readout; writable sliders are the follow-up). The riskiest C++ specifics to verify
on first compile are the `FindAllOf` signature and the weather UFunction parameter
layouts (use the Live View "Find functions" panel to confirm the signatures).
