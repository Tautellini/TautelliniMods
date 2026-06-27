-- engine.lua  --  generic UE4SS access PRIMITIVES (game-agnostic)
--
-- Holds NO domain literals (no Slot_/HighlightColor/MPC_/m_Lock/GameplayAbility/
-- PlayerState). A mod adds its own domain reads in its OWN engine adapter and
-- re-exports these primitives. A CI grep (tests/) fails the build on any leak.
--
-- pcall does NOT catch native access violations. Wrapping is necessary but
-- INSUFFICIENT: the first defense is NEVER doing the dangerous thing. A future
-- mod reusing these primitives must obey the same refusals
-- (see G1R/LuaModdingSurface.md):
--   * NO TMap iteration via reflection (correlated with native AVs).
--   * NO GetCDO()/StaticFindObject on AngelScript class objects.
--   * NO instance property reads off AS class objects.
--   * NO K2_GetActorLocation on the broken part-actor decode path; read the
--     runtime ROOT COMPONENT instead (readRootPos).

local ipairs = ipairs
local string = string
local tonumber = tonumber
local type = type
local pcall = pcall
local FindAllOf = FindAllOf
local StaticFindObject = StaticFindObject
local StaticConstructObject = StaticConstructObject

local engine = {}

-- live (non-CDO) instances of a class, valid only. Continuous FindAllOf polling
-- causes hitches; callers cache the results and poll lean.
function engine.liveInstances(className)
    local out = {}
    local ok, found = pcall(FindAllOf, className)
    if ok and found then
        for _, obj in ipairs(found) do
            if obj:IsValid() and not string.find(obj:GetFullName(), "Default__", 1, true) then
                out[#out + 1] = obj
            end
        end
    end
    return out
end

-- decode a runtime root component's world position as {x,y,z}, or nil. The
-- RelativeLocation struct read decodes when MemberVariableLayout is active and
-- equals K2_GetComponentLocation; either path serves. part.rr is the component.
function engine.readRootPos(part)
    -- IsValid (a safe object-table slot read, never a deref) BEFORE the native
    -- location read: on the FindAllOf fallback the component can belong to a stale
    -- or destroyed actor, and pcall does NOT catch the access violation that reading
    -- a dead component raises.
    if not (part and engine.isValid(part.rr)) then return nil end
    local x, y, z
    local okp = pcall(function()
        local v = part.rr.RelativeLocation
        x, y, z = v.X, v.Y, v.Z
    end)
    if not (okp and tonumber(x) and tonumber(y) and tonumber(z)) then
        okp = pcall(function()
            local v = part.rr:K2_GetComponentLocation()
            x, y, z = v.X, v.Y, v.Z
        end)
    end
    if okp and tonumber(x) and tonumber(y) and tonumber(z) then
        return { x, y, z }
    end
    return nil
end

-- ------------------------------------------------------------- native safety --
-- pcall is necessary but NOT sufficient: it catches a Lua error, NOT a native
-- access violation. The real guard against the most common AV, dereferencing a
-- handle whose UObject was destroyed or GC'd, is a fresh IsValid() BEFORE the
-- deref. These wrap that doctrine so callers stop hand-rolling pcall+IsValid at
-- every site. They do NOT make a BANNED operation safe: TMap iteration,
-- GetCDO/StaticFindObject or instance-prop reads on AngelScript classes still AV
-- on a perfectly valid object (see the refusals at the top of this file). guard()
-- defends the stale/destroyed-handle class of crash, the one IsValid catches.

-- true only if obj is a live UObject. IsValid() is itself the designed-safe check
-- (it reads the object-table slot, never derefs the object); the pcall makes a nil
-- or a non-UObject value return false instead of erroring.
function engine.isValid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return (ok and v) and true or false
end

-- run fn(obj) ONLY when obj is a valid UObject, with the whole call pcall-wrapped.
-- Returns fn's result, or nil when obj is invalid or fn raised a Lua error. This is
-- the one-liner for "touch this object if it is still alive"; route every cached
-- deref through it instead of a bare pcall:
--   local name = engine.guard(obj, function(o) return o:GetFullName() end)
function engine.guard(obj, fn)
    if not engine.isValid(obj) then return nil end
    local ok, r = pcall(fn, obj)
    if ok then return r end
    return nil
end

-- a bare guarded call for work that is NOT centred on a single UObject (a
-- StaticFindObject lookup, a numeric/struct read): returns fn()'s result, or nil on
-- a caught Lua error. Same caveat: catches Lua errors, NOT native AVs.
function engine.try(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

-- ------------------------------------------------------------------ UMG / widgets --
-- These name the construction globals (StaticFindObject / StaticConstructObject) so the
-- pure kit files do not have to. They are generic UE access, no game-domain knowledge.

-- find an object by full path (a CDO, a class), valid only. e.g.
-- engine.find("/Script/UMG.Default__WidgetBlueprintLibrary").
function engine.find(path)
    local obj = engine.try(function() return StaticFindObject(path) end)
    if engine.isValid(obj) then return obj end
    return nil
end

-- construct a new UObject of class `cls` under `outer`. Returns it (valid) or nil.
function engine.construct(cls, outer)
    local obj = engine.try(function() return StaticConstructObject(cls, outer) end)
    if engine.isValid(obj) then return obj end
    return nil
end

-- the first live instance of a class (convenience over liveInstances).
function engine.firstLive(className)
    return engine.liveInstances(className)[1]
end

-- the viewport size in PIXELS plus the UMG DPI scale, read off a world-context UObject
-- `ctx` (a live widget or controller). UMG canvas slots live in DESIGN space (pixels /
-- scale), so a caller converts. Returns w, h, scale, or nil.
function engine.viewport(ctx)
    local lib = engine.find("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (engine.isValid(lib) and engine.isValid(ctx)) then return nil end
    local w, h, sc
    local ok = engine.try(function()
        local sz = lib:GetViewportSize(ctx)
        w, h = sz.X, sz.Y
        sc = lib:GetViewportScale(ctx)
        return true
    end)
    if not (ok and type(w) == "number" and type(h) == "number") then return nil end
    if type(sc) ~= "number" or sc <= 0 then sc = 1 end
    return w, h, sc
end

return engine
