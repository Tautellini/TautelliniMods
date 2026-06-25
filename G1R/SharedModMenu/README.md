# SharedModMenu

An optional, standalone in-game settings menu for Gothic 1 Remake, **pure Lua** (no Blueprint,
no pak). Any UE4SS Lua mod registers its settings and they appear as a tab; with this mod not
installed, that registration is a harmless no-op, so your mod ships one integration that works
either way.

## For mod authors

Drop **one file** into your mod and call `register` once at startup. Copy `modmenu.lua` (from
this mod's `Scripts/`) into your own `Scripts/`, then:

```lua
-- pcall the require so a missing file can never break your mod
local ok, modmenu = pcall(require, "modmenu")
if ok and modmenu then
  modmenu.register("MyMod", {
    { name = "God Mode",  kind = "bool", desc = "Take no damage",
      get = function() return cfg.god end,
      set = function(v) cfg.god = v; applyGod() end },

    { name = "Move Speed", kind = "num", min = 0.1, max = 5, step = 0.1,
      get = function() return cfg.speed end,
      set = function(v) cfg.speed = v; applySpeed() end },

    { name = "Reset", kind = "action",
      set = function() resetConfig() end },
  })
end
```

**Your mod never depends on SharedModMenu at runtime.** Because you vendor `modmenu.lua` into your
own `Scripts/`, `require("modmenu")` resolves to your local copy and always succeeds, the `pcall`
is just belt-and-suspenders. And when SharedModMenu is not installed, `register` simply publishes
to a store nobody reads, a harmless no-op. So the menu is purely additive: it never has to be
present for your mod to work.

Your `get`/`set` stay in your mod; `modmenu` transports the schema + values to the menu and
applies edits back through `set`, so your mod is the single source of truth and the menu is just a
view. `modmenu.lua` is fully self-contained (standard Lua + the UE4SS globals `ModRef`/
`LoopAsync`), so vendoring it adds no other files and no shared-kit dependency.

### Sub-tabs

Each mod is one top tab. To split your settings into sub-tabs, register a list of sections
instead of a flat list:

```lua
modmenu.register("MyMod", {
  { title = "Combat", items = { ... } },
  { title = "World",  items = { ... } },
})
```

### Item kinds

| kind | control | fields |
|---|---|---|
| `bool` | `[ ON ] / [ OFF ]` toggle | |
| `num` | `[-]` / `[+]`, plus a click-to-set bar when `min`+`max` are given | `min`, `max`, `step` |
| `action` | `[ RUN ]` button | |

`get()` returns the current value; `set(v)` applies it (your mod owns storage and persistence).

### Descriptions

**New in 1.3.0.** Any item, of any kind, may carry an optional **`desc`**: a short one-line hint
shown to the right of the value, so players understand a setting without leaving the game.

```lua
{ name = "Move Speed", kind = "num", min = 0.1, max = 5, step = 0.1,
  desc = "How fast you run", get = ..., set = ... }
```

Keep it to a phrase. The panel widens to fit the longest description in a section, and an
over-long one is trimmed with an ellipsis. `desc` is **fully optional and version-safe**: omit it
and nothing changes, and a player on a SharedModMenu older than 1.3.0 simply will not see it (the
field is ignored, your mod still works). So you can add descriptions today without forcing anyone
to update. `color`/`enum` kinds are planned.

## Controls

- Toggle with the configured key (default **F2**).
- Mouse: click a tab or sub-tab to switch, a row to select, `[-]`/`[+]`/the bar/`[ ON/OFF ]`/
  `[ RUN ]` to act, `[X]` to close.
- Numpad: `8`/`2` select item, `4`/`6` change value, `5` run the selected `[ RUN ]` action (or flip
  the selected `[ ON/OFF ]`), `7`/`9` sub-tab, `1`/`3` mod tab.

Every key above is remappable in `Scripts/config.lua` (`menuKey` plus the `keys` table). Key
changes take effect on the next game start; all other settings hot-reload with CTRL+R.

## Install & config

Drop the `SharedModMenu` folder into UE4SS `Mods/` (it ships an `enabled.txt`). No `mods.txt`
edit. The toggle key is this mod's own `Scripts/config.lua` (`menuKey`); there is no shared
config file, every other setting belongs to the mod that registered it.

## How it works (one line)

UE4SS runs each Lua mod in an isolated state, so `modmenu.lua` bridges registrations over UE4SS
shared variables (scalars only, serialized); a ~250 ms poll in each consumer applies menu edits.
