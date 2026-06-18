-- engine_lock.lua -- the lockpicking engine adapter (the only file with Gothic
-- domain literals). Re-exports the generic kit primitives so session/tinter/boost
-- see one `engine` surface. pcall does NOT catch native AVs; the IsValid gates here
-- are the real guard (banned-ops rules live in kit/engine.lua + LuaModdingSurface.md).

local ipairs = ipairs
local string = string
local os = os
local pcall = pcall
local type = type
local tostring = tostring
local FName = FName
local StaticFindObject = StaticFindObject

local kit = require("kit")

local engine = {}
engine.liveInstances = kit.engine.liveInstances
engine.readRootPos = kit.engine.readRootPos
local isValid = kit.engine.isValid
engine.isValid = isValid

-- Cached singleton handles. A FindAllOf scan walks the whole object array and is a frame
-- hitch, so the session-long singletons (the LockPickSubsystem and the player's attribute
-- set) are resolved once and reused. Each resolver revalidates with isValid() on use, and
-- engine.dropHandles() clears them on a world change (main's InitGameStatePost hook).
local subsysCache = nil
local attrSetCache = nil

-- the active lock's FName, via the current task's owning Ability (m_Lock). Abilities
-- are reused, so prefer the freshest notify-captured spawn.
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

-- the live LockPickSubsystem, CACHED: a session-long singleton, so the ~30ms FindAllOf
-- runs once instead of every lock open. The scene actor it owns IS per-minigame and is
-- read fresh by mpcHandles below; only the subsystem handle is cached here.
local function lockPickSubsystem()
    if subsysCache and isValid(subsysCache) then return subsysCache end
    subsysCache = nil
    for _, sub in ipairs(engine.liveInstances("LockPickSubsystem")) do
        subsysCache = sub
        return sub
    end
    return nil
end

-- the KismetMaterialLibrary CDO, the MPC_Lockpicking asset (both cheap StaticFindObject
-- hash lookups), and the live scene actor read off the CACHED subsystem. Returns
-- lib, mpc, scene or nil. No FindAllOf once the subsystem is cached.
function engine.mpcHandles()
    local lib, mpc, scene
    pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary") end)
    pcall(function() mpc = StaticFindObject("/Game/Blueprints/LockPick/MPC_Lockpicking.MPC_Lockpicking") end)
    local sub = lockPickSubsystem()
    if sub then
        pcall(function()
            local sc = sub.m_LockSceneActor
            if sc and sc:IsValid() then scene = sc end
        end)
    end
    if lib and lib:IsValid() and mpc and mpc:IsValid() and scene then
        return lib, mpc, scene
    end
    return nil
end

-- the player's lockpicking AttributeSet (the one under PlayerState), CACHED. Boost and
-- the precision read both need it, so resolving it here makes them share ONE scan, and
-- the cache makes later opens free. isValid() plus the PlayerState identity check
-- re-resolve a stale handle after a save-load / respawn.
function engine.playerLockAttrSet()
    local hit = attrSetCache
    if hit and isValid(hit) then
        local ok, full = pcall(function() return hit:GetFullName() end)
        if ok and full and string.find(full, "PlayerState", 1, true) then return hit end
    end
    attrSetCache = nil
    for _, s in ipairs(engine.liveInstances("AttributeSet_Lockpicking")) do
        local ok, full = pcall(function() return s:GetFullName() end)
        if ok and full and string.find(full, "PlayerState", 1, true) then
            attrSetCache = s
            return s
        end
    end
    return nil
end

-- player's lockpicking GAS attributes (native, safe read): LockpickPrecision (=
-- connections the game prunes) and LockpickDurability. GAS exposes each as an
-- FGameplayAttributeData (CurrentValue/BaseValue) or a bare number.
function engine.lockpickAttributes()
    local function valueOf(a)
        if type(a) == "number" then return a end
        if a == nil then return nil end
        local v
        pcall(function() v = a.CurrentValue end)
        if type(v) ~= "number" then pcall(function() v = a.BaseValue end) end
        return type(v) == "number" and v or nil
    end
    local set = engine.playerLockAttrSet()
    if not set then return nil end
    local out
    pcall(function()
        out = { precision = valueOf(set.LockpickPrecision),
                durability = valueOf(set.LockpickDurability) }
    end)
    if out and (out.precision or out.durability) then return out end
    return nil
end

-- read MPC Slot_i as {R,G,B} (the live per-piece world position). h carries the
-- lib/scene/mpc handles. IsValid-gate the scene: it can die mid-open and pcall can't
-- catch the AV reading a dead scene.
function engine.readSlot(h, i)
    if not isValid(h.scene) then return nil end
    local v
    local ok = pcall(function()
        local c = h.lib:GetVectorParameterValue(h.scene, h.mpc, FName("Slot_" .. i))
        v = { c.R, c.G, c.B }
    end)
    if not ok then return nil end
    return v
end

-- write HighlightColor on every MID of a piece (re-applied per tick; the game's hover
-- overwrites it). IsValid-gate per MID: a cached MID can die and pcall can't catch the AV.
function engine.writeColor(e, color)
    for _, mid in ipairs(e.mids) do
        pcall(function()
            if mid:IsValid() then
                mid:SetVectorParameterValue(FName("HighlightColor"), color)
            end
        end)
    end
end

-- read/write the scene's piece interpolation speed (baseline 20). Cranking it snaps
-- the move glide (the auto-solve speed lever; restored on stop). IsValid-gate: the
-- scene actor is torn down on open and pcall can't catch the AV indexing a dead AActor.
function engine.getSceneInterp(scene)
    if not isValid(scene) then return nil end
    local v
    local ok = pcall(function() v = scene.m_LockPieceInterpolationSpeed end)
    if ok then return v end
    return nil
end

function engine.setSceneInterp(scene, value)
    if not isValid(scene) then return false end
    return (pcall(function() scene.m_LockPieceInterpolationSpeed = value end))
end

-- read a MID's current HighlightColor (to spot the game's glow vs our own paint).
-- IsValid-gate per call, same staleness risk as writeColor.
function engine.readHighlight(mid)
    local c
    local ok = pcall(function()
        if mid:IsValid() then
            c = mid:K2_GetVectorParameterValue(FName("HighlightColor"))
        end
    end)
    if ok and c then return c end
    return nil
end

-- the ONLY write that DRIVES the minigame: press a task input UFunction (up/down move
-- selection, left/right turn the piece). INPUT-STATE DEPENDENT (moves in some sessions,
-- inert in others), so the caller confirms each press from the measured state. Liveness
-- checked per call (pcall can't catch the AV on a dead task). Returns true if dispatched.
function engine.pressInput(freshTask, which)
    if not freshTask or not freshTask.obj then return false end
    local ok = pcall(function()
        local obj = freshTask.obj
        if not obj:IsValid() then error("task not valid") end
        if which == "up" then obj:UpPressed()
        elseif which == "down" then obj:DownPressed()
        elseif which == "left" then obj:LeftPressed()
        elseif which == "right" then obj:RightPressed()
        else error("unknown press '" .. tostring(which) .. "'") end
    end)
    return ok
end

-- drop the cached singleton handles. Call on a world change: the isValid() revalidation in
-- the resolvers already self-heals, this just avoids carrying a dead wrapper across a GC.
function engine.dropHandles()
    subsysCache = nil
    attrSetCache = nil
end

return engine
