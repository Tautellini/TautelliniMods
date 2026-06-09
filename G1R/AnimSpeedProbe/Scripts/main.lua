-- AnimSpeedProbe: dev-only investigation mod, NOT for shipping.
--
-- Fast-auto-solve linchpin (plans/fast-auto-solve.md, open question 1): can the
-- lock-piece move ANIMATION be collapsed by writing the scene actor's
-- interpolation speed, and does the game keep the written value or re-assert it?
-- The whole "super fast" mode rides on this, so eyeball it before building it.
--
-- GothicLockSceneActor exposes m_LockPieceInterpolationSpeed (FloatProperty,
-- reflected, writable), m_UseConstantInterpolationSpeed (bool),
-- m_LockPieceTranslationStep, m_ShakeSpeed, m_ShakeDuration. The session already
-- READS m_LockPieceTranslationStep, so reading/writing these floats on the live
-- scene actor is the safe reflected path (NOT the chest-class / part-actor crash
-- territory). Read-only except the deliberate speed writes on the hotkeys.
--
-- Usage: deploy, open a lock. The start values are logged. Then A/B by hand:
--   move a piece (normal speed) ->  F10 crank  ->  move a piece (should SNAP)
--   ->  F11 restore  ->  move a piece (normal again).  F12 logs the current value
--   (press it AFTER a few moves to see whether the game re-asserted it).
-- Send the log plus what you SAW (did the glide collapse on F10?).

local pcall, tostring, ipairs, string, type = pcall, tostring, ipairs, string, type
local FindAllOf = FindAllOf

local CRANK = 1000.0   -- a deliberately huge interpolation speed
local origSpeed = nil  -- captured at minigame start, for F11 restore

local function log(msg) print("[AnimSpeedProbe] " .. tostring(msg) .. "\n") end

local function findScene()
    local ok, subs = pcall(FindAllOf, "LockPickSubsystem")
    if ok and subs then
        for _, sub in ipairs(subs) do
            local scene
            pcall(function()
                local sc = sub.m_LockSceneActor
                if sc and sc:IsValid() then scene = sc end
            end)
            if scene then return scene end
        end
    end
    return nil
end

local function readField(scene, name)
    local v
    local ok = pcall(function() v = scene[name] end)
    if ok then return v end
    return "ERR"
end

local function dumpFields(tag)
    local scene = findScene()
    if not scene then log(tag .. ": no live lock scene") return nil end
    local fields = {
        "m_LockPieceInterpolationSpeed", "m_UseConstantInterpolationSpeed",
        "m_LockPieceTranslationStep", "m_ShakeSpeed", "m_ShakeDuration",
        "m_BarDistanceThresholdForInterpolation",
    }
    for _, f in ipairs(fields) do
        log(string.format("%s %s = %s", tag, f, tostring(readField(scene, f))))
    end
    return scene
end

local function setSpeed(value, tag)
    local scene = findScene()
    if not scene then log(tag .. ": no live lock scene") return end
    local before = readField(scene, "m_LockPieceInterpolationSpeed")
    local ok = pcall(function() scene.m_LockPieceInterpolationSpeed = value end)
    local after = readField(scene, "m_LockPieceInterpolationSpeed")
    log(string.format("%s write %s: ok=%s, %s -> %s (read back)",
        tag, tostring(value), tostring(ok), tostring(before), tostring(after)))
end

-- minigame start: log the as-shipped values and remember the original speed
pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick", function()
    ExecuteWithDelay(1200, function()
        ExecuteInGameThread(function()
            local scene = dumpFields("START")
            if scene then
                origSpeed = readField(scene, "m_LockPieceInterpolationSpeed")
            end
        end)
    end)
end)

pcall(function()
    RegisterKeyBind(Key.F10, function()
        ExecuteInGameThread(function() setSpeed(CRANK, "F10 CRANK") end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F11, function()
        ExecuteInGameThread(function()
            if type(origSpeed) == "number" then setSpeed(origSpeed, "F11 RESTORE")
            else log("F11: no original speed captured yet") end
        end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F12, function()
        ExecuteInGameThread(function() dumpFields("F12 NOW") end)
    end)
end)

-- world-change backstop (a stale wrapper after a GC purge is a native AV pcall
-- cannot catch): nothing to tear down here, but mirror the house rule.
pcall(RegisterInitGameStatePostHook, function() origSpeed = nil end)

log("loaded: open a lock; START values logged. F10 cranks the interpolation "
    .. "speed, F11 restores, F12 reads it now. Move a piece before/after F10 to "
    .. "see if the glide collapses; send the log and what you saw.")
