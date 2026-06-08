-- num.lua  --  tiny stateless numeric helpers (PURE: zero UE4SS globals)
--
-- Shared, engine-free math so the same arithmetic is written and reviewed
-- once instead of duplicated across the engine-facing files. Loadable under
-- bare LuaJIT.

local math = math
local pairs = pairs

local num = {}

-- exact-value table lookup that tolerates float fuzz: tier base values and
-- boosted targets arrive as attribute reads and can carry tiny error.
function num.lookup(tbl, value)
    for k, v in pairs(tbl) do
        if math.abs(value - k) < 0.001 then return v end
    end
    return nil
end

-- squared RGB distance between two {R,G,B} colors (alpha ignored). Used to
-- tell our own paint from the game's selected-glow signature.
function num.colorDist2(c, ref)
    local dr, dg, db = c.R - ref.R, c.G - ref.G, c.B - ref.B
    return dr * dr + dg * dg + db * db
end

return num
