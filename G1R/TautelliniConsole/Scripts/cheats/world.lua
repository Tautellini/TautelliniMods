-- cheats/world.lua  --  setweather (more world commands land here later).
--
-- Weather is the Ultra Dynamic Sky controller's EWeather enum (an int). setweather
-- forces it immediately via engine.setWeather. PURE of UE4SS globals: engine is
-- injected. See ../../docs/cheat-techniques.md.

local require, tonumber, ipairs, tostring = require, tonumber, ipairs, tostring
local args = require("util.args")

local world = {}

-- friendly name -> EWeather id, and id -> label for feedback.
local WEATHER_IDS = {
    sunny = 0, clear = 0, sun = 0,
    rain = 1, drizzle = 1, rain2 = 2, rain3 = 3, storm = 3, thunderstorm = 3,
    cloudy = 4, overcast = 4,
}
local WEATHER_NAMES = { [0] = "Sunny", [1] = "Rain", [2] = "Rain 2", [3] = "Storm", [4] = "Cloudy" }

local function resolveWeather(token)
    if token == nil then return nil end
    local id = WEATHER_IDS[args.lower(token)]
    if id == nil then
        local n = tonumber(token)
        if n and WEATHER_NAMES[n] then id = n end
    end
    return id
end

local function apply(engine, id)
    return engine.setWeather(id), WEATHER_NAMES[id] or tostring(id)
end

local function doWeather(params, out, engine)
    local id = resolveWeather(params[1])
    if id == nil then
        out.line("usage: setweather <sunny|rain|rain2|storm|cloudy> (or 0-4)")
        return
    end
    local ok, label = apply(engine, id)
    out.line("setweather: " .. (ok and label or ("FAILED (" .. label .. "; controller not found?)")))
end

function world.specs()
    return {
        { name = "setweather",
          help = "set weather: sunny|rain|rain2|storm|cloudy (or 0-4)",
          run = function(p, out, engine) doWeather(p, out, engine) end },
    }
end

-- SharedModMenu: one button per weather (a dropdown is not a menu control here).
function world.menu(engine)
    local items = {}
    for _, w in ipairs({ { 0, "Sunny" }, { 1, "Rain" }, { 3, "Storm" }, { 4, "Cloudy" } }) do
        local id = w[1]
        items[#items + 1] = { name = w[2], kind = "action", set = function() engine.setWeather(id) end }
    end
    return { title = "Weather", items = items }
end

return world
