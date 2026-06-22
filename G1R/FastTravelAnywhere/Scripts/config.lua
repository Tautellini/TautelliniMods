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

    -- Log every teleport step (cursor, DPI, computed map + world coords). Use this to diagnose
    -- the on-map teleport. Off keeps the consumer log quiet.
    debug = false,

    -- Capture mode: when true, Shift + the hotkey logs your CURRENT world coordinates as a ready
    -- to paste locations.lua entry, so you can curate the quick-travel list. Dev aid; leave off
    -- for normal play.
    captureCoords = false,
}
