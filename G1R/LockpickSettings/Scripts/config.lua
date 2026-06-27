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

    -- ------------------------------------------------------------ Immersive Mode --
    -- Make F6 auto-solve COST lockpicks and require skill, both scaled by the lock's difficulty (its
    -- connection count). Off by default. While it is on, the Shift+F6 full-auto-every-lock mode is
    -- disabled (no free auto-clearing of every lock). A tooltip on the minigame shows the lock's
    -- difficulty, your lockpicks, the pick cost and the skill it needs (red when you cannot meet it);
    -- a solve you cannot afford or lack the skill for is refused.
    immersiveMode = false,

    -- The lockpick item counted and consumed (ItKe_Lockpick = the Gothic lockpick / Dietrich).
    lockpickItem = "ItKe_Lockpick",

    -- Lockpicks an F6 solve costs, per connection of the lock, then clamped:
    -- cost = clamp(round(lockpicksPerConnection * connections), lockpickCostMin, lockpickCostMax).
    lockpicksPerConnection = 0.5,
    lockpickCostMin        = 1,
    lockpickCostMax        = 15,

    -- Picklock skill TIER the lock demands, set by its connection count (its difficulty) via two
    -- thresholds. A lock with fewer than skilledAtConnections needs only Untrained. From there up to
    -- masterAtConnections it needs Skilled. At or above masterAtConnections it needs Master. You need
    -- your LockpickPrecision at or above the demanded tier for F6 to solve. Defaults fit the game's
    -- range (3..10 connections, ceiling 11): Untrained handles <=4 (24 locks), Skilled 5..9 (285),
    -- Master >=10 (the 108 hardest locks).
    skilledAtConnections = 5,
    masterAtConnections  = 10,

    -- Log solver internals to UE4SS.log (a few lines per lock).
    debugSolver = true,

    -- DEV diagnostic: when debugSolver is on, this key maps the live lock's active edges and
    -- compares them to the shipped variants (explains a "disagrees with the precision variant"
    -- lock). "" disables. It drives reversible probe moves on the open lock, so use a save you
    -- do not mind poking.
    debugEdgeMapHotkey = "F10",
}
