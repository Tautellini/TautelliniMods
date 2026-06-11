# Wetterwerk 0.2.0 - experimental release

First public-ish drop. A **C++ UE4SS mod** (not the Lua prototype): a `Wetterwerk`
tab in the UE4SS GUI console for preset switching, Hold, and a full live editor of
the weather/sky values.

## Artifacts (two downloads)

- **`Wetterwerk-0.2.0-manual.zip`** (~260 KB) - the mod ONLY, for users who already
  run UE4SS **v3.0.1 Beta `272ce2f8`**. Contains `Wetterwerk\dlls\main.dll` +
  `enabled.txt` + `readme.txt` (= `readme-manual.txt`). They must enable the GUI
  console themselves.
- **`Wetterwerk-0.2.0-bundled-ue4ss.zip`** (~7 MB) - the mod **+ the exact matching
  UE4SS** (`tools/ue4ss`, byte-identical to `272ce2f8`) **+ a pre-configured
  `UE4SS-settings.ini`** (GuiConsole on, dx11) **+ the `dwmapi.dll` proxy**. Extracts
  into `...\G1R\Binaries\Win64\`; the menu works with no settings editing. For users
  who do NOT already have UE4SS. Readme = `readme-bundled.txt`.

The bundled variant exists precisely to dodge the ABI problem: the user always gets
the exact UE4SS the DLL needs. (UE4SS is MIT; redistribution is fine.)

## The hard requirement (must be loud on the page)

The DLL is **ABI-locked to UE4SS v3.0.1 Beta (Git SHA `272ce2f8`)**. On any other
UE4SS build it fails to load with `0x7f` (clean, non-fatal). The **bundled** download
removes this concern (it ships the matching UE4SS); the **manual** download requires
the user to already have that exact build, or rebuild from source (`cpp/BUILD.md`).
The GUI console is NOT developer-only - it is core UE4SS, default-off in the basic
build, which the bundled `UE4SS-settings.ini` simply turns on.

## What works / what's rough (experimental)

Works: preset switching, Hold, the reflection editor (every weather/sky value,
filtered, with inherited engine values read-only and control-disabling toggles
behind a "(!) Caution" group). All driven from the menu - no hotkeys.

Rough edges, see `zip-readme.txt`:
- ABI version lock (above).
- Manual edits override that aspect, so presets may not visibly change a hand-edited value.
- "Current weather" readout can lag one step.
- Some preset indices are invalid per biome (no effect).
- Real preset count + preset names are not yet read from the weather enum (TODO).

## Page assets still to rework

The `nexus-page/` **description** (`nexus-description.bbcode`) and the gallery
**images** were authored for the Lua prototype (hotkey/ImGui framing, "pure Lua",
four presets). They do not match this C++ external-window editor and need a rewrite
+ re-render before the page goes live. The `nexus-summary.txt` is updated.
