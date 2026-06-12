-- LockpickSettings configuration
-- Apply edits with a game restart, or CTRL+R ingame (UE4SS hot reload).

return {
    -- Extra lockpick durability added on top of the vanilla per-tier value
    -- (untrained 2, trained 4, master 6), as a per-tier table:
    --        extraTries = { untrained = 5, trained = 10, master = 20 }
    --     giving 7 / 14 / 26. A tier left out (or set to 0) stays vanilla.
    -- Keep each tier's boosted TOTAL clear of the other tiers' vanilla bases
    -- (2 / 4 / 6) and of each other, so the tier stays detectable; a colliding
    -- tier is skipped with a log line and left vanilla. The vanilla bases are
    -- game constants and live in boost.lua, not here.
    extraTries = { untrained = 5, trained = 10, master = 20 },

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

    -- Auto-solve: let the mod drive the lock for you, fast. It collapses the
    -- move animation and runs the route on a tight cadence, so the lock solves
    -- in a couple of seconds. The hotkey solves the CURRENT lock and stops by
    -- itself the moment it opens; press it again to cancel. Held with the
    -- "every" modifier below it toggles FULL-AUTO mode: every lock you open then
    -- solves itself automatically (press the modifier+hotkey again to turn it
    -- off, which also cancels a solve in progress). It re-plans once if a move
    -- is refused. Set the hotkey to "" to disable. Needs the next-move feature
    -- to be available.
    autoSolveHotkey        = "F6",
    -- Modifier held with the hotkey to toggle full-auto-every-lock mode:
    -- "SHIFT", "CONTROL", "ALT", or "" to disable that toggle.
    autoSolveEveryModifier = "SHIFT",
    -- Full-auto-every-lock state at game launch. false = opt-in (toggle it live
    -- with the modifier+hotkey). true = every lock auto-solves from the start.
    autoSolveEvery         = false,
    -- How FAST the auto-solver moves: the lock's piece interpolation speed while a
    -- solve runs (vanilla baseline is 20). The driver only plays the next move once
    -- the previous one has visibly settled, so this value alone sets the pace. High
    -- snaps each move and clears the lock in a couple of seconds (1000 = the fast
    -- default). LOWER it to make the solve glide at a human-watchable pace, so a
    -- guard can still walk up and catch you mid-pick: 20 matches a normal manual
    -- move, 40 to 80 is brisk but visible. The scene's original is restored on stop.
    autoSolveSpeed         = 1000,

    -- Log solver internals (moved sets, replans, calibration) to the
    -- UE4SS log. ALPHA DEFAULT: on, so bug reports arrive with a full solver
    -- trace already in UE4SS.log. The output is a few lines per lock plus one
    -- per settled move, not per-frame spam. Set to false for quiet play
    -- (restart or CTRL+R).
    debugSolver = true,
}
