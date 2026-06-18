-- LockpickSettings config. Edit then restart the game.
-- Menu/hotkey changes are saved to saved_settings.lua and override these on next
-- launch; delete that file to reset.

return {
    -- Extra durability per skill tier, on top of vanilla 2/4/6. 0 = vanilla.
    extraTries = { untrained = 5, trained = 10, master = 20 },

    -- Next-move hint: tints the piece to move next. State at launch.
    showNextMove = false,
    nextMoveHotkey = "F7", -- "" disables the key

    -- Hint colors {r,g,b} 0..1: green = turn left, blue = turn right.
    hintColorLeft  = { 0.10, 1.00, 0.15 },
    hintColorRight = { 0.15, 0.45, 1.00 },
    hintColorNeutral = { 1.00, 0.95, 0.20 }, -- direction unknown (rare)

    -- Connection display: tints the selected piece's partners. State at launch.
    showConnections = false,
    connectionsHotkey = "F8", -- "" disables the key

    -- Partner colors {r,g,b} 0..1: same drag direction / opposite.
    partnerColorSame     = { 0.55, 0.10, 1.00 },
    partnerColorOpposite = { 1.00, 0.15, 0.15 },

    -- Auto-solve: F6 solves the current lock (press again to cancel).
    autoSolveHotkey        = "F6", -- "" disables
    autoSolveEveryModifier = "SHIFT", -- mod+F6 toggles full-auto-every-lock; "" disables
    autoSolveEvery         = false,   -- full-auto state at launch

    -- Animation speed: how fast each move glides (vanilla 20, ~500 = instant).
    -- Lower it to get caught mid-pick. Visual only. Clamped 10..500.
    autoSolveAnimationSpeed = 250,

    -- Move rate / stability knob: ms per solved move. Lower = faster but pokes
    -- UE4SS's buggy action queue harder = more crash-prone. Clamped 25..500.
    -- Live in the menu as "Tick (DANGER)".
    autoSolveTickMs        = 50,

    -- Log solver internals to UE4SS.log (a few lines per lock).
    debugSolver = true,
}
