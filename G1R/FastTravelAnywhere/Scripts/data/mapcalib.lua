-- data/mapcalib.lua -- baked map(UICustomSize space) -> world affine, per map. PORTABLE: the map
-- coordinate space is fixed per map asset, so these constants hold for every player at every
-- resolution. The on-screen placement (cursor -> map) is computed LIVE from the DPI scale, not
-- baked here. See travel/pipeline.lua and the [[map-teleport-mod]] memory.
--
-- world map dot->world fit (5 precise points, max error 45/11 world units, sub-pixel):
--   worldX = ax*mapX + cx ; worldY = ay*mapY + cy   (axis-aligned: cross terms are zero)
return {
    -- The overworld map (UIMapConfigWorldHuman, UICustomSize 1600x900).
    world = {
        M = { ax = -138.484464, cx = 227935.3681, ay = -131.972110, cy = -45186.9795 },
        -- Nudge (MAP units) added to the cursor's map position before map->world so the player
        -- MARKER lands on the cursor (the pin icon draws above its true point). Positive y pulls the
        -- landing DOWN the map (mapY grows downward): RAISE y if the marker lands above the cursor,
        -- LOWER it if below. Portable (map units, DPI independent).
        cursorOffset = { x = 0, y = 16.5 },
    },
    -- City / area maps get their own entry once calibrated (own-the-map-to-travel feature).
}
