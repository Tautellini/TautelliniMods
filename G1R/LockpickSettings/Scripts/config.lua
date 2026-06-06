-- EasyLockpicking configuration (v8 bare minimum)
-- Read once when the mod loads (game start). Restart the game after edits.

return {
    -- Every lockpicking minigame starts with at least this many tries
    -- (failures before the pick breaks). Vanilla Untrained has 4, so
    -- 14 = vanilla + 10. The floor applies to every skill tier, so no
    -- tier ever starts a minigame with fewer tries than this.
    minTries = 14,
}
