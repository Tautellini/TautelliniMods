-- connections.lua  --  Connection Display feature: the partner tint map (PURE).
--
-- The pieces the currently selected piece would drag along glow, direction
-- coded: purple = travel WITH the selected piece (dir 1), red = travel AGAINST
-- it (dir -1). No engine, separately testable. The Tinter applies the map.

local ipairs = ipairs

local connections = {}

function connections.partnerTints(s, palette)
    local out = {}
    for _, e in ipairs(s.edges[s.selectedRow] or {}) do
        out[e.b] = (e.dir == 1) and palette.partnerSame or palette.partnerOpp
    end
    return out
end

return connections
