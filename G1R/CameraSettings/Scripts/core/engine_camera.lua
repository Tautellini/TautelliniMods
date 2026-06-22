-- core/engine_camera.lua -- the mod's engine ADAPTER. The ONLY file naming UE4SS access
-- globals; every call guarded. Resolves the AngelScript camera config and reads/WRITES its
-- reflected fields BY NAME, the proven-safe AS path: StaticFindObject the Default__ object,
-- never GetCDO (see ../../LuaModdingSurface.md and [[g1r-camera-control]]). Writing a field
-- once is enough -- the GothicCameraManager applies this config every frame, so we never tick.

local pcall, ipairs, tonumber = pcall, ipairs, tonumber

local kit = require("kit")
local isValid, guard = kit.engine.isValid, kit.engine.guard

-- captured at load; nil under bare LuaJIT (so this file still LOADS), only CALLED in UE4SS.
local StaticFindObject = StaticFindObject

local CONFIG_PATH = "/Script/Angelscript.Default__DefaultCamera"

local engine = {}

-- the single AngelScript config object, cached and revalidated (a save/level change can
-- replace it). A miss before the AS VM is up just re-looks-up next call, which is cheap.
local cached
local function config()
    if isValid(cached) then return cached end
    cached = nil
    if not StaticFindObject then return nil end
    local ok, o = pcall(StaticFindObject, CONFIG_PATH)
    if ok and isValid(o) then cached = o end
    return cached
end
engine.config = config
function engine.available() return config() ~= nil end

local function readField(field)
    local cfg = config(); if not cfg then return nil end
    return guard(cfg, function(c) return c[field] end)
end

local function writeField(field, value)
    local cfg = config(); if not cfg then return false end
    return (pcall(function() cfg[field] = value end))
end

function engine.readVector(field)
    local cfg = config(); if not cfg then return nil end
    local x, y, z
    local ok = pcall(function() local v = cfg[field]; x, y, z = v.X, v.Y, v.Z end)
    if ok and tonumber(x) then return { X = x, Y = y, Z = z } end
    return nil
end

-- read the vector, set one component, write it back. Tries a whole-table assign first (and
-- verifies it took), then a per-component assign on the live struct handle, since UE4SS
-- struct-property writes vary across builds.
local function writeVectorComponent(field, component, value)
    local v = engine.readVector(field); if not v then return false end
    v[component] = value
    local cfg = config(); if not cfg then return false end
    if pcall(function() cfg[field] = { X = v.X, Y = v.Y, Z = v.Z } end) then
        local after = engine.readVector(field)
        if after and after[component] == value then return true end
    end
    return (pcall(function() local s = cfg[field]; s.X = v.X; s.Y = v.Y; s.Z = v.Z end))
end

-- apply a catalog control's value to the config (scalar field list, or a vector component)
function engine.applyControl(control, value)
    if control.field then
        local ok = true
        for _, f in ipairs(control.field) do
            if not writeField(f, value) then ok = false end
        end
        return ok
    elseif control.vector then
        return writeVectorComponent(control.vector, control.component, value)
    end
    return false
end

-- read a control's current value from the config (used to capture the vanilla snapshot)
function engine.readControl(control)
    if control.field then
        return readField(control.field[1])
    elseif control.vector then
        local v = engine.readVector(control.vector)
        return v and v[control.component] or nil
    end
    return nil
end

return engine
