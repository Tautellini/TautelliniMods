Wetterwerk (EXPERIMENTAL 0.2.0) - BUNDLED with UE4SS

This package includes UE4SS (the exact build the mod needs) AND the Wetterwerk mod,
already configured so the menu works out of the box. Use this if you do NOT already
have UE4SS installed. If you ALREADY run UE4SS, use the "manual" download instead -
this bundle would overwrite your UE4SS files and settings.

Bundled UE4SS: v3.0.1 Beta (Git SHA #272ce2f8). Wetterwerk is a C++ mod locked to
this exact UE4SS build, which is why they ship together.

================================================================================
INSTALL
================================================================================
1. CLOSE the game.
2. Extract the contents of this archive into:
       ...\Gothic 1 Remake\G1R\Binaries\Win64\
   After extracting you should have:
       Win64\dwmapi.dll
       Win64\ue4ss\UE4SS.dll
       Win64\ue4ss\UE4SS-settings.ini
       Win64\ue4ss\Mods\Wetterwerk\dlls\main.dll
       Win64\ue4ss\Mods\Wetterwerk\enabled.txt
3. Launch the game.

The UE4SS GUI console is already turned on (GuiConsoleEnabled = 1,
GuiConsoleVisible = 1, GraphicsAPI = dx11), so no settings editing is needed.

================================================================================
USE
================================================================================
- The menu opens as a SEPARATE UE4SS window (not an in-game overlay). Alt-Tab to it
  (run the game in borderless/windowed so you can see it), and click the
  "Wetterwerk" tab.
- Top: the current weather, Previous / Next / Hold, and a button per preset.
- Below: every weather/sky value, grouped per actor, with a filter box. The
  control-disabling toggles sit in a "(!) Caution" dropdown - in particular do NOT
  enable "Use Cinematics Settings": it stops preset switching from working.

The menu is the only entry point - there are no hotkeys.

================================================================================
EXPERIMENTAL - KNOWN ROUGH EDGES
================================================================================
- Editing a value manually overrides that aspect, so afterwards switching presets
  may not visibly change what you hand-edited.
- The "current weather" readout can lag by one step.
- Some preset indices can be invalid in a given biome (clicking them does nothing).
- The editor exposes a LOT of values; the real weather knobs are the named ones
  (cloud, fog, rain, wind, thunder, ...). Inherited engine values are read-only.

================================================================================
UNINSTALL
================================================================================
Delete  Win64\dwmapi.dll  and the whole  Win64\ue4ss  folder. That removes UE4SS
and the mod. No game files are modified.
