-- palette.lua -- resolve config color triples into {R,G,B,A} structs for the Tinter.

local kit = require("kit")

local palette = {}

function palette.build(config)
    config = config or {}
    local colorFrom = kit.color.colorFrom
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

return palette
