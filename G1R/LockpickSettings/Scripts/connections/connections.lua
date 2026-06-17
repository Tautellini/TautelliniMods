-- connections.lua -- the partner tint map (PURE, no engine). purple = drags WITH the
-- selected piece (dir 1), red = AGAINST (dir -1). The Tinter applies it.

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
