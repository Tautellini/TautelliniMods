# Shared Mod Menu (SharedModMenu) - v1 spec

A standalone, reusable in-game settings menu for Gothic 1 Remake, separate from
LockpickSettings. Captured from the planning interrogation (2026-06-10).

> **PIVOT (2026-06-13): build it PURE-LUA, not Blueprint.** The "Goal" below assumed
> a BP/UMG widget in a cooked pak (`BUILD-GUIDE.md`, now obsolete) because Lua-only
> menus were thought impossible. They are not: a full Lua UMG menu (tabs, mouse +
> numpad, value controls, camera lock) is built and working in
> `G1R/TautelliniDevProbe/Scripts/probes/menu.lua`. So SharedModMenu becomes a
> pure-Lua mod = that renderer + the consumer API. The API / registry / per-mod
> section / each-mod-owns-persistence design below STILL HOLDS; only the widget
> implementation changes (Lua reflection instead of a BP pak). Refinements from the
> newer design (`G1R/TautelliniTuner/plans/tautellini-tuner.md`, which this now
> supersedes): get/set callbacks instead of onChange dispatchers; tabs instead of
> sections; OPTIONAL install (other mods register only if `_G.SharedModMenu` exists,
> queueing if they load first); the dev tooling is a separate mod `TautelliniDevConsole`
> (renamed from TautelliniConsole) = console commands + optional menu registration.
> Hotkey lives in one shared `Mods/TautelliniMenu.cfg` (single source despite the kit
> being vendored everywhere).

> **M1 DONE (2026-06-13): the SharedModMenu mod is built + deployed.** `Scripts/main.lua`
> (bootstrap + `_G.SharedModMenu` API + queue drain + `Mods/TautelliniMenu.cfg` hotkey,
> default F2) + `Scripts/render.lua` (the pure-Lua UMG renderer reading the process-global
> `_G.__sharedModMenu` registry; get/set item callbacks; bool/num/action kinds). Kit got the
> `kit.menu.register` forwarder shim (kit 1.2.0). Parse + mock-UE4SS wiring harness + kit
> tests green. Awaiting in-game smoke test (empty menu until a consumer registers). NEXT:
> M3 = wire LockpickSettings as the first consumer; then M4 = TautelliniDevConsole.

## Goal

A Blueprint (UMG) widget that renders an in-game menu using the GAME's own
renderer, so it does NOT need UE4SS's GuiConsole / ImGui overlay (and so dodges
the Frame-Generation present-hook freeze), plus a Lua framework that exposes an
API any UE4SS Lua mod can use to register its config options into ONE shared
menu and receive change callbacks. The user's words: "a clean product, that
could be used by other mods that need a Mod Menu." First consumer:
LockpickSettings, exposing all of its settings.

## Scope

In scope (v1):
- New standalone mod `SharedModMenu` at `G1R/SharedModMenu` (display "Shared Mod Menu").
- A Blueprint UMG widget (minimal dark panel, neutral, one accent), loaded via
  UE4SS BPModLoaderMod from a cooked pak.
- A Lua framework: the consumer API, the option registry, the open/close hotkey
  (pauses the game, shows the cursor), and the bridge to the widget.
- Control types: toggle (bool), slider (int min/max), color (RGB), button (action).
- Layout: a single scroll list, one labeled SECTION per registering mod.
- Persistence: each consumer mod saves ITS OWN settings; the menu only fires
  onChange. Reuse the atomic-save technique from `chests/store.lua`.
