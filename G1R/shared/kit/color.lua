-- generic color decoding (PURE, no engine). Validation only; building a
-- specific palette is a mod concern.
local type = type
local tonumber = tonumber

local color = {}

-- validate a config {red, green, blue} triple (0..1) into the {R,G,B,A} struct
-- the engine accepts; fall back to the given default when missing/malformed.
function color.colorFrom(v, fallback)
    if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
        return { R = tonumber(v[1]), G = tonumber(v[2]), B = tonumber(v[3]), A = 1.0 }
    end
    return fallback
end

return color
