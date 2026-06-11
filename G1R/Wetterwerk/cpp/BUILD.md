# Wetterwerk (C++ UE4SS mod) - build & install guide

This folder is the C++ version of Wetterwerk: a UE4SS mod that adds a **Wetterwerk**
tab to the UE4SS GUI console and controls the Ultra Dynamic Sky weather. It exists
because the live UE4SS (v3.0.1 Beta, Git SHA `272ce2f8`) exposes ImGui only to C++
mods, not Lua (see `../plans/weather-control.md`, the "C++ ImGui per-mod tab"
section). End users do NOT build this; they just install the prebuilt DLL and turn
on the UE4SS GUI console, see `INSTALL.md`.

You build it in **Visual Studio 2022** against the RE-UE4SS framework source. The
output is a single `main.dll` you drop into the game's mod folder.

> Honest status. The mod code targets UE4SS API symbols that are all confirmed
> present in your `UE4SS.dll`, but it has not been compiled against your exact
> RE-UE4SS headers here. Expect the first build to possibly flag one or two
> signature tweaks; the two likely spots and how to fix them are in
> [Appendix: API confidence](#appendix-api-confidence). Everything else (the tab,
> the request pump, the property reads) is straight from the bundled UE4SS guides.

---

## What you get

```
cpp/
  CMakeLists.txt          top-level: builds RE-UE4SS then the mod
  Wetterwerk/
    CMakeLists.txt        the mod target (-> Wetterwerk.dll)
    dllmain.cpp           the mod: tab registration, on_update pump, ImGui render
    WeatherControl.hpp    the control layer interface
    WeatherControl.cpp    the control layer: find actors, get/set weather, Hold watchdog
  install/
    enabled.txt           drop into Mods\Wetterwerk\ to activate the mod
  BUILD.md                this file
```

`RE-UE4SS/` (the framework source) is NOT in the repo: it is large and needs Unreal
Engine source access to clone. You add it locally per the steps below.

---

## 1. Prerequisites (one-time)

1. **Visual Studio 2022** with, at minimum:
   - "Desktop development with C++"
   - "C++ Clang tools for Windows" (UE4SS builds with Clang/clang-cl, not plain MSVC)
   - "C++ CMake tools for Windows"
   - A recent Windows 10/11 SDK
   The authoritative, current list is the UE4SS build requirements page:
   <https://docs.ue4ss.com/dev/guides/build-requirements.html> (or the "Build
   requirements" link from <https://docs.ue4ss.com>). Install exactly what it lists.

2. **git** (with SSH set up on your GitHub account).

3. **Unreal Engine source access** (RE-UE4SS pulls UE headers from Epic's private
   repos):
   - Make an Epic Games account and link it to your GitHub account.
   - Accept the email invite to the **@EpicGames** GitHub organization.
   - Set up an SSH key on your GitHub account.
   This is the same prerequisite the bundled guide
   (`<game>\...\ue4ss\Docs\guides\creating-a-c++-mod.md`, Part 1) requires.

---

## 2. Get the RE-UE4SS framework

Pick ONE route.

### Route A (recommended): the official template, drop our mod in

The official **UE4SSCPPTemplate** pins the correct UE4SS ABI and wires CMake for
you, which is the most robust path.

1. Clone it: `git clone https://github.com/UE4SS-RE/UE4SSCPPTemplate`
   (use its `dev` branch if you build against UE4SS `main`).
2. Run its setup script (`new_mod_setup.bat`) and follow the prompts; let it pull
   RE-UE4SS as a submodule.
3. Copy this repo's `cpp/Wetterwerk/` folder into the template next to its example
   mod, and add `add_subdirectory(Wetterwerk)` to the template's top-level
   `CMakeLists.txt` (or rename the example mod folder to `Wetterwerk` and replace
   its files with ours).
