# Wetterwerk - install & use

Weather control + full weather-value editor for Gothic 1 Remake. This is a C++
UE4SS mod: its menu is a tab in the **UE4SS GUI console**, which opens as a
**separate window** next to the game (not an in-game overlay). The menu is the only
entry point - there are no hotkeys.

> Why a separate window: the menu is drawn by UE4SS's debug GUI, whose render mode
> is a global UE4SS setting (`RenderMode`), defaulting to a separate window. An
> in-game overlay is possible (`RenderMode = GameViewportClientTick`) but each user
> would have to set it, and that mode can interact badly with Frame Generation, so
> the separate window is the supported setup.

## 1. Requirements

- UE4SS installed and working for Gothic 1 Remake.
- **The exact UE4SS version matters.** This is a C++ mod, so the prebuilt `main.dll`
  is locked to one UE4SS build. It is compiled for **UE4SS v3.0.1 Beta (Git SHA
  `272ce2f8`)** - the first line of `...\ue4ss\UE4SS.log` shows yours. If they do not
  match, the mod will not load (see Troubleshooting). If you need a different UE4SS
  version, the mod must be rebuilt against it (`cpp/BUILD.md`).

## 2. Install the mod

Copy the `Wetterwerk` folder into your game's UE4SS mods folder so you end up with:

```
...\Gothic 1 Remake\G1R\Binaries\Win64\ue4ss\Mods\Wetterwerk\
    enabled.txt
    dlls\
        main.dll
```

The `enabled.txt` activates the mod (no `mods.txt` edit needed).

## 3. Turn on the UE4SS GUI console (one-time)

The menu lives in the UE4SS GUI console, which is OFF by default. Open
`...\ue4ss\UE4SS-settings.ini`, find the `[Debug]` section, and set:

```ini
[Debug]
GuiConsoleEnabled = 1
GuiConsoleVisible = 1
GraphicsAPI = dx11
```

- `GuiConsoleEnabled` / `GuiConsoleVisible = 1` show the console window.
- `GraphicsAPI` defaults to `opengl`. If the window does not appear, shows up blank,
  or the game hangs at startup on `opengl`, set it to **`dx11`** (recommended; it is
  what this mod was verified with).

Leave `RenderMode` at its default (`ExternalThread`) for the separate window.

## 4. Open the menu

1. Launch the game. A **separate UE4SS window** appears. It is its own window, so:
   - **Alt-Tab** to it (look for it in the taskbar), and
   - run the game in **borderless or windowed** mode so the window is visible
     (a fullscreen-exclusive game hides it).
2. In that window's tab bar, click the **Wetterwerk** tab.

## 5. Use it

- **Top:** the current weather, `< Previous` / `Next >`, a `Hold` toggle, and a
  numbered button per preset. Hold pins the weather so the game stops changing it.
- **All weather values:** sections for **Weather**, **Sky** and **Controller**.
  Expand a section, type in the **filter** box (e.g. `fog`, `cloud`, `color`) to
  narrow it, and drag any value to change it live. Use the **scrollbar** on the
  right of the list to scroll (the mouse wheel may not reach the separate window).

Everything is driven from the menu; there are no hotkeys.

## Troubleshooting

- **No `Wetterwerk` tab / nothing happens.** Check `...\ue4ss\UE4SS.log`:
  - `Failed to load dll ... error: [0x7f] The specified procedure could not be
    found.` means your UE4SS version differs from the one the DLL was built for
    (see Requirements). The DLL must be rebuilt against your UE4SS commit.
  - `Wetterwerk loaded (C++ tab + editor)` means it loaded fine; the tab is in the
    UE4SS console **window** (Alt-Tab to it).
- **Console window never appears / is blank / game hangs at startup.** Set
  `GraphicsAPI = dx11` in `UE4SS-settings.ini` (step 3).
- **Can't see the window in fullscreen.** Run the game in borderless/windowed.

## Notes

- **Some edits drift back.** The game interpolates toward the active preset, so a
  changed value may be pulled back. `Hold` pins the *preset*; it does not lock every
  individual value.
- **The list includes engine properties.** Because the editor exposes *every*
  reflected value on the actors, you will also see inherited engine properties
  (transform, tick settings, etc.) mixed in with the weather knobs. Use the filter.
- **Separate window, not in-game.** That is how the UE4SS GUI console works in the
  default render mode. See the note at the top.