- LockpickSettings integration exposing ALL its settings.
- A Nexus page for SharedModMenu with a NEW design using a BLUE accent
  (distinct from LockpickSettings' gold).
- A step-by-step UE 5.4 build guide written for ZERO Unreal experience.

Out of scope (v1):
- "Needs restart" labels: everything applies live (value-only settings like the
  per-tier tries simply take effect on the next lock).
- Key-rebinding control type.
- Per-mod tabs (sections only).
- A shared central save file (each mod owns its persistence).
- A blue-branded or Gothic-styled in-game widget (v1 widget is minimal/neutral;
  the blue identity lives on the Nexus page).
- Authoring/cooking the `.uasset` (the editor work is the user's, per the guide).

## User-facing behavior

- In-game, the player presses the menu hotkey (default `F1`, configurable). The
  game pauses, the mouse cursor appears, and the SharedModMenu panel opens.
- The panel is a scroll list. Every installed mod that registered gets a labeled
  section containing its rows: toggles, int sliders, color pickers, buttons.
- Changing a control applies LIVE: toggles and colors take effect immediately;
  value-only settings (per-tier tries) apply on the next lock. The OWNING mod
  persists the change.
- Closing (hotkey again, or a Close button) unpauses and hides the cursor.
- Graceful both ways: SharedModMenu installed but a consumer absent -> that
  section just does not appear. A consumer installed but SharedModMenu absent ->
  the consumer runs normally on its `config.lua` + hotkeys, with no menu.

## Architecture

Two halves that meet at a deliberately thin, primitive-only bridge.

### Blueprint side (the pak, user-built in UE 5.4)
- `WBP_SharedModMenu` (UUserWidget): the panel + a scroll box + four row widget
  types. References ONLY engine-standard UMG (UButton, UCheckBox, USlider,
  UTextBlock, UScrollBox, color via a swatch + sliders). NO game classes, so it
  survives game content patches.
- A loader actor BP that BPModLoaderMod instantiates on map load; it creates the
  widget, adds it to the viewport hidden, and is the object Lua finds.
- The widget exposes BP functions Lua CALLS (Lua -> BP) and BP events Lua HOOKS
  (BP -> Lua). All parameters are primitives (string/int/float/bool); no structs
  or arrays cross the bridge (row-by-row build), to avoid marshaling fragility.

### Lua side (the framework, this repo)
- A UE4SS Lua mod under `G1R/SharedModMenu/Scripts` that:
  - Publishes the consumer API for other mods to use (see below).
  - Holds the registry of registered mods + their options.
  - Owns the hotkey; on open it builds the widget rows from the registry, sets
    pause + UI input mode + cursor; on close it restores play.
  - Bridges: finds the loader/widget instance (spawn notify + FindAllOf
    fallback), calls the widget's Add* functions to build rows, hooks the
    widget's change events, and dispatches each change to the owning mod.
- Reuses the vendored kit (log, etc.), same pattern as LockpickSettings.

### BP <-> Lua contract (the interface the widget MUST implement)
Lua calls (Lua -> BP):
- `OpenMenu()` / `CloseMenu()` (or `SetMenuOpen(bool)`): show/hide, pause, cursor.
- `ClearMenu()`: remove all rows.
- `AddSection(modName)`: add a section header.
- `AddToggle(modName, key, label, currentBool)`.
- `AddSlider(modName, key, label, min, max, currentInt)`.
- `AddColor(modName, key, label, r, g, b)` (0..1 floats).
- `AddButton(modName, key, label)`.
BP events Lua hooks (BP -> Lua):
- `OnToggleChanged(modName, key, bool)`.
- `OnSliderChanged(modName, key, int)`.
- `OnColorChanged(modName, key, r, g, b)`.
- `OnButtonPressed(modName, key)`.
- `OnMenuClosed()`.

### Consumer API (the reusable product)
A registering mod calls something like:
```lua
local ModMenu = <obtained from the shared global / package.loaded once present>
ModMenu.register({
  mod = "LockpickSettings",
  options = {
    { key = "showNextMove", type = "toggle", label = "Next-move hint" },
    { key = "extraTries.untrained", type = "slider", label = "Untrained bonus", min = 0, max = 30 },
    { key = "hintColorLeft", type = "color", label = "Hint color (turn left)" },
    { key = "resetDefaults", type = "button", label = "Reset to defaults" },
    -- ...all LockpickSettings settings
  },
  get = function(key) ... end,         -- menu reads the current value to display
  onChange = function(key, value) ... end, -- menu pushes a change; the mod applies + SAVES
})
```
- Cross-mod exposure: SharedModMenu publishes a single well-known global table
  (the one place the no-globals rule is intentionally broken, since inter-mod
  APIs need a rendezvous). Load order puts SharedModMenu first; consumers also
  defensively register whenever the API appears (handshake), so order is not
  fragile.

## Configuration
- SharedModMenu's own `config.lua`: the open hotkey (default `F1`), maybe the
  accent color and panel opacity.
- Each consumer keeps its own `config.lua` as the defaults; the menu writes a
  small per-mod override (e.g. `<Mod>/settings.save.lua`) loaded over the
  defaults at startup, via the atomic-save technique from `chests/store.lua`.

## Performance
- The menu is inert until opened (and the game is paused while open). Building
  rows is a one-time pass on open. No per-frame Lua. Negligible cost.

## Build / toolchain (summary; full click-by-click guide is a separate deliverable)
1. Install Unreal Engine 5.4.x (Epic Games Launcher), matching the game's 5.4.
2. Create a blank Blueprint project (no starter content).
3. Build `WBP_SharedModMenu` + the four row widgets + the Add*/event functions,
   engine-UMG only.
4. Add the BPModLoaderMod loader actor.
5. Cook for Windows and package the pak; place it in the game's `LogicMods`
   folder so BPModLoaderMod loads it.
- The IoStore/LogicMods load path on G1R is the least-certain step and needs a
  test cook to confirm (see Risks).

## Update strategy
- The widget references only engine UMG, so it survives ordinary game content
  patches. It must be RE-COOKED only if the game bumps its engine version
  (5.4 -> 5.5) or changes the cooked-asset/IoStore format. NOT per game build.
- The Lua side is patch-safe like the other Lua mods.

## Risks / open questions
- BIGGEST RISK: a zero-Unreal-experience user completing the cook + IoStore /
  LogicMods packaging. This is the hardest, least-deterministic milestone; the
  guide must be exhaustive and we should expect iteration.
- IoStore packaging for BPModLoaderMod on G1R: confirm whether a loose `.pak` in
  `LogicMods` mounts, or an IoStore container is required. Needs a test cook.
- BP widget input/pause/cursor (SetInputModeUIOnly + SetGamePaused +
  bShowMouseCursor) is standard UMG but must be verified inside G1R.
- The cross-mod API rendezvous (global + handshake) must tolerate any load order.

## Done criteria (v1)
- In-game: press the hotkey -> menu opens (paused, cursor), shows a
  "LockpickSettings" section with all its settings as toggle/slider/color/button
  rows; changing any applies live AND persists across a restart; closing restores
  play.
- Reusability proven: a second (even dummy) mod can register and appear as its
  own section without touching SharedModMenu's code.
- Graceful absence verified both directions.

## Delivery split
- I produce now (this repo): the `G1R/SharedModMenu` scaffold, the Lua framework
  + consumer API, the LockpickSettings integration module, the exact BP<->Lua
  contract doc, the click-by-click UE build guide, and the blue Nexus page.
- The user produces (UE 5.4 editor, following the guide): the `.uasset` widget,
  the loader actor, the cook, and the packaged pak in `LogicMods`.
- "Working v1" is reached when the user completes the editor steps against this
  contract; everything on the Lua/repo side is ready to meet it.
