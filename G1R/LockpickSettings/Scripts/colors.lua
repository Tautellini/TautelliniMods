-- colors.lua  --  color validation and the resolved hint palette (PURE)
--
-- Keeps the color literals and the {r,g,b} validation out of the engine-write
-- file. build(config) is called once at load by main.lua; the frozen palette
-- is handed to the Tinter constructor. Zero UE4SS globals, loadable under
-- bare LuaJIT.

local type = type
local tonumber = tonumber

local colors = {}

-- validate a config {red, green, blue} triple (0..1) into an {R,G,B,A} struct
-- the engine accepts; fall back to the given default when the triple is
-- missing or malformed.
function colors.colorFrom(v, fallback)
    if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
        return { R = tonumber(v[1]), G = tonumber(v[2]), B = tonumber(v[3]), A = 1.0 }
    end
    return fallback
end

-- resolve the whole hint/partner palette from config, with the exact default
-- colors the mod has always shipped:
--   hintLeft  green  = turn the hinted piece left
--   hintRight blue   = turn it right
--   hintNeutral yellow = direction not yet measured, do not gamble
--   partnerSame purple = dragged WITH the selected piece
--   partnerOpp  red    = dragged AGAINST it
function colors.build(config)
    config = config or {}
    local colorFrom = colors.colorFrom
    return {
        hintLeft = colorFrom(config.hintColorLeft,
            { R = 0.10, G = 1.00, B = 0.15, A = 1.0 }),
        hintRight = colorFrom(config.hintColorRight,
            { R = 0.15, G = 0.45, B = 1.00, A = 1.0 }),
        hintNeutral = colorFrom(config.hintColorNeutral,
            { R = 1.00, G = 0.95, B = 0.20, A = 1.0 }),
        partnerSame = colorFrom(config.partnerColorSame,
            { R = 0.55, G = 0.10, B = 1.00, A = 1.0 }),
        partnerOpp = colorFrom(config.partnerColorOpposite,
            { R = 1.00, G = 0.15, B = 0.15, A = 1.0 }),
    }
end

return colors
