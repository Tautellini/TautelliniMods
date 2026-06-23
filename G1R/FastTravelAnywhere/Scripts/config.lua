-- FastTravelAnywhere config. Edit then restart (or CTRL+R) the game.
-- Menu changes are saved to saved_settings.lua and override these on next launch; delete that
-- file to reset to the values here.

return {
    -- On-map teleport: press the hotkey while the world map is open to teleport to the cursor.
    onMapTeleport = true, -- default ON

    -- The on-map teleport hotkey. A UE4SS key name (e.g. "T", "F", "G"). Empty = no key bound.
    hotkey = "T",

    -- Safe landing: before an on-map teleport, check the click and a small ring around it and land on
    -- flat ground instead of a rock face. It stays on the exact click when that is already flat, and
    -- only nudges you (up to 3 m) when it is not. Turn off to teleport to the precise click point.
    safeLanding = true, -- default ON

    -- Expand search: when the close check finds only steep ground (or water/void) near the cursor,
    -- widen the search in stages out to maxSearchRange and use the closest flat spot found, instead of
    -- giving up. Turn off to only ever check right around the cursor.
    expandSearch = true, -- default ON

    -- How far (cm) the expanded search may look for flat ground. 3000 = 30 m.
    maxSearchRange = 3000,

    -- How flat a surface must be to count as safe to stand on, as the upward part of its normal
    -- (1 = dead flat). Measured: open ground ~0.9-1.0, a moderate mountain ledge ~0.85, a cliff face
    -- ~0.3. Lower this to allow steeper landings, raise it to be pickier.
    minFlatness = 0.85,

    -- How far (cm) a landing spot may sit above or below the point you clicked. Stops the search from
    -- dropping you onto flat ground at the bottom of a canyon far below the click. 1500 = 15 m. Raise
    -- it to allow bigger height changes, lower it to keep landings closer to the clicked elevation.
    maxElevationDelta = 1500,

    -- With safe landing on: if even the expanded search finds no flat ground, skip the teleport
    -- entirely rather than dropping you on a cliff or in water. Turn off to always teleport to the
    -- closest ground found, even when it is steep.
    cancelIfUnsafe = true, -- default ON



    -- Minimum seconds between teleports. A teleport plus the area loading around you takes a moment,
    -- so this paces presses and stops accidental spam.
    teleportCooldown = 1.0,

    -- Log every teleport step (cursor, DPI, computed map + world coords, and the safe-landing
    -- traces). Use this to diagnose the on-map teleport. Off keeps the consumer log quiet.
    debug = false,

    -- Capture mode: when true, Shift + the hotkey logs your CURRENT world coordinates as a ready
    -- to paste locations.lua entry, so you can curate the quick-travel list. Dev aid; leave off
    -- for normal play.
    captureCoords = false,
}
