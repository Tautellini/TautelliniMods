Wetterwerk (EXPERIMENTAL 0.2.0) - weather control + editor for Gothic 1 Remake

A C++ UE4SS mod. It adds a "Wetterwerk" tab to the UE4SS GUI console where you can
switch weather presets, hold the weather so the game stops changing it, and live-
edit the weather/sky values the game exposes. Everything is driven from the menu.

================================================================================
IMPORTANT - THIS BUILD IS LOCKED TO ONE UE4SS VERSION
================================================================================
This is a C++ mod, so the DLL is only guaranteed to be working with the exact UE4SS build it was
compiled against:

    UE4SS  v3.0.1 Beta   (Git SHA #272ce2f8)

Check yours in the FIRST line of  ...\ue4ss\UE4SS.log .  If it does not match,
the mod MIGHT NOT LOAD

================================================================================
INSTALL
================================================================================
1. Have UE4SS (the version above) installed for Gothic 1 Remake.
2. Copy the  Wetterwerk  folder from this archive into:
       ...\Gothic 1 Remake\G1R\Binaries\Win64\ue4ss\Mods\
   You should end up with:
       Mods\Wetterwerk\dlls\main.dll
       Mods\Wetterwerk\enabled.txt
3. Turn on the UE4SS GUI console. In  ...\ue4ss\UE4SS-settings.ini , [Debug]:
       GuiConsoleEnabled = 1
       GuiConsoleVisible = 1
       GraphicsAPI       = dx11
4. Launch the game. UE4SS.log should show:
       Wetterwerk loaded (C++ tab + editor). Menu is the only entry point.

================================================================================
USE
================================================================================
- The menu opens as a SEPARATE UE4SS window (not an in-game overlay). Alt-Tab to
  it (run the game in borderless/windowed so you can see it), and click the
  "Wetterwerk" tab.
- Top: the current weather, Previous / Next / Hold, and a button per preset.
- Below: every weather/sky value, grouped per actor, with a filter box. The
  control-disabling toggles sit in a "(!) Caution" dropdown - in particular do NOT
  enable "Use Cinematics Settings": it stops preset switching from working.

The menu is the only entry point - there are no hotkeys.

================================================================================
EXPERIMENTAL - KNOWN ROUGH EDGES
================================================================================
- The DLL only loads on the exact UE4SS build listed above.
- Editing a value manually overrides that aspect, so afterwards switching presets
  may not visibly change what you hand-edited.
- The "current weather" readout can lag by one step.
- Some preset indices can be invalid in a given biome (clicking them does nothing).
- The editor exposes a LOT of values; the real weather knobs are the named ones
  (cloud, fog, rain, wind, thunder, ...). Inherited engine values are read-only.

No game files are modified. To uninstall, delete the  Wetterwerk  folder.
