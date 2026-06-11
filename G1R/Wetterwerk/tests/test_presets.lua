-- test_presets.lua  --  weather.presets is pure (only string ops), so it tests
-- directly under bare LuaJIT. Pins the leaf/label extraction from the several
-- shapes a UDS_Weather_Settings full name takes.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local presets = require("weather.presets")

local FULL = "UDS_Weather_Settings_C /Game/Blueprints/Weather/Weather_Presets/"
    .. "Gothic_Pressets/Temperate_Decidious_Forest/Gothic_Forest_Sunny.Gothic_Forest_Sunny"

T.add("leaf strips the class prefix, path and Outer.Name duplication", function()
    T.eq(presets.leaf(FULL), "Gothic_Forest_Sunny")
end)

T.add("label drops a redundant Gothic_ and turns underscores into spaces", function()
    T.eq(presets.label(FULL), "Forest Sunny")
end)

T.add("leaf is idempotent on a bare leaf", function()
    T.eq(presets.leaf("Gothic_Forest_Sunny"), "Gothic_Forest_Sunny")
    T.eq(presets.label("Gothic_Forest_Sunny"), "Forest Sunny")
end)

T.add("a trailing _C suffix is stripped", function()
    T.eq(presets.leaf("X /A/B/Gothic_Thunderstorm_C.Gothic_Thunderstorm_C"),
        "Gothic_Thunderstorm")
    T.eq(presets.label("X /A/B/Gothic_Thunderstorm_C.Gothic_Thunderstorm_C"),
        "Thunderstorm")
end)

T.add("a path with no class prefix still resolves", function()
    T.eq(presets.leaf("/Game/Path/Gothic_Snow.Gothic_Snow"), "Gothic_Snow")
end)

T.add("a bare Outer.Name with no slash resolves", function()
    T.eq(presets.leaf("Gothic_Snow.Gothic_Snow"), "Gothic_Snow")
end)

T.add("label is case-insensitive on the Gothic_ prefix", function()
    T.eq(presets.label("gothic_storm"), "storm")
end)

T.add("nil and empty inputs return nil", function()
    T.eq(presets.leaf(nil), nil)
    T.eq(presets.leaf(""), nil)
    T.eq(presets.label(nil), nil)
end)

os.exit(T.run())
