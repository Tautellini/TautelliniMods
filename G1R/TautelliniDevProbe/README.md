# TautelliniDevProbe

One mod that holds all the active dev probes, so there is a single `enabled.txt`, a
single deploy, and a single place that assigns hotkeys (no more per-probe folders and
`XXenabled.txt` renaming, and no key clashes). **DEV-ONLY.**

## Layout

- `Scripts/main.lua` loads each probe module, registers its keys once and hooks once
  (tracked in a persistent global so CTRL+R never double-registers), dispatches
  through a table refreshed every load (so edits hot-reload), detects key conflicts,
  and logs the full keymap on load.
- `Scripts/probes/*.lua` one file per probe, each `return function(ctx) ... return
  { name, keys, hooks } end`. Add a probe by dropping a file in `probes/` and adding
  its name to `MODULES` in `main.lua`.

## Keymap

Reserved keys avoided: F4/F5 (player save/load), F9 (default load), F11 (window
resize), F6/F7/F8 (LockpickSettings), F10 (ConsoleEnabler). Only F1/F2/F3/F12 are used,
NO modifiers (Shift combos proved unreliable on this build), so each key does one thing.

- **F1** archery: dump GAS attributes (Dexterity) + ArcheryComponent + equipped weapon
- **F2** umg: S3 spike, probe UMG building blocks (safe)
- **F3** umg: S3 spike, CreateWidget + AddToViewport attempt (RISKY, throwaway save)
- **F12** asread: AS read sweep (by-name read + live instance + enumerate)

Retired (render paths measured dead 2026-06-13): menucap/S0 (no Lua ImGui) and
canvas/S2 (HUD `ReceiveDrawHUD` never fires). Findings recorded in the tuner plan.

Archery's native `[bow]` hooks auto-arm and fire on a real shot. All output is tagged
`[DevProbe:<probe>]` in `UE4SS.log`.

## Safety

Hot-reload-safe: nothing dangerous runs at load, every UObject deref goes through the
shared kit guard (`kit.engine.guard`). The `asread` keys (F9/F11/F12) exercise the
AngelScript read frontier; the validated route is safe, but a bad target (e.g. a chest
class) can still hard-crash, so use a throwaway save when poking new AS classes.
Forensic `ABOUT TO` logging pinpoints any crash.

## Probes

Active (in `MODULES`): `archery` (F1), `asread` (F12), `lockbuild` (F3), `sleep`
(F10 / Shift+F10 / Ctrl+F10 / numpad / * -). Kept on disk but NOT loaded: `gamepad.lua`
(shelved, FKey input is a dead end on this build) and `menu.lua` (graduated into the standalone
SharedModMenu mod).

Consolidated from the old per-probe mods (ArcheryProbe, ASReadProbe, LockBuildProbe, SleepProbe).
The retired/concluded ones (CanvasProbe, AngelscriptProbe, AnimSpeedProbe, LockProbe, WeatherProbe)
were removed; their findings live in memory, `LuaModdingSurface.md`, and the shipped mods.
