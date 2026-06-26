# TautelliniConsole — command reference

Every command the console registers. Open a console (native `~`/`F10` or the UE4SS
window) and type a command; arguments are space-separated. Names take the optional
global prefix from `config.lua` (`commandPrefix`, empty by default). Items marked
**menu** also appear in the SharedModMenu tab (default `F2`).

The mechanism behind these is in [`docs/cheat-techniques.md`](docs/cheat-techniques.md):
we call the game's own functions (so the HUD updates), never raw GAS writes.

> Make a manual save before world-changing commands; if you dislike the result, reload.

## Player / combat

| Command | Effect | Menu |
|---|---|---|
| `god [on\|off]` | Invulnerability via the `m_GodMode` cheat flag, and a full heal on enable. Toggles with no arg. | Player ▸ God Mode |
| `heal` | Restore Health to full (proper heal path, so the bar updates). | Player ▸ Heal |
| `mana` | Refill Mana to max. | Player ▸ Restore Mana |
| `oxygen` | Refill Oxygen to max. | Player ▸ Restore Oxygen |
| `nofatigue` | Clear tiredness (Fatigue → 0). | Player ▸ Clear Fatigue |
| `parrycheat [on\|off]` | Auto-parry every melee attack (`m_ParryCheatMode`). | Player ▸ Auto-Parry |
| `onehit [on\|off]` | One-hit kills: a huge Strength + Dexterity boost (reverted on off). Magic damage does not scale. | Player ▸ One-Hit Kills |

## Stats

`<stat> add|remove|set <n>`, or bare `<stat>` to print the current value.

| Command | Effect | Menu |
|---|---|---|
| `str` | Strength. `add`/`remove`/`set`. | Stats ▸ Strength |
| `dex` | Dexterity. `add`/`remove`/`set`. | Stats ▸ Dexterity |
| `level` | Character level. `add`/`remove`/`set`. | Stats ▸ Level |
| `skillpoints` | Learn/skill points. `add`/`remove`/`set`. | Stats ▸ Skill Points |
| `xp` | Experience. `add`/`remove` only (no `set`). | — |
| `speed` | Movement-speed multiplier. `add`/`remove`/`set`. | — (experimental) |

## Items

Item ids are the game's `It*` class names (e.g. `ItMi_Gold`, `ItMw_1H_Sword_01`).

| Command | Effect | Menu |
|---|---|---|
| `additem <ItemId> [count]` | Give an item (default count 1). | — |
| `removeitem <ItemId> [count]` | Remove an item; no count removes all of it. | — |

## Skills

Skill names accept the short form (`Acrobatics`) or full (`GE_Skill_Acrobatics`).

| Command | Effect |
|---|---|
| `addskill <Skill>` | Learn a skill for free. |
| `removeskill <Skill>` | Remove a learned skill. |

## Lockpicking

Sets the player's picklock skill to a real in-game tier by granting its
`GE_Skill_Picklock_*` effect, so the game itself drives how locks behave. Granting
the skill is the right lever: a raw `LockpickPrecision` write does not hold (the
game recomputes it from the active skill effects). The middle tier is **Skilled**
in-game; `trained` is accepted as an alias.

| Command | Effect | Menu |
|---|---|---|
| `lockskill` | Print the current tier and precision. | — |
| `lockskill <untrained\|skilled\|master>` | Set the lockpicking skill to that tier (also accepts `trained` for Skilled and `0`-`2`). Clears the other tiers first, so exactly one is active. | Lockpicking ▸ Untrained / Skilled / Master |

## Time

| Command | Effect | Menu |
|---|---|---|
| `time` / `time HH:MM` | Print the clock, or set it (24h, absolute). NPCs resume their routine over time, they do not snap. | Time ▸ Hour + presets |
| `skiptime <seconds>` | Advance the clock by N seconds (3600 = 1h). | — |
| `freezetime [on\|off]` | Freeze/unfreeze the day-night clock (not a combat pause). | Time ▸ Freeze Clock |
| `timescale <value>` | Global game speed: `1` normal, `2` double, `0.5` half. | Time ▸ Game Speed |

## World

| Command | Effect | Menu |
|---|---|---|
| `setweather <sunny\|rain\|rain2\|storm\|cloudy>` | Set the weather immediately (also accepts `0`-`4`). | Weather ▸ buttons |

## Movement

| Command | Effect | Menu |
|---|---|---|
| `fly [on\|off] [speed]` | Free no-clip flight: W/A/S/D + look to move, look up while moving to climb. Optional speed in cm/s (default 1500). Turn off in open space, not inside a wall. | Movement ▸ Fly Mode |
| `noclip [on\|off]` | Toggle collision (fly already disables it). | Movement ▸ No-Clip |
| `runspeed [mult]` | Run-speed multiplier (`1` normal, `2` double); bare prints the current value. | Movement ▸ Run Speed |

## Generic

| Command | Effect |
|---|---|
| `set <class> <prop> <value>` | Reflection write to every instance of a class. |
| `dumpobj <name>` | Print an object's properties. |
| `help` | List all registered commands. |

## Roadmap (not yet implemented)

Reachable with the same approach, queued next: `npclist` / `gotonpc` (teleport to an
NPC), `relationship` (set friend/enemy), `killnpcs` / `killenemy`, `spawnai` (spawn a
creature), `unlocknearby` (chests/doors), `barrier` (colony dome), `clearcrimes`,
`quests` / `setquest` (quest-state flags).
