-- travel/cost.lua -- PURE ore-cost + distance math for Immersive Mode. No engine, no UE4SS globals
-- (loads under bare Lua for tests). Distance is in world units (1 uu = 1 cm); the player position
-- and map targets reach here already in those units. See IMMERSIVE-MODE-SPEC.md.

local floor = math.floor
local format = string.format

local cost = {}

-- straight-line 2D distance between two world points, in world units
function cost.distance(ax, ay, bx, by)
    local dx, dy = (bx or 0) - (ax or 0), (by or 0) - (ay or 0)
    return (dx * dx + dy * dy) ^ 0.5
end

-- world units -> metres (1 uu = 1 cm)
function cost.metres(units) return (units or 0) / 100 end

-- human distance string: "450 m" below 1 km, "1.20 km" above
function cost.formatDistance(units)
    local m = (units or 0) / 100
    if m >= 1000 then return format("%.2f km", m / 1000) end
    return format("%.0f m", m)
end

-- ore cost of a jump. cfg = { per100m, minCost, maxCost }. cost = clamp(round(per100m * metres/100)).
function cost.ore(units, cfg)
    cfg = cfg or {}
    local m = (units or 0) / 100
    local raw = floor((cfg.per100m or 0) * (m / 100) + 0.5)
    local lo = cfg.minCost or 0
    if raw < lo then raw = lo end
    local hi = cfg.maxCost
    if hi and raw > hi then raw = hi end
    return raw
end

-- in-game minutes to advance for a jump. cfg = { minutesPer100m, max }. Clamped to max (a per-jump
-- cap so one teleport never skips an absurd amount).
function cost.travelMinutes(units, cfg)
    cfg = cfg or {}
    local m = (units or 0) / 100
    local mins = (cfg.minutesPer100m or 0) * (m / 100)
    if cfg.max and mins > cfg.max then mins = cfg.max end
    return mins
end

-- human minutes string: "45 min" below an hour, "1h 31m" above
function cost.formatMinutes(mins)
    mins = floor((mins or 0) + 0.5)
    if mins >= 60 then return format("%dh %02dm", floor(mins / 60), mins % 60) end
    return format("%d min", mins)
end

return cost
