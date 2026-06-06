-- EasyLockpicking configuration (v8.2 per-tier)
-- Read once when the mod loads (game start). Restart the game after edits.

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
}
