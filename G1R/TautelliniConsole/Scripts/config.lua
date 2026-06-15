-- TautelliniConsole configuration
-- Apply edits with a game restart, or CTRL+R ingame (UE4SS hot reload).

return {
    -- Prepended to every command name. "" (default) gives plain names: god, str,
    -- heal, time. Set it to e.g. "tc_" to namespace the whole command set at once
    -- (tc_god, tc_str, ...), which avoids clashing with a game or other-mod
    -- console command. A prefix change takes effect on a game RESTART (the old
    -- names stay registered but inert until then).
    commandPrefix = "",

    -- Echo command results to the UE4SS log as well as the console output device,
    -- so results are visible from either the native ~ console or the UE4SS
    -- console window. Left on; turn off for quieter logs.
    verbose = true,

    -- Fly vertical keys (UE key names), polled WHILE FLYING. The game ignores
    -- jump/block/sneak once you are airborne, so flight up/down has to read the
    -- physical keys directly. Set these to whatever you want to hold for rise and
    -- descend. Examples: "SpaceBar", "LeftControl", "LeftShift", "C", "X".
    flyUpKey   = "SpaceBar",
    flyDownKey = "LeftControl",
}
