-- engine_weather.lua  --  the weather engine adapter (mod-specific)
--
-- The ONLY file that holds Gothic weather domain literals (the Ultra Dynamic Sky
-- class names, GetCurrentWeather / SetCurrentWeatherImmediate, the Weather asset
-- property, the atmosphere/flag property names). It RE-EXPORTS the generic kit
-- primitives so the Control sees one `engine` surface, mirroring the
-- LockpickSettings core/engine_lock.lua shape.
--
-- Every engine call is pcall-wrapped. pcall does NOT catch native access
-- violations, so the banned-operations rules in G1R/LuaModdingSurface.md still
-- apply: no TMap iteration via reflection, no GetCDO/StaticFindObject on AS class
-- objects, no instance reads off chest classes. We only ever touch the live world
-- actors (via FindAllOf) and their reflected properties, which the WeatherProbe
-- confirmed safe (2026-06-10).
--
-- THREADING: the weather WRITES (setWeather, write*) must run on the GAME THREAD.
-- This adapter does not marshal threads itself; the caller (the Control, driven by
-- main.lua's poll and its ExecuteInGameThread-wrapped request handlers) guarantees
-- the context. Reads are done from that same game-thread poll and cached, so the
-- ImGui render never touches an engine object directly.

local ipairs = ipairs
local string = string
local pcall = pcall
local tostring = tostring

local kit = require("kit")

-- domain class names of the live Ultra Dynamic Sky actors (AngelScript classes,
-- found by FindAllOf; the spec confirmed these resolve to the live instances).
local CONTROLLER_CLASS = "GothicUltraDynamicControlerAS"
local WEATHER_CLASS    = "GothicUltraDynamicWeatherAS"
local SKY_CLASS        = "GothicUltraDynamicSkyAS"

-- the lock flags, best-effort levers that ASK the game to stop changing the
-- weather. The Control's watchdog is the real guarantee (it re-asserts the chosen
-- preset on drift), so a wrong/absent flag name here is harmless.
local FLAG_RANDOMIZE = "Randomize Weather"
local FLAG_ENABLE_LOGIC = "Enable Logic"

local engine = {}
-- generic primitive, re-exported verbatim from the shared kit
engine.liveInstances = kit.engine.liveInstances

-- first live (non-Default__, valid) instance of a class, or nil.
local function firstLive(className)
    for _, obj in ipairs(engine.liveInstances(className)) do
        return obj -- liveInstances already filters Default__ and IsValid
    end
    return nil
end

function engine.findController() return firstLive(CONTROLLER_CLASS) end
function engine.findWeatherActor() return firstLive(WEATHER_CLASS) end
function engine.findSkyActor() return firstLive(SKY_CLASS) end

-- is a cached actor handle still usable? (cheap, pcall-guarded)
function engine.isValid(actor)
    if not actor then return false end
    local ok, valid = pcall(function() return actor:IsValid() end)
    return ok and valid == true
end

-- the active weather index, or nil. controller:GetCurrentWeather() returns an int.
function engine.getCurrentWeather(controller)
    if not controller then return nil end
    local n
    local ok = pcall(function() n = controller:GetCurrentWeather() end)
    if ok and type(n) == "number" then return n end
    return nil
end

-- DRIVE the weather: SetCurrentWeatherImmediate(index) is the confirmed one-arg
-- call (the 2-arg form fails); SetCurrentWeather(index) is the fallback. MUST be
-- called on the game thread. Returns true if a call dispatched (NOT proof the sky
-- changed; the caller re-reads GetCurrentWeather to confirm).
function engine.setWeather(controller, index)
    if not controller then return false end
    local ok = pcall(function() controller:SetCurrentWeatherImmediate(index) end)
    if ok then return true end
    ok = pcall(function() controller:SetCurrentWeather(index) end)
    return ok
end

-- the preset asset's full name (weatherActor.Weather:GetFullName()), or nil. The
-- pure weather.presets module turns this into a leaf and a label.
function engine.presetName(weatherActor)
    if not weatherActor then return nil end
    local name
    local ok = pcall(function()
        local w = weatherActor.Weather
        if w then name = w:GetFullName() end
    end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- how many presets the controller knows: #controller.ListContainer.Weathers, or
-- nil if unreadable. The WeatherProbe read this exact array. Single read, the
-- caller caches it.
function engine.presetCount(controller)
    if not controller then return nil end
    local n
    local ok = pcall(function()
        local arr = controller.ListContainer.Weathers
        n = #arr
    end)
    if ok and type(n) == "number" and n > 0 then return n end
    return nil
end

-- read a reflected NUMBER property by name (BP names carry spaces), or nil.
function engine.readNumber(actor, propName)
    if not actor then return nil end
    local v
    local ok = pcall(function() v = actor[propName] end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- write a reflected NUMBER property by name. Returns true if the assignment did
-- not error (NOT proof the engine kept it; the lerp may pull a raw value back, see
-- atmosphere.lua's lerp note). Game thread.
function engine.writeNumber(actor, propName, value)
    if not actor then return false end
    return (pcall(function() actor[propName] = value end))
end

-- read a reflected BOOL property by name, or nil.
function engine.readBool(actor, propName)
    if not actor then return nil end
    local v
    local ok = pcall(function() v = actor[propName] end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- write a reflected BOOL property by name. Returns true if it did not error.
function engine.writeBool(actor, propName, value)
    if not actor then return false end
    return (pcall(function() actor[propName] = value end))
end

-- the two known lock levers, set on whichever actor carries them (the spec is not
-- certain which, so the Control hands BOTH the controller and the weather actor).
-- Best-effort: a missing property just pcall-fails. Returns true if any write
-- landed without error.
function engine.setRandomizeWeather(actors, value)
    local any = false
    for _, a in ipairs(actors) do
        if engine.writeBool(a, FLAG_RANDOMIZE, value) then any = true end
    end
    return any
end

function engine.setEnableLogic(actors, value)
    local any = false
    for _, a in ipairs(actors) do
        if engine.writeBool(a, FLAG_ENABLE_LOGIC, value) then any = true end
    end
    return any
end

return engine
