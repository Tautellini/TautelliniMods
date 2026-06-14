# SharedModMenu - Blueprint + pak build guide (zero Unreal experience)

> **OBSOLETE (2026-06-13).** This whole BP-widget + cooked-`.pak` approach is NO
> LONGER NEEDED. We proved a pure-Lua UMG menu builds and renders fine from UE4SS
> reflection (Create UserWidget + StaticConstructObject the widget tree +
> AddToViewport; mouse via the LMB keybind + GetMousePositionOnViewport; camera
> lock via SetInputMode_UIOnlyEx). SharedModMenu is now a PURE-LUA mod, no Unreal,
> no cooking, no pak. See `plans/shared-mod-menu.md` and the working renderer in
> `G1R/TautelliniDevProbe/Scripts/probes/menu.lua`. Kept only for historical
> reference / if a BP path is ever wanted.

How to build the `SharedModMenu` widget in Unreal Engine 5.4 and package it into
a `.pak` that `BPModLoaderMod` loads into Gothic 1 Remake. Written for someone who
has never opened Unreal.

The conventions below are not guessed: they are read from the game's installed
`BPModLoaderMod` (`...\ue4ss\Mods\BPModLoaderMod\Scripts\main.lua`). It scans
`G1R\Content\Paks\LogicMods\` for `.pak` files, and for a pak named `X.pak` it
spawns the actor class `ModActor_C` from the package path `/Game/Mods/X/ModActor`.
So our pak must be `SharedModMenu.pak` and contain an actor at
`/Game/Mods/SharedModMenu/ModActor`.

Work in PHASES. Do not build the whole widget first. Phase B proves the
cook+pak+load pipeline with a trivial actor BEFORE you invest time in the UI,
because packaging is the part most likely to fight you.

--------------------------------------------------------------------------------
## Phase A - Install the tools and make the project

1. Install the **Epic Games Launcher**, then in it the **Unreal Engine** tab ->
   install **5.4.x** (match the game's engine; the game runs UE 5.4). This is a
   large download (tens of GB). Pick the latest 5.4.x.
2. Install **Visual Studio 2022 Community** with the "Game development with C++"
   workload IS NOT required for a Blueprint-only mod. Skip it.
3. Launch UE 5.4 -> **Games** -> **Blank** -> **Blueprint** (not C++) ->
   **No Starter Content** -> Quality/raytracing defaults are fine.
   - **Name the project exactly `G1R`.** This matters: cooked asset paths are
     prefixed with the project name, and naming it `G1R` makes `/Game/...` in
     your pak resolve to the game's `/Game/...`. A different name means the pak
     mounts at the wrong path and the loader never finds the actor.
4. Project Settings (Edit -> Project Settings) -> **Packaging**:
   - Turn **Use Io Store** OFF (we want a loose `.pak`, which BPModLoaderMod
     mounts; the game's own content is IoStore, our mod is not).
   - Leave **Use Pak File** ON.
   - "Include Engine Content" can stay default.

--------------------------------------------------------------------------------
## Phase B - Prove the pipeline with a hello-world pak (do this first)

Goal: get an empty actor to spawn in-game, logged by BPModLoaderMod, before any
UI work. If this fails, nothing else can work, so de-risk it now.

1. Content Browser -> create folders so you have `Content/Mods/SharedModMenu/`.
   (Right-click -> New Folder, twice.)
2. In `Content/Mods/SharedModMenu/`, right-click -> **Blueprint Class** ->
   **Actor** -> name it **`ModActor`** (exactly). Open it.
3. In the Event Graph, off **Event BeginPlay**, add a **Print String** node with
   text like `SharedModMenu ModActor spawned`. Compile, Save.
4. Cook it: menu **Platforms -> Windows -> Cook Content** (wait for "Cook
   complete"). Cooked files land under
   `G1R\Saved\Cooked\Windows\G1R\Content\Mods\SharedModMenu\` (ModActor.uasset
   and .uexp).
5. Pak just that folder. Open a terminal and run UnrealPak with a response file:
   - UnrealPak is at
     `<UE install>\Engine\Binaries\Win64\UnrealPak.exe`.
   - Make a file `filelist.txt` with one line per cooked file, mapping the cooked
     path to a mount path under `G1R\Content\`:
     ```
     "C:\...\G1R\Saved\Cooked\Windows\G1R\Content\Mods\SharedModMenu\ModActor.uasset" "../../../G1R/Content/Mods/SharedModMenu/ModActor.uasset"
     "C:\...\G1R\Saved\Cooked\Windows\G1R\Content\Mods\SharedModMenu\ModActor.uexp"   "../../../G1R/Content/Mods/SharedModMenu/ModActor.uexp"
     ```
   - Run:
     ```
     UnrealPak.exe "C:\out\SharedModMenu.pak" -create="C:\out\filelist.txt"
     ```
6. Copy `SharedModMenu.pak` into the game's
   `...\Gothic 1 Remake\G1R\Content\Paks\LogicMods\` (create `LogicMods` if it
   is not there).
7. Launch the game. Open `...\ue4ss\UE4SS.log` and search for `BPModLoaderMod`.
   You want to see it load `SharedModMenu` and a line that the `ModActor` was
   spawned (and your Print String may show on screen briefly).

If Phase B does not show the actor spawning, STOP and fix packaging before going
on (most likely: project not named `G1R`, IoStore left on, wrong mount path in
the response file, or pak not in `LogicMods`). This is the expected hard part.

--------------------------------------------------------------------------------
## Phase C - Build the menu widget (WBP_SharedModMenu)

This is the bulk of the UI work. Build it once Phase B passes.

1. In `Content/Mods/SharedModMenu/`, right-click -> **User Interface ->
   Widget Blueprint** -> name it **`WBP_SharedModMenu`**.
2. Root layout: add a full-screen **Border** (dark, ~80% opacity) -> inside it a
   **Vertical Box** -> a **Text** title ("MOD MENU") -> a **Scroll Box** named
   `OptionsList` (this is where rows get added) -> a **Close** Button at the
   bottom.
3. Make four small reusable row widgets (each its own Widget Blueprint in the
   same folder), so the menu can add them dynamically:
   - `WBP_RowToggle`  : a Text label + a CheckBox.
   - `WBP_RowSlider`  : a Text label + a Slider + a Text value readout.
   - `WBP_RowColor`   : a Text label + three small Sliders (R/G/B) + a color swatch Image.
   - `WBP_RowButton`  : a Button with a Text label.
   - `WBP_SectionHeader` : a bold Text label (the per-mod section title).
   Use ONLY these engine UMG widgets. Do not reference any game class, that is
   what keeps the pak alive across game content patches.
4. On `WBP_SharedModMenu`, add these **functions/events** (the contract the Lua
   side calls; names and parameters must match EXACTLY):
   - `ClearMenu()` : clears `OptionsList`'s children.
   - `AddSection(ModName: string)` : add a `WBP_SectionHeader` to `OptionsList`.
   - `AddToggle(ModName: string, Key: string, Label: string, Current: bool)`.
   - `AddSlider(ModName: string, Key: string, Label: string, Min: int, Max: int, Current: int)`.
   - `AddColor(ModName: string, Key: string, Label: string, R: float, G: float, B: float)`.
   - `AddButton(ModName: string, Key: string, Label: string)`.
   - `SetMenuOpen(Open: bool)` : Open -> AddToViewport (if needed),
     `SetVisibility(Visible)`, `SetInputModeUIOnly`, show mouse cursor, and
     `Set Game Paused = true`; Close -> hide, `SetInputModeGameOnly`, hide cursor,
     `Set Game Paused = false`, then call the `OnMenuClosed` dispatcher.
   - Each Add* creates the matching row widget, fills its label/value, stores
     `ModName`+`Key` on the row, and binds the row's control change to fire one of
     the dispatchers below.
5. Add these **Event Dispatchers** on `WBP_SharedModMenu` (the contract the Lua
   side hooks). The Lua framework subscribes to these to learn about changes:
   - `OnToggleChanged(ModName: string, Key: string, Value: bool)`.
   - `OnSliderChanged(ModName: string, Key: string, Value: int)`.
   - `OnColorChanged(ModName: string, Key: string, R: float, G: float, B: float)`.
   - `OnButtonPressed(ModName: string, Key: string)`.
   - `OnMenuClosed()`.
   When a row's CheckBox/Slider/Button changes, call the matching dispatcher with
   the row's stored `ModName`+`Key` and the new value.

--------------------------------------------------------------------------------
## Phase D - Wire the loader actor to the widget

1. Open `ModActor` (from Phase B). On **Event BeginPlay**:
   - **Create Widget** -> class `WBP_SharedModMenu` -> promote the result to a
     variable `Menu` (make it Instance Editable / public is not needed).
   - Do NOT add to viewport yet, and do NOT open it. The Lua side will call
     `SetMenuOpen(true)` when the hotkey is pressed.
   - Store the widget so Lua can reach it. Simplest: keep `Menu` as a public
     variable on `ModActor`; the Lua framework finds the `ModActor` instance via
     FindAllOf and reads `Menu`, then calls the widget's functions and binds its
     dispatchers.
2. Compile, Save.

--------------------------------------------------------------------------------
## Phase E - Cook, pak, install, test with the Lua framework

1. Re-cook (Platforms -> Windows -> Cook Content). Now the cooked output includes
   `WBP_SharedModMenu`, the row widgets, and `ModActor`.
2. Re-pak: add every new cooked file (each `.uasset`/`.uexp` under
   `...\Content\Mods\SharedModMenu\`) to `filelist.txt` and re-run UnrealPak to
   rebuild `SharedModMenu.pak`.
3. Copy `SharedModMenu.pak` to `...\G1R\Content\Paks\LogicMods\` (overwrite).
4. Make sure the SharedModMenu Lua mod (the framework I provide, deployed under
   `...\ue4ss\Mods\SharedModMenu\`) is enabled, and LockpickSettings is updated to
   register with it.
5. Launch. Press the menu hotkey (default `F1`). The menu should open paused with
   a cursor, show a `LockpickSettings` section with its rows, and changing a row
   should apply live and persist. Close restores play.

--------------------------------------------------------------------------------
## Notes and gotchas

- **Project must be named `G1R`** and **Use Io Store OFF**, or the pak mounts at
  the wrong path and the loader cannot find `/Game/Mods/SharedModMenu/ModActor`.
- The actor MUST be named `ModActor` and live at `/Game/Mods/SharedModMenu/`
  inside the project, matching the pak file name `SharedModMenu.pak`.
- Keep EVERYTHING in the widget to engine-standard UMG. No game classes, so the
  pak only needs re-cooking if the game bumps its engine version (5.4 -> 5.5),
  not on ordinary content patches.
- Load order, if it ever matters, is set in
  `...\ue4ss\Mods\BPModLoaderMod\load_order.txt`.
- The cook+pak step (Phase B/E) is the iteration-prone part. Re-run the Phase B
  smoke test whenever packaging behaves oddly.

The Lua side (the framework, the `ModMenu.register` API, finding `ModActor` and
its `Menu`, calling the Add* functions, subscribing to the dispatchers, and the
LockpickSettings integration) is the part I produce in this repo; it is written to
match the exact function and dispatcher names above.
