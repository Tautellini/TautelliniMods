-- probes/tickfind.lua  --  dev-only: find a per-frame GAME-THREAD tick for the
-- deferred-queue-free auto-solve driver (see UE4SS-Lua-Best-Practices.md,
-- principle SINGLE-DRIVER; the fix for the F6/F7 abort, RE-UE4SS issue #1180).
--
-- The crash fix is to drive periodic work from ONE long-lived game-thread loop
-- instead of LoopAsync + per-tick/per-keypress ExecuteInGameThread. Two ways to
-- get a game-thread tick, and this probe checks for BOTH:
--   (1) the Delayed Action System: if this build exposes LoopInGameThreadWithDelay
--       and friends, the driver needs no hook at all. The probe logs which of
--       those globals exist (inert _G reads, done at load and in every report).
--   (2) RegisterHook on a UFunction the ENGINE dispatches every frame: the hook
--       then runs on the game thread inside ProcessEvent, with one persistent ref
--       and no deferral. The probe hooks a few candidates and counts their fire
--       RATE so the dev can pick the one that fires once per frame (Hz close to
--       the framerate).
--
-- READ-ONLY and INERT: the hook callbacks only bump an integer while a measurement
-- window is open, and never deref the hook args, FindAllOf, or write anything. Only
-- engine-native /Script/Engine UFunctions are hooked, the seam our own rule says is
-- safe (hook where the caller is the engine, never AngelScript-internal calls).
--
-- Usage: load a save, be in normal gameplay, press NUM_ZERO to START a window, play
-- for a few seconds, press NUM_ZERO again to STOP and print each candidate's fires
-- and approximate Hz. Read the log: the driver tick is the SINGLE-FIRE candidate
-- whose Hz is closest to your framerate (PlayerTick or ReceiveDrawHUD). Actor:
-- ReceiveTick fires once PER TICKING ACTOR (very high Hz) so it is shown only to
-- confirm game-thread dispatch; it would need de-dup to one call per frame. A
-- candidate stuck at 0 either did not arm (see the "hook NOT armed" line at load)
-- or is not engine-dispatched on this build.

local pcall, tostring, type, ipairs = pcall, tostring, type, ipairs
local string, os, table, rawget = string, os, table, rawget

return function(ctx)
    local log = ctx.makeLog("tickfind")

    -- candidate per-frame, engine-dispatched UFunctions (run on the game thread)
    local CANDIDATES = {
        { path = "/Script/Engine.PlayerController:PlayerTick",
          tag = "PlayerController:PlayerTick", note = "single-fire, ideal driver" },
        { path = "/Script/Engine.HUD:ReceiveDrawHUD",
          tag = "HUD:ReceiveDrawHUD", note = "single-fire, ideal driver" },
        { path = "/Script/Engine.Actor:ReceiveTick",
          tag = "Actor:ReceiveTick", note = "per ticking actor, high Hz, needs de-dup" },
    }

    -- the Delayed Action System globals: if present, the driver can use a game-thread
    -- loop API directly and skip the hook entirely
    local DELAYED_API = {
        "LoopInGameThreadWithDelay", "ExecuteInGameThreadWithDelay",
        "RetriggerableExecuteInGameThreadWithDelay", "CancelDelayedAction",
        "LoopInGameThreadAfterFrames", "ExecuteInGameThreadAfterFrames",
    }

    local function reportApi()
        local have = {}
        for _, n in ipairs(DELAYED_API) do
            if type(rawget(_G, n)) == "function" then have[#have + 1] = n end
        end
        if #have > 0 then
            log("Delayed Action System present: " .. table.concat(have, ", ")
                .. "  -> driver can use a game-thread loop API, no hook needed")
        else
            log("Delayed Action System: NONE -> use the RegisterHook tick below as the driver")
        end
    end

    local count = {}
    for _, c in ipairs(CANDIDATES) do count[c.path] = 0 end
    local measuring, t0 = false, 0

    local function bump(path) if measuring then count[path] = count[path] + 1 end end

    local function toggle()
        if not measuring then
            for _, c in ipairs(CANDIDATES) do count[c.path] = 0 end
            t0 = os.clock()
            measuring = true
            log("measuring STARTED; play normally for a few seconds, then press NUM_ZERO again")
        else
            measuring = false
            local dt = os.clock() - t0
            if dt <= 0 then dt = 0.0001 end
            log(string.format("measuring STOPPED after %.2fs:", dt))
            for _, c in ipairs(CANDIDATES) do
                local n = count[c.path]
                log(string.format("  %-32s %7d fires  %8.1f Hz  [%s]",
                    c.tag, n, n / dt, c.note))
            end
            log("  driver tick = the single-fire candidate whose Hz is nearest your FPS")
            log("  (0 fires = hook did not arm, see load lines, or not engine-dispatched)")
            reportApi()
        end
    end

    local hooks = {}
    for _, c in ipairs(CANDIDATES) do
        local path = c.path
        hooks[#hooks + 1] = { path = path, tag = c.tag, cb = function() bump(path) end }
    end

    return {
        name = "tickfind",
        hooks = hooks,
        keys = {
            { key = "NUM_ZERO", desc = "toggle a per-frame-tick measurement window", fn = toggle },
        },
        -- log the Delayed Action System availability once at load (inert), so the dev
        -- sees it even before running a measurement
        autorun = reportApi,
    }
end
