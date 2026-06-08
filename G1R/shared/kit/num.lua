-- generic numeric helpers (PURE, no engine).
local math = math
local pairs = pairs

local num = {}

-- exact-value table lookup that tolerates float fuzz (attribute reads carry
-- tiny error).
function num.lookup(tbl, value)
    for k, v in pairs(tbl) do
        if math.abs(value - k) < 0.001 then return v end
    end
    return nil
end

-- squared RGB distance between two {R,G,B} colors (alpha ignored).
function num.colorDist2(c, ref)
    local dr, dg, db = c.R - ref.R, c.G - ref.G, c.B - ref.B
    return dr * dr + dg * dg + db * db
end

return num
