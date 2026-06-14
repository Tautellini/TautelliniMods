-- probes/sleep.lua  --  find the EXACT thing a real sleep does, and test SkipTime.
-- See G1R/SleepAnywhere/plans/sleep-anywhere.md.
--
-- Status: AdvanceToClockTime / SetCurrentClockTime move the clock but do NOT move NPCs.
-- SkipTime SIMULATES elapsed time (may fire the per-hour events NPC routines listen to)
-- instead of teleporting the clock.
--   SkipTime(Duration: InGameTime{ TotalSeconds:double })  -- so just pass seconds.
--
-- The sleep confirm handler is Server_OnSleepUIConfirmButtonClicked(selectedHoursToSleep:
-- float) on the ability instance; we cannot call it from a field (no instance), but the
-- HOOKS log what it calls internally the moment you do a REAL bed sleep. That is still the
-- missing measurement.
--
-- KEYS (REMAPPED from the standalone SleepProbe's F5-F9, which clash with reserved keys):
--   F10            = SkipTime forward to the target hour  (THE test; watch NPCs).  [was F9]
--   Shift+F10      = read the current clock.                                       [was F5]
--   Ctrl+F10       = try to activate GameplayAbilitySleep here (likely bed-gated). [was F8]
--   NUM_DIVIDE     = raw AdvanceToClockTime(target)   (known: clock only).         [was F6]
--   NUM_MULTIPLY   = raw SetCurrentClockTime(target).                              [was Shift+F6]
--   NUM_MINUS      = cycle target hour (8/13/19/22).                               [was F7]
-- HOOKS capture a real bed sleep: [sleep]/[time] always, [routine] inside a trace window.
-- RESTART the game (hooks). PLEASE do ONE real bed sleep among NPCs.

local pcall, ipairs, tostring, type, string, os = pcall, ipairs, tostring, type, string, os

return function(ctx)
    local log = ctx.makeLog("sleep")
    local isValid, firstLive, onGameThread = ctx.isValid, ctx.firstLive, ctx.onGameThread
    local StaticFindObject = ctx.StaticFindObject

    local SUBSYS = "GameTimeSubsystem"
    local PLAYER = "GothicPlayerCharacter"
    local SLEEP_CLASS = "/Script/G1R.GameplayAbilitySleep"
    local GAS_LIB_CDO = "/Script/G1R.Default__GothicGASLibrary"
    local TARGETS = { 8, 13, 19, 22 }
    local targetIdx = 1

    local traceUntil, traceCount = 0, 0
    local TRACE_SECONDS, TRACE_MAX = 6.0, 60

    local function openTrace(why) traceUntil = os.clock() + TRACE_SECONDS; traceCount = 0; log("=== TRACE WINDOW OPEN (" .. why .. ") ===") end
    local function inTrace() return os.clock() < traceUntil and traceCount < TRACE_MAX end

    local function readClockHM(subsys)
        local ct; if not pcall(function() ct = subsys:GetCurrentClockTime() end) or ct == nil then return nil end
        local h, m; pcall(function() h = ct.Hour end); pcall(function() m = ct.Minute end)
        if h == nil then return nil end
        return h, (m or 0)
    end
    local function clockStr(subsys)
        local h, m = readClockHM(subsys); if h == nil then return "<unreadable>" end
        return tostring(h) .. ":" .. string.format("%02d", m)
    end

    local function dumpClock()
        local subsys = firstLive(SUBSYS)
        if not subsys then log("no GameTimeSubsystem (be IN-GAME)"); return end
        log("current clock = " .. clockStr(subsys))
    end

    -- THE TEST: skip elapsed time forward to the target hour.
    local function testSkip()
        local subsys = firstLive(SUBSYS); if not subsys then log("no GameTimeSubsystem"); return end
        local target = TARGETS[targetIdx]
        local h, m = readClockHM(subsys); h = h or 0; m = m or 0
        local cur = h + m / 60
        local delta = (target - cur) % 24; if delta < 0.001 then delta = 24 end   -- always forward
        local seconds = delta * 3600
        openTrace("SkipTime forward")
        local before = clockStr(subsys)
        local ok = pcall(function() subsys:SkipTime({ TotalSeconds = seconds }) end)
        log("[SkipTime] SkipTime(+" .. string.format("%.2f", delta) .. "h) ok=" .. tostring(ok)
            .. " before=" .. before .. " after=" .. clockStr(subsys) .. "  | WATCH the NPCs")
    end

    local function testAdvance()
        local subsys = firstLive(SUBSYS); if not subsys then log("no GameTimeSubsystem"); return end
        local target = TARGETS[targetIdx]; openTrace("raw AdvanceToClockTime")
        local before = clockStr(subsys)
        local ok = pcall(function() subsys:AdvanceToClockTime({ Hour = target, Minute = 0, Second = 0.0 }) end)
        log("[Advance] AdvanceToClockTime(Hour=" .. target .. ") ok=" .. tostring(ok) .. " before=" .. before .. " after=" .. clockStr(subsys))
    end

    local function testSet()
        local subsys = firstLive(SUBSYS); if not subsys then log("no GameTimeSubsystem"); return end
        local target = TARGETS[targetIdx]; openTrace("raw SetCurrentClockTime")
        local before = clockStr(subsys)
        local ok = pcall(function() subsys:SetCurrentClockTime(target, 0, 0.0) end)
        log("[Set] SetCurrentClockTime(" .. target .. ",0,0) ok=" .. tostring(ok) .. " before=" .. before .. " after=" .. clockStr(subsys))
    end

    local function cycleTarget()
        targetIdx = targetIdx + 1; if targetIdx > #TARGETS then targetIdx = 1 end
        log("target hour is now " .. TARGETS[targetIdx] .. ":00")
    end

    local function getPlayerASC(player)
        -- ASC lives on the PlayerState in this GAS setup (the character returned null).
        local ps; pcall(function() ps = player:GetPlayerState() end)
        if ps ~= nil and isValid(ps) then
            local asc; pcall(function() asc = ps:GetAbilitySystemComponent() end)
            if asc ~= nil and isValid(asc) then return asc, "playerstate" end
        end
        local asc; pcall(function() asc = player:GetAbilitySystemComponent() end)
        if asc ~= nil and isValid(asc) then return asc, "character" end
        if StaticFindObject then
            local lib; pcall(function() lib = StaticFindObject(GAS_LIB_CDO) end)
            if lib ~= nil then
                local a2; pcall(function() a2 = lib:GetAbilitySystemComponent(player) end)
                if a2 ~= nil and isValid(a2) then return a2, "GothicGASLibrary" end
                if ps ~= nil then
                    local a3; pcall(function() a3 = lib:GetAbilitySystemComponent(ps) end)
                    if a3 ~= nil and isValid(a3) then return a3, "GothicGASLibrary(ps)" end
                end
            end
        end
        return nil, "none"
    end

    local function tryOpenSleep()
        local player = firstLive(PLAYER); if not player then log("[Sleep] no GothicPlayerCharacter"); return end
        local asc, how = getPlayerASC(player)
        if not asc then log("[Sleep] could not get ASC (tried direct + GothicGASLibrary)"); return end
        local cls; if StaticFindObject then pcall(function() cls = StaticFindObject(SLEEP_CLASS) end) end
        if cls == nil then log("[Sleep] could not resolve " .. SLEEP_CLASS); return end
        openTrace("activate GameplayAbilitySleep")
        local ok, ret = pcall(function() return asc:TryActivateAbilityByClass(cls) end)
        log("[Sleep] ASC via " .. how .. "; TryActivateAbilityByClass ok=" .. tostring(ok) .. " returned=" .. tostring(ret)
            .. "  | did the clock UI appear?")
    end

    -- hook callbacks (armed centrally via spec.hooks)
    local function always(tag) return function() log(tag) end end
    local function sleepConfirm()
        log("=== REAL SLEEP CONFIRM (OnSleepUIConfirmButtonClicked) ==="); openTrace("real bed sleep")
    end
    local function traced(tag) return function() if inTrace() then traceCount = traceCount + 1; log("[routine] " .. tag) end end end

    return {
        name = "sleep",
        hooks = {
            { path = "/Script/G1R.GameplayAbilitySleep:OnSleepUIConfirmButtonClicked", tag = "SleepConfirm", cb = sleepConfirm },
            { path = "/Script/G1R.GameplayAbilitySleep:OnActivateAbility_Scriptable", tag = "[sleep] ability OnActivate", cb = always("[sleep] ability OnActivate") },
            { path = "/Script/G1R.GameTimeSubsystem:AdvanceToClockTime", tag = "[time] AdvanceToClockTime", cb = always("[time] AdvanceToClockTime") },
            { path = "/Script/G1R.GameTimeSubsystem:SetCurrentClockTime", tag = "[time] SetCurrentClockTime", cb = always("[time] SetCurrentClockTime") },
            { path = "/Script/G1R.GameTimeSubsystem:SkipTime", tag = "[time] SkipTime", cb = always("[time] SkipTime") },
            { path = "/Script/G1R.GothicNPCState:SimulateDailyRoutineIfNeeded", tag = "GothicNPCState:SimulateDailyRoutineIfNeeded", cb = traced("GothicNPCState:SimulateDailyRoutineIfNeeded") },
            { path = "/Script/G1R.GothicNPCState:TeleportAndExchangeDailyRoutineToClass", tag = "GothicNPCState:TeleportAndExchangeDailyRoutineToClass", cb = traced("GothicNPCState:TeleportAndExchangeDailyRoutineToClass") },
            { path = "/Script/G1R.AIState_DailyRoutine:RequestDailyRoutineScheduleUpdate", tag = "AIState_DailyRoutine:RequestDailyRoutineScheduleUpdate", cb = traced("AIState_DailyRoutine:RequestDailyRoutineScheduleUpdate") },
            { path = "/Script/G1R.GameplayAbility_CharacterAI:SwitchToDailyRoutine", tag = "CharacterAI:SwitchToDailyRoutine", cb = traced("CharacterAI:SwitchToDailyRoutine") },
            { path = "/Script/G1R.GameplayAbility_CharacterAI:StartScheduledNextState", tag = "CharacterAI:StartScheduledNextState", cb = traced("CharacterAI:StartScheduledNextState") },
        },
        keys = {
            { key = "F10", desc = "SkipTime forward to target hour (watch NPCs)", fn = function() onGameThread(testSkip) end },
            { key = "F10", mod = "SHIFT", desc = "read the current clock", fn = function() onGameThread(dumpClock) end },
            { key = "F10", mod = "CONTROL", desc = "try activate GameplayAbilitySleep here", fn = function() onGameThread(tryOpenSleep) end },
            { key = "NUM_DIVIDE", desc = "raw AdvanceToClockTime(target)", fn = function() onGameThread(testAdvance) end },
            { key = "NUM_MULTIPLY", desc = "raw SetCurrentClockTime(target)", fn = function() onGameThread(testSet) end },
            { key = "NUM_MINUS", desc = "cycle target hour (8/13/19/22)", fn = cycleTarget },
        },
    }
end