4. Continue at [section 3](#3-configure--build).

### Route B: clone RE-UE4SS into this folder

Use the `CMakeLists.txt` already in this `cpp/` folder.

```bat
cd <repo>\G1R\Wetterwerk\cpp
git clone https://github.com/UE4SS-RE/RE-UE4SS RE-UE4SS
cd RE-UE4SS
git submodule update --init --recursive
cd ..
```

`RE-UE4SS/` is gitignored, so it stays out of the repo. The top-level
`CMakeLists.txt` here expects it at `cpp/RE-UE4SS`.

> CRITICAL: match the EXACT UE4SS commit your game runs, or the mod fails to load
> with error `0x7f` ("procedure not found" = ABI mismatch). A C++ mod is ABI-locked
> to the precise UE4SS build. Find the commit in the FIRST line of your game's
> `...\ue4ss\UE4SS.log`, e.g. `UE4SS - v3.0.1 Beta #0 - Git SHA #272ce2f8`, then in
> `cpp/RE-UE4SS` run `git fetch --tags && git checkout 272ce2f8 && git submodule
> update --init --recursive` before configuring. Do NOT trust the bundled
> `Changelog.md` top entry for the version (it shows the unreleased dev version,
> which misled an earlier build into using the wrong commit). This game = `272ce2f8`.

---

## 3. Configure & build

From the `cpp/` folder (Route B) or the template root (Route A):

**Option 1 - generate a Visual Studio solution (easiest in the IDE):**
```bat
cmake -B build -G "Visual Studio 17 2022"
```
Then open `build\WetterwerkMods.sln` (Route A: the template's `.sln`) in VS2022,
set the configuration to **`Game__Shipping__Win64`**, right-click the **Wetterwerk**
project in Solution Explorer, and hit **Build**.

**Option 2 - command line:**
```bat
cmake -B build -G "Visual Studio 17 2022"
cmake --build build --config Game__Shipping__Win64
```

> `Game__Shipping__Win64` is the config for normal use. Use a debug config only if
> you intend to attach a debugger.

The first configure builds RE-UE4SS too, so it takes a while. Subsequent mod-only
rebuilds are fast.

---

## 4. Install the DLL

After a successful build you have `Wetterwerk.dll` under
`build\...\Wetterwerk\` (the exact path depends on the generator/config).

1. Go to the game's mod folder:
   `...\Gothic 1 Remake\G1R\Binaries\Win64\ue4ss\Mods`
2. Create `Wetterwerk\dlls\` inside it.
3. Copy your built DLL there and **rename it to `main.dll`**:
   `Mods\Wetterwerk\dlls\main.dll`
4. Copy `cpp\install\enabled.txt` to `Mods\Wetterwerk\enabled.txt` (activates the
   mod without editing `mods.txt`).

Final layout:
```
Mods\
  Wetterwerk\
    enabled.txt
    dlls\
      main.dll
```

> You can automate steps 1-3: uncomment the `POST_BUILD` block in
> `Wetterwerk/CMakeLists.txt`, set `GAME_MODS_DIR`, and rebuild.

---

## 5. Run & verify

1. The GUI tab needs the UE4SS GUI console enabled. In
   `...\ue4ss\UE4SS-settings.ini` set both:
   ```
   GuiConsoleEnabled = 1
   GuiConsoleVisible = 1
   ```
   (Default `RenderMode = ExternalThread` + `GraphicsAPI = opengl` shows the
   console as a SEPARATE window. That mode most likely avoids the Frame-Generation
   freeze, since it does not hook the game's Present. If the window is blank/white,
   the GUI doc suggests trying `GraphicsAPI = dx11`.)
2. Launch the game. In the UE4SS log you should see
   `Wetterwerk loaded (C++ tab).`
3. Open the UE4SS GUI console window and click the **Wetterwerk** tab. Be in-game
   (in the world). You should see the current preset; click **Next** / a preset
   button and the sky should change; toggle **Hold** and the game should stop
   changing the weather.

Because every C++ mod's `register_tab` adds into this one window, any future
Tautellini C++ tab appears here too, and the whole window opens and closes as a
unit.

---

## Appendix: API confidence

**Documented-solid** (from the bundled `ue4ss\Docs\guides`): `register_tab`,
`UE4SS_ENABLE_IMGUI`, `on_update` / `on_unreal_init` / `on_ui_init`,
`Output::send`, `GetValuePtrByPropertyNameInChain<T>`, `GetFunctionByNameInChain`,
`ProcessEvent`, and the ImGui calls. These should compile as written.

**Verify on first compile / first run** (commented inline in `WeatherControl.cpp`):

1. **`UObjectGlobals::FindAllOf(name, out)` signature** (in `find_live`). If your
   RE-UE4SS headers declare it differently, adjust that one call. `ForEachUObject`
   is the documented fallback.

2. **The weather UFunction parameter layouts.** `SetCurrentWeatherImmediate` is
   assumed to take one `int32`, and `GetCurrentWeather` to return one `int32`. If
   the sky does not change when you click a preset, confirm the real signatures:
   open the GUI console -> **Live View** -> search for the controller
   (`GothicUltraDynamicControlerAS`) -> **Find functions** -> inspect
   `SetCurrentWeatherImmediate` / `GetCurrentWeather`, then fix the `Params` structs
   in `WeatherControl.cpp`.

3. **`weather.Weather` and the atmosphere knobs** are read as object / `float`
   properties. If a knob reads wrong, it may be a UE5 `double`; read it with
   `GetValuePtrByPropertyNameInChain<double>` instead. The bool lock flags
   (`Randomize Weather`, `Enable Logic`) may be bitfield bools; if they have no
   effect, the Hold watchdog still holds the weather regardless.

4. **`UObject::GetFullName()` return type** is assumed `std::wstring`. If your
   headers return an `FString`, call `.GetCharArray()` / `.ToString()` before
   `narrow()`.

The preset count is a fallback of 10 for now (set in `dllmain.cpp`); reading the
real `#ListContainer.Weathers` length is a TODO, as is the writable atmosphere
sliders (v1 ships the read-only readout).

## Update fragility (important)

A C++ mod is bound to UE4SS's ABI and the exact bundled ImGui version. When you
update UE4SS, **rebuild and re-ship** this DLL against the new release; a stale DLL
against a newer UE4SS can crash on load rather than degrade. Keep your local
`RE-UE4SS` checkout on the tag that matches the UE4SS you ship for.
