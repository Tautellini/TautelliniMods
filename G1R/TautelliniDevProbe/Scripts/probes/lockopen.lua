-- probes/lockopen.lua  --  dev-only: find a ONE-SHOT way to put a lock in its final opened state,
-- so the minigame can be skipped WITHOUT removing it and WITHOUT a per-tick press loop. The press
-- loop is what feeds the #1180 deferred-queue crash; a single call has the risk profile of one
-- F6 toggle. The unlock must still COUNT (achievement Memory_Crime_Lockpick + crime registration),
-- so the target is the game's own success path.
--
-- WHAT CHANGED (2026-06-19): the first version ENUMERATED the task's UFunctions live via
-- cls:ForEachFunction. That NATIVE-CRASHED (AV mid-iteration; pcall/try cannot catch it). Walking
-- or enumerating a live UClass function list is a banned op on this build (see LuaModdingSurface.md).
-- So we no longer enumerate. We READ a safe summary and TEST the KNOWN-callable functions one at a
-- time behind explicit keys. Calling a known UFunction BY NAME is the proven-safe pattern:
-- LockpickSettings presses task:UpPressed() this way, and the game itself calls TryOpenLock /
-- MemorizeLockpick, which LockpickSettings already hooks without crashing.
--
-- Known surface (offline, from G1R/reference/g1r-class-props.txt):
--   AbilityTask_LockPick success delegates: OnSuccessLockPick, OnFailedLockPick, OnSetLockUnlocked.
--   AbilityTask_LockPick callable (confirmed via LockpickSettings hooks/presses): UpPressed,
--   DownPressed, LeftPressed, RightPressed, BackPressed, TryOpenLock, MemorizeLockpick.
--
-- DANGER: the call tests invoke gameplay functions on the live task. Use a THROWAWAY save, and
-- watch whether the lock OPENS and whether the crime/achievement counts.
--
-- ACTIONS (bind a key to each in config.probes.lockopen.keys; be in a live minigame, chest or door):
--   read     = safe READ: live task, owning ability, lock name (no enumeration)
--   tryOpen  = CALL task:TryOpenLock() once       (the game's confirm/open path)
--   memorize = CALL task:MemorizeLockpick() once  (the success/record path)

local tostring = tostring

return function(ctx)
    local log = ctx.makeLog("lockopen")
    local isValid, try = ctx.isValid, ctx.try
    local fullName, classPath = ctx.fullName, ctx.classPath
    local firstLive, firstPlayer = ctx.firstLive, ctx.firstPlayer

    -- freshest live task, cached by the spawn notify (an ability is reused; the task is per-game)
    local freshTask = nil
    local function liveTask()
        if freshTask and isValid(freshTask) then return freshTask end
        local t = firstLive("AbilityTask_LockPick")
        return isValid(t) and t or nil
    end

    local function readSummary()
        log("########## lockopen READ (be in a live minigame) ##########")
        local task = liveTask()
        if isValid(task) then
            log("task = " .. fullName(task) .. "  [" .. classPath(task) .. "]")
        else
            log("no live AbilityTask_LockPick (open a lock first)")
        end
        local ab = firstPlayer("GameplayAbilityOpen") or firstPlayer("GameplayAbilityDoor")
        if isValid(ab) then
            log("ability = " .. fullName(ab) .. "  [" .. classPath(ab) .. "]")
            log("  m_Lock = " .. tostring(try(function() return ab.m_Lock:ToString() end)))
        else
            log("no player GameplayAbilityOpen/Door instance")
        end
        log("########## READ done. ##########")
    end

    -- call ONE known UFunction on the live task, isolated, with ABOUT-TO forensics so the log
    -- pinpoints a crash. pcall catches a Lua error; a native AV is still uncatchable, but the
    -- ABOUT-TO line is then the last log line, which is the signal.
    local function callOnTask(funcName)
        return function()
            local task = liveTask()
            if not isValid(task) then log(funcName .. ": no live task (open a lock first)"); return end
            log("[call] ABOUT TO: task:" .. funcName .. "()  on " .. fullName(task))
            local ok, err = pcall(function() task[funcName](task) end)
            log("[call] task:" .. funcName .. "() done (dispatched=" .. tostring(ok)
                .. (ok and "" or ", err=" .. tostring(err))
                .. "). Watch the lock: did it OPEN, and did the crime/achievement count?")
        end
    end

    -- hotkeys come from config.probes.lockopen.keys (by action id); none are hardcoded here
    return {
        name = "lockopen",
        actions = {
            { id = "read", desc = "READ live task + owning ability + lock name (safe, no enumerate)",
              fn = readSummary },
            { id = "tryOpen", desc = "CALL task:TryOpenLock() once (DANGER, throwaway save)",
              fn = callOnTask("TryOpenLock") },
            { id = "memorize", desc = "CALL task:MemorizeLockpick() once (DANGER, throwaway save)",
              fn = callOnTask("MemorizeLockpick") },
        },
        notifies = {
            { path = "/Script/G1R.AbilityTask_LockPick",
              cb = function(task) if isValid(task) then freshTask = task end end },
        },
    }
end
