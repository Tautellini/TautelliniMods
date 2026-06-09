-- engine_lock.lua  --  the lockpicking engine adapter (mod-specific)
--
-- The ONLY file that holds Gothic-lockpick domain literals (MPC_Lockpicking,
-- Slot_, HighlightColor, m_Lock, GameplayAbility, PlayerState). It RE-EXPORTS
-- the generic kit primitives so session/tinter/boost see one `engine` surface,
-- identical to before the shared split (MOVE-AND-PRESERVE call sites).
--
-- pcall does NOT catch native access violations. The banned-ops rules in
-- kit/engine.lua and G1R/LuaModdingSurface.md still apply here.

local ipairs = ipairs
local string = string
local os = os
local pcall = pcall
local tostring = tostring
local FName = FName
local StaticFindObject = StaticFindObject

local kit = require("kit")

local engine = {}
-- generic primitives, re-exported verbatim from the shared kit
engine.liveInstances = kit.engine.liveInstances
engine.readRootPos = kit.engine.readRootPos

-- the active lock's FName. The TASK is the only object guaranteed to belong to
-- the current minigame; its owning Ability carries m_Lock. Ability objects are
-- REUSED across interactions, so take freshTask/freshAbility (main-owned notify
-- caches) so identity comes from the freshest spawn.
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

-- the three handles the MPC slot reads need: the KismetMaterialLibrary CDO, the
-- MPC_Lockpicking collection, and the live lock scene actor. Returns
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

-- read MPC Slot_i as {R,G,B} (the live per-piece world position). h carries the
-- .lib/.scene/.mpc handles from mpcHandles (the Session passes itself). Only
-- Slot_0..N-1 per the mined piece count are valid; higher slots keep stale
-- values from earlier scenes.
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
-- hover highlight writes the same parameter, so persistent tints are re-applied
-- per tick by the caller.
function engine.writeColor(e, color)
    for _, mid in ipairs(e.mids) do
        pcall(function() mid:SetVectorParameterValue(FName("HighlightColor"), color) end)
    end
end

-- read / write the lock scene's piece-move interpolation speed, a reflected float
-- on GothicLockSceneActor (baseline 20, m_UseConstantInterpolationSpeed = true).
-- Cranking it collapses the move glide to a near-instant SNAP (the fast auto-solve
-- lever; probe-confirmed the written value sticks, the game does not re-assert it).
-- Per-minigame scene actor, so it never leaks across locks; fast mode restores the
-- original on stop. getSceneInterp returns the number or nil; setSceneInterp
-- returns ok.
function engine.getSceneInterp(scene)
    local v
    local ok = pcall(function() v = scene.m_LockPieceInterpolationSpeed end)
    if ok then return v end
    return nil
end

function engine.setSceneInterp(scene, value)
    return (pcall(function() scene.m_LockPieceInterpolationSpeed = value end))
end

-- read the current HighlightColor off a single MID, or nil. Used to observe the
-- game's selected-glow signature and to tell our own paint apart from it.
function engine.readHighlight(mid)
    local c
    local ok = pcall(function() c = mid:K2_GetVectorParameterValue(FName("HighlightColor")) end)
    if ok and c then return c end
    return nil
end

-- The ONLY write that DRIVES the minigame: call one of the lockpick task's input
-- UFunctions to move the selection (up/down) or turn the selected piece
-- (left/right). Same functions the game's own input dispatch fires. An early
-- LockProbe build moved the lock from a Lua call, but LuaModdingSurface.md
-- records the behaviour as INPUT-STATE DEPENDENT: it moved pieces in one session
-- and was inert in another, unresolved. The caller must therefore confirm each
-- press from the measured state, never assume it landed. Every call is liveness
-- checked on the LIVE task per call (never on a stale cache) and pcall-wrapped:
-- pcall does not catch a native access violation, so the IsValid gate is the real
-- guard. Returns true if the call dispatched (NOT that a piece moved), false
-- otherwise. which is one of "up"/"down"/"left"/"right".
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

return engine
