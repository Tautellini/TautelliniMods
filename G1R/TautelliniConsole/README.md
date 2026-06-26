# TautelliniConsole

A console cheat layer for Gothic 1 Remake, built entirely in UE4SS Lua. It
registers cheat commands and surfaces a console to type them in. No pak, no
Blueprint, no dependency on the game's stripped Marvin/cheat exec functions: it
works over the reflected property surface mapped in `../LuaModdingSurface.md`.

Full design and decisions: `plans/tautellini-console.md`.

## Using it

Open a console and type commands. Two front-ends, either works:

- The in-game native console (this mod tries to surface it on `Tilde` / `F10`).
- The UE4SS console window (always available).

Type `help` for the full list. Command names take an optional global prefix
(`config.lua` -> `commandPrefix`, empty by default, e.g. set `"tc_"`).

### Commands

The full, maintained command reference is **[`COMMANDS.md`](COMMANDS.md)** (every
command, its arguments, and whether it has a menu control). In short: player/combat
(`god`, `heal`, `mana`, `oxygen`, `nofatigue`, `parrycheat`, `onehit`), stats (`str`,
`dex`, `level`, `skillpoints`, `xp`, `speed`), items (`additem`, `removeitem`),
skills (`addskill`, `removeskill`), lockpicking (`lockskill`), time (`time`,
`skiptime`, `freezetime`, `timescale`), world (`setweather`), movement (`fly`,
`noclip`, `runspeed`), and the generic `set` / `dumpobj` / `help`.

The cheats call the game's own functions rather than writing GAS internals, so the
HUD updates; the approach is documented in
[`docs/cheat-techniques.md`](docs/cheat-techniques.md).

## In-game menu (SharedModMenu)

If the optional [SharedModMenu](../SharedModMenu) mod is installed, this mod adds a
**TautelliniConsole** tab so the cheats are clickable as well as typeable. With
SharedModMenu absent, the integration is a harmless no-op, you lose nothing. Open
the menu with its key (default `F2`).

| Sub-tab | Items |
|---|---|
| **Player** | God Mode, Auto-Parry, One-Hit Kills (toggles); Heal, Restore Mana, Restore Oxygen, Clear Fatigue (buttons) |
| **Stats** | Strength, Dexterity, Level, Skill Points (sliders) |
| **Lockpicking** | Untrained / Skilled / Master (buttons) |
| **Movement** | Fly Mode, No-Clip (toggles); Run Speed (slider) |
| **Time** | Hour 0-23 (slider); Set 08:00 / 12:00 / 20:00 (buttons); Freeze Clock (toggle); Game Speed (slider) |
| **Weather** | Sunny / Rain / Storm / Cloudy (buttons) |

The menu and the console drive the **same** code, so a toggle flipped either way
stays in sync. Some commands stay console-only because they do not fit a
toggle/slider/button: `additem`/`removeitem` and `addskill`/`removeskill` (text ids),
`set`/`dumpobj`/`help` (text + arguments), `skiptime`, and minute-precise time
(use `time HH:MM`).

Adding the tab is opt-in per module: a cheat module exposes a `menu(engine)`
returning one `{ title, items }` section, and `core/menu.lua` collects them, so a
future command lands in the menu by adding that one function.

## Build / deploy

```
powershell -File tools\deploy.ps1 -Mod TautelliniConsole
```

This copies `Scripts/` and vendors the shared kit under `shared/kit/`. Press
`CTRL+R` in-game to hot reload, or restart the game.

## Tests

```
powershell -File G1R\TautelliniConsole\tests\run.ps1
```

Runs `check_load.lua` (every module loads under bare LuaJIT) plus the pure-logic
suites (`args`, `registry`, `stats`, `menu`, `lockpicking`). The engine-touching code
is verified in-game.

## Status

v0.3.2, alpha. Adds combat toggles (parry, one-hit), items, skills, lockpicking
(`lockskill`, three tier buttons), time (skip/freeze/speed) and weather on top of the
v1 set, all driven through the game's own functions (see `docs/cheat-techniques.md`)
so the HUD stays in sync. god and heal are play-confirmed; the newer commands,
`lockskill` included, need an in-game smoke test. NPC/spawn/world commands are on the
roadmap in `COMMANDS.md`.
