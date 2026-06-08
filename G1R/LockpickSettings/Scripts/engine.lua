-- engine.lua  --  the single pcall-wrapped UE4SS access boundary
--
-- This is the ONLY shipped file allowed to name a UE4SS global (FindAllOf,
-- StaticFindObject, FName). Every engine touch is pcall-wrapped and every
-- function returns a value or nil so callers degrade. Keeping all engine
-- access here is exactly what lets solver.lua, geometry.lua, num.lua and
-- colors.lua stay loadable under bare LuaJIT.
--
-- pcall does NOT catch native access violations. Wrapping is necessary but
-- INSUFFICIENT: the first line of defense is NEVER DOING THE DANGEROUS THING.
-- The following stay HARD REFUSALS here, not relaxed because the file now
-- looks tidy (see G1R/LuaModdingSurface.md for the why):
--   * NO TMap iteration via reflection (correlates with native AVs); a
--     single-KEY :Find is the only TMap access ever allowed, and we do not
--     need even that.
--   * NO GetCDO()/StaticFindObject on AngelScript CLASS objects (native AV).
--   * NO reading instance properties off AS class objects (reflection
--     garbage + AV).
--   * NO K2_GetActorLocation / GetDistanceTo on the part ACTORS (broken
--     decode path on this build); read the runtime ROOT COMPONENT instead.

-- Capture stdlib + the core UE4SS free-function globals as locals at load:
-- the Lua state is shared and another mod can clobber a global mid-session.
local ipairs = ipairs
local string = string
local os = os
local tonumber = tonumber
local pcall = pcall
local FName = FName
local FindAllOf = FindAllOf
local StaticFindObject = StaticFindObject

local engine = {}

-- live (non-CDO) instances of a class, valid only. Continuous polling with
-- FindAllOf causes hitches; callers cache the results and poll lean.
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

-- the active lock's FName. The TASK is the only object guaranteed to belong to
-- the current minigame; its owning Ability carries m_Lock. Ability objects are
-- REUSED across interactions, so the fresh-spawn shortcut and the world scan
-- can hand a door the previous chest's lock name. Take freshTask/freshAbility
-- (main-owned notify caches) so identity comes from the freshest spawn.
function engine.currentLockName(freshTask, freshAbility)
    if freshTask and os.clock() - freshTask.t < 30.0 then
        local name
        local ok = pcall(function()
            if freshTask.obj:IsValid() then
                name = freshTask.obj.Ability.m_Lock:ToString()
            end
        end)
        if ok and name and name ~= "" and name ~= "None" then return name end
    end
    if freshAbility and os.clock() - freshAbility.t < 30.0 then
        local name
        local ok = pcall(function()
            if freshAbility.obj:IsValid() then
                name = freshAbility.obj.m_Lock:ToString()
            end
        end)
        if ok and name and name ~= "" and name ~= "None" then return name end
    end
    for _, cls in ipairs({ "GameplayAbilityOpen", "GameplayAbilityDoor" }) do
        for _, ab in ipairs(engine.liveInstances(cls)) do
            if string.find(ab:GetFullName(), "PlayerState", 1, true) then
                local name
                local ok = pcall(function() name = ab.m_Lock:ToString() end)
                if ok and name and name ~= "" and name ~= "None" then return name end
            end
        end
    end
    return nil
end

-- the three handles the MPC slot reads need: the KismetMaterialLibrary CDO,
-- the MPC_Lockpicking collection, and the live lock scene actor. Returns
-- lib, mpc, scene or nil.
function engine.mpcHandles()
    local lib, mpc, scene
    pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary") end)
    pcall(function() mpc = StaticFindObject("/Game/Blueprints/LockPick/MPC_Lockpicking.MPC_Lockpicking") end)
    for _, sub in ipairs(engine.liveInstances("LockPickSubsystem")) do
        pcall(function()
            local sc = sub.m_LockSceneActor
            if sc and sc:IsValid() then scene = sc end
        end)
        if scene then break end
    end
    if lib and lib:IsValid() and mpc and mpc:IsValid() and scene then
        return lib, mpc, scene
    end
    return nil
end

-- read MPC Slot_i as {R,G,B} (the live per-piece world position). h carries
-- the .lib/.scene/.mpc handles from mpcHandles (the Session passes itself).
-- Only Slot_0..N-1 per the mined piece count are valid: higher slots keep
-- stale values from earlier scenes.
function engine.readSlot(h, i)
    local v
    local ok = pcall(function()
        local c = h.lib:GetVectorParameterValue(h.scene, h.mpc, FName("Slot_" .. i))
        v = { c.R, c.G, c.B }
    end)
    if not ok then return nil end
    return v
end

-- write the HighlightColor parameter on every MID of a piece entry. The game's
-- hover highlight writes the same parameter, so persistent tints are
-- re-applied per tick by the caller.
function engine.writeColor(e, color)
    for _, mid in ipairs(e.mids) do
        pcall(function() mid:SetVectorParameterValue(FName("HighlightColor"), color) end)
    end
end

-- read the current HighlightColor off a single MID, or nil. Used to observe
-- the game's selected-glow signature and to tell our own paint apart from it.
function engine.readHighlight(mid)
    local c
    local ok = pcall(function() c = mid:K2_GetVectorParameterValue(FName("HighlightColor")) end)
    if ok and c then return c end
    return nil
end

-- decode a part's runtime root component world position as {x,y,z}, or nil.
-- The RelativeLocation struct read decodes on this build (MemberVariableLayout
-- active) and equals K2_GetComponentLocation exactly; either path serves.
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
