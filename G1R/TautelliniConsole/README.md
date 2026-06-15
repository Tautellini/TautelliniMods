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

### Commands (v1)

| Command | Effect |
|---|---|
| `god [on\|off]` | Invulnerability toggle (fills health, sets DamageMultiplier 0). |
| `heal` / `mana` / `oxygen` | Refill that resource to max. |
| `nofatigue` | Clear tiredness. |
| `str` / `dex` / `level` / `skillpoints` | `add`/`remove`/`set <n>`; bare prints current. |
| `xp` | `add`/`remove <n>` (additive only). |
| `speed` | `add`/`remove`/`set <n>` movement multiplier. |
| `lockmaster` | Max lockpick durability + precision. |
| `time` | Print the clock, or `time 8:30` to set it (24h, absolute). |
| `set <class> <prop> <value>` | Generic reflection write (ALL instances of a class). |
| `dumpobj <name>` | Print an object's properties. |
| `help` | List all commands. |

`time` sets the clock exactly; NPCs resume their routine over time rather than
snapping (that seamless reposition is the separate SleepAnywhere problem).

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
suites (`args`, `registry`, `stats`). The engine-touching code is verified
in-game.

## Status

v1, alpha. The command mechanisms are either proven (attribute writes, the
`GameTimeSubsystem` clock, the stock reflection `set`) or best-effort with a
documented fallback (native console surfacing). In-game smoke test pending.
