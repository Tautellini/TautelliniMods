-- LockpickSettings configuration
-- Apply edits with a game restart, or CTRL+R ingame (UE4SS hot reload).

return {
    -- Vanilla tries (LockpickDurability) per skill tier. Used to recognize
    -- the tier at minigame start AND as the base the bonus is added to.
    -- If a game patch ever changes these, fix them here.
    baseTries = {
        untrained = 2,
        trained   = 4,
        master    = 6,
    },

    -- Added on top of the base: 2/4/6 -> 12/14/16 tries.
    -- Keep it large enough that the boosted values can never collide with
    -- another tier's base value.
    extraTries = 10,

    -- Next-move hint: the piece you should move next is tinted green,
    -- recomputed after every move from the lock's live state. Entirely
    -- state-driven: needs no input tracking, works identically with
    -- keyboard and controller. Tracking runs from the start of every
    -- lock regardless of this setting, so toggling the highlight on
    -- mid-pick is exact; the hotkey only switches the green paint.
    -- This is the state at game start.
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

    -- Log solver internals (moved sets, replans, calibration) to the
    -- UE4SS log. Leave false for normal play.
    debugSolver = false,
}
