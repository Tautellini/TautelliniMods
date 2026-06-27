-- FastTravelAnywhere config. Edit then restart (or CTRL+R) the game.
-- Menu changes are saved to saved_settings.lua and override these on next launch; delete that
-- file to reset to the values here.

return {
    -- On-map teleport: press the hotkey while the world map is open to teleport to the cursor.
    onMapTeleport = true, -- default ON

    -- The on-map teleport hotkey. A UE4SS key name (e.g. "T", "F", "G"). Empty = no key bound.
    hotkey = "T",

    -- Minimum seconds between teleports. A teleport plus the area loading around you takes a moment,
    -- so this paces presses and stops accidental spam.
    teleportCooldown = 1.0,

    -- Log every teleport step (cursor, DPI, computed map + world coords). Use this to diagnose the
    -- on-map teleport. Off keeps the consumer log quiet.
    debug = false,

    -- Capture mode: when true, Shift + the hotkey logs your CURRENT world coordinates as a ready
    -- to paste locations.lua entry, so you can curate the quick-travel list. Dev aid; leave off
    -- for normal play.
    captureCoords = false,

    -- ------------------------------------------------------------- Immersive Mode --
    -- Make fast travel cost ore (Erzbrocken) by distance, and optionally advance the clock. The
    -- whole feature is gated on this and ships OFF; turn it on for the immersive experience. Both
    -- the on-map teleport and the quick-travel list are charged.
    immersiveMode = false,

    -- The adjustable cost ratio: ore per 100 m of straight-line distance (also a menu slider).
    oreCostPer100m = 3,

    -- Floor and cap on the ore cost, so short hops are not near-free and cross-map jumps stay
    -- payable. Cost = clamp(round(oreCostPer100m * metres / 100), oreCostMin, oreCostMax).
    oreCostMin = 3,
    oreCostMax = 50,

    -- The ore currency item class. ItMi_Orenugget is the Gothic ore nugget (Erzbrocken).
    currencyItem = "ItMi_Orenugget",

    -- Advance the in-game clock on a paid teleport (only matters when immersiveMode is on).
    advanceTime = true,

    -- In-game minutes added per 100 m of distance when advanceTime is on.
    timeMinutesPer100m = 20,

    -- Cap on how many in-game minutes a single teleport may advance the clock, so one long jump never
    -- skips an absurd amount at once. 180 = 3 hours.
    maxTimeAdvanceMin = 180,

    -- Seconds to wait after a teleport before advancing the clock, so the area you arrived in has
    -- streamed in first. The skip runs the game's world catch-up; doing it mid-stream crashed the
    -- game. Rapid teleports merge into one skip once you stop moving for this long.
    timeSkipDelaySec = 2.0,

}
