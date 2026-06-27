-- tests/test_cost.lua -- pure cost math. Run: tools/lua54/lua.exe tests/test_cost.lua
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../Scripts/?.lua;" .. here .. "/../Scripts/?/?.lua;" .. package.path
local cost = require("travel.cost")

local fails = 0
local function check(name, got, want)
    if math.abs(got - want) > 1e-6 then fails = fails + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function checkStr(name, got, want)
    if got ~= want then fails = fails + 1
        print("FAIL " .. name .. ": got '" .. tostring(got) .. "' want '" .. tostring(want) .. "'") end
end

-- distance: a 3-4-5 triangle scaled to world units
check("distance 3-4-5", cost.distance(0, 0, 30000, 40000), 50000)
check("metres", cost.metres(100000), 1000)

-- ore: per100m = 15, 1200 m (120000 uu) -> 15*12 = 180, within [5,250]
check("ore 1200m", cost.ore(120000, { per100m = 15, minCost = 5, maxCost = 250 }), 180)
-- floor clamp: 10 m -> 1.5 -> 2, raised to the minimum 5
check("ore floor", cost.ore(1000, { per100m = 15, minCost = 5, maxCost = 250 }), 5)
-- cap clamp: a huge cross-map jump caps at 250
check("ore cap", cost.ore(1000000, { per100m = 15, minCost = 5, maxCost = 250 }), 250)
-- rounding, no clamp: 200 m -> 15*2 = 30
check("ore round", cost.ore(20000, { per100m = 15 }), 30)

-- format
checkStr("fmt m", cost.formatDistance(45000), "450 m")
checkStr("fmt km", cost.formatDistance(120000), "1.20 km")

-- travel minutes: minutesPer100m = 20, 1200 m -> 20*12 = 240
check("minutes", cost.travelMinutes(120000, { minutesPer100m = 20 }), 240)
check("minutes cap", cost.travelMinutes(120000, { minutesPer100m = 20, max = 180 }), 180)
checkStr("fmt min", cost.formatMinutes(45), "45 min")
checkStr("fmt hour", cost.formatMinutes(91), "1h 31m")

if fails == 0 then print("test_cost OK (all assertions passed)") else print(fails .. " FAILURES"); os.exit(1) end
