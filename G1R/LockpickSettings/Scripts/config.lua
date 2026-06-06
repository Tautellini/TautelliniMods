-- EasyLockpicking configuration (tries-only v1)
-- Edit values, save, then press CTRL+R ingame to hot-reload.
--
-- The mod grants extra lockpick tries (failures before the pick breaks)
-- ONLY while the lockpicking minigame is running. The boost is applied at
-- minigame start and removed at minigame end; your stored stats and saves
-- stay vanilla.

return {
    -- Extra tries by your VANILLA durability value (= skill tier).
    -- Untrained is 4. The values for Skilled/Master are still unknown;
    -- when you learn the skill, the log line "vanilla durability" tells
    -- us the new number and we add it here.
    extraTriesByVanilla = {
        [4] = 6,    -- Untrained: 4 -> 10 tries
        -- [?] = 3, -- Skilled (value unknown yet)
        -- [?] = 1, -- Master (value unknown yet)
    },

    -- Used when the vanilla value is not in the table above.
    extraTriesDefault = 4,
}
