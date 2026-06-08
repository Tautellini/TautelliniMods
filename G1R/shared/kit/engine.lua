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
local pcall = pcall
local FindAllOf = FindAllOf

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

return engine
