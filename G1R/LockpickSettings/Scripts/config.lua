-- LockpickSettings configuration
-- Apply edits with a game restart, or CTRL+R ingame (UE4SS hot reload).

return {
    -- Extra tries added on top of the vanilla per-tier durability
    -- (untrained 2, trained 4, master 6), giving 12/14/16 by default.
    -- Keep it large enough that a boosted value can never collide with
    -- another tier's vanilla base. The vanilla base values themselves are
    -- game constants and live in the code (boost.lua), not here, because
    -- changing them would break tier detection.
    extraTries = 10,

    -- Next-move hint: the piece you should move next is tinted,
    -- recomputed after every move from the lock's live state. Works
    -- identically with keyboard and controller; the direction colors
    -- calibrate themselves from your first move. Tracking runs from
    -- the start of every lock regardless of this setting, so toggling
    -- the highlight on mid-pick is exact; the hotkey only switches the
    -- paint. This is the state at game start.
    showNextMove = false,

    -- Hotkey that toggles the next-move hint ingame (UE4SS key name,
    -- e.g. "F7", "F8", "H"). Set to "" to disable the hotkey.
    nextMoveHotkey = "F7",

    -- Hint colors as {red, green, blue} with 0..1 values, encoding
    -- WHICH WAY to turn the hinted lock: hintColorLeft (default green)
    -- shows when turning left is correct, hintColorRight (default blue)
    -- when turning right is. Set both to the same color if you prefer
    -- a plain hint without direction encoding.
    hintColorLeft  = { 0.10, 1.00, 0.15 },
    hintColorRight = { 0.15, 0.45, 1.00 },

    -- Shown if the turn direction is ever not derivable (should not
    -- happen; the mapping comes from the lock stage's fixed geometry).
    hintColorNeutral = { 1.00, 0.95, 0.20 },

    -- Show the pieces connected to your currently SELECTED piece in
    -- purple: they will move along when you turn it. Selection is
    -- tracked from the game's own input events (keyboard and
    -- controller) and re-anchors itself on every actual move. This is
    -- the state at game start; toggle ingame with the hotkey.
    showConnections = false,

    -- Hotkey that toggles the connection display ingame ("" disables).
    connectionsHotkey = "F8",

    -- Colors of connected pieces as {red, green, blue} with 0..1
    -- values: purple for pieces dragged in the SAME direction as the
    -- selected piece, red for pieces dragged in the OPPOSITE direction.
    partnerColorSame     = { 0.55, 0.10, 1.00 },
    partnerColorOpposite = { 1.00, 0.15, 0.15 },

    -- Log solver internals (moved sets, replans, calibration) to the
    -- UE4SS log. ALPHA DEFAULT: on, so bug reports arrive with a full solver
    -- trace already in UE4SS.log. The output is a few lines per lock plus one
    -- per settled move, not per-frame spam. Set to false for quiet play
    -- (restart or CTRL+R).
    debugSolver = true,
}
