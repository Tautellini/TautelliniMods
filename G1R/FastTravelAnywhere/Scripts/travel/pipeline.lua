-- travel/pipeline.lua -- PURE cursor->world math. No engine, no UE4SS globals (loads under bare
-- LuaJIT for tests). The screen placement (cursor->map) is computed from the live viewport + DPI
-- scale; the geography (map->world) is the baked affine in data/mapcalib. See [[map-teleport-mod]].

local pipeline = {}

-- design-space cursor -> map (UICustomSize) coords. The map widget is UICustomSize design units,
-- centered in the design viewport (dw x dh = physical viewport / DPI), so subtracting the centering
-- offset recovers the map-space position. No DPI math here: everything is already in design space.
function pipeline.cursorToMap(cdx, cdy, dw, dh, uw, uh)
    if not (cdx and cdy and dw and dh and uw and uh) then return nil end
    return cdx - (dw - uw) / 2, cdy - (dh - uh) / 2
end

-- is a map coord inside the map image (0..uw, 0..uh)? gates teleport to clicks actually on the map.
function pipeline.inMap(mapX, mapY, uw, uh, margin)
    margin = margin or 0
    return mapX ~= nil and mapY ~= nil
        and mapX >= -margin and mapX <= uw + margin
        and mapY >= -margin and mapY <= uh + margin
end

-- map coords -> world via the baked axis-aligned affine M = { ax, cx, ay, cy }.
function pipeline.mapToWorld(M, mapX, mapY)
    if not (M and mapX and mapY) then return nil end
    return M.ax * mapX + M.cx, M.ay * mapY + M.cy
end

return pipeline
