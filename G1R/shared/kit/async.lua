-- async.lua  --  game-thread scheduling with a fast path and a fallback.
--
-- WHY: nesting ExecuteInGameThread inside LoopAsync / ExecuteWithDelay enqueues a
-- deferred action from inside the deferred-queue drain. That reentrancy is RE-UE4SS
-- issue #1180. On old builds it aborts the game. On 988+ UE4SS catches it
-- ("[Lua::Registry::get_function_ref] Ref was not function ... removing hook!") and
-- drops the shared Lua engine-tick hook, after which EVERY mod's loops and timers go
-- silent. The Delayed Action System (RE-UE4SS PR #1128) runs the body ON the game
-- thread with no nesting, so this module prefers it and only falls back to the nested
-- pattern when those globals are absent (older UE4SS).
--
-- The mod's main.lua owns whether to use this; it is just a helper, the registration
-- still happens from main.lua's tail.

local rawget, type, pcall = rawget, type, pcall

local LoopInGameThreadWithDelay    = rawget(_G, "LoopInGameThreadWithDelay")
local ExecuteInGameThreadWithDelay = rawget(_G, "ExecuteInGameThreadWithDelay")
local CancelDelayedAction          = rawget(_G, "CancelDelayedAction")
local LoopAsync                    = rawget(_G, "LoopAsync")
local ExecuteWithDelay             = rawget(_G, "ExecuteWithDelay")
local ExecuteInGameThread          = rawget(_G, "ExecuteInGameThread")

local async = {}

-- true when this build has the game-thread Delayed Action System (the no-nesting path)
async.hasGameThreadTimers = type(LoopInGameThreadWithDelay) == "function"
    and type(ExecuteInGameThreadWithDelay) == "function"

-- gameLoop(ms, decide) -- call decide() about every ms until it stops the loop.
--
-- decide() returns one of:
--   true       -> stop the loop
--   a function -> run that work this cycle on the game thread
--   nil/false  -> nothing to do this cycle
--
-- One body shape covers both paths. On the fast path decide() runs on the game thread,
-- so it may read game state directly and the returned work runs inline. On the fallback
-- decide() runs on the async thread (keep it a cheap decision) and the returned work is
-- marshalled to the game thread, only when there is work, so the deferred queue stays
-- quiet. Returns a canceller (idempotent).
function async.gameLoop(ms, decide)
    if type(decide) ~= "function" then return function() end end

    if type(LoopInGameThreadWithDelay) == "function" then
        local handle, stopped = nil, false
        local function stop()
            stopped = true
            if type(CancelDelayedAction) == "function" and handle ~= nil then
                pcall(CancelDelayedAction, handle)
            end
        end
        handle = LoopInGameThreadWithDelay(ms, function()
            if stopped then return end
            local ok, work = pcall(decide)
            if not ok or work == true then stop(); return end
            if type(work) == "function" then pcall(work) end
        end)
        return stop
    end

    if type(LoopAsync) == "function" then
        local stopped, ticking = false, false
        LoopAsync(ms, function()
            if stopped then return true end
            local ok, work = pcall(decide)
            if not ok or work == true then stopped = true; return true end
            if type(work) == "function" then
                if ticking then return false end -- previous game-thread pass still in flight
                ticking = true
                if type(ExecuteInGameThread) == "function" then
                    ExecuteInGameThread(function() pcall(work); ticking = false end)
                else
                    pcall(work); ticking = false
                end
            end
            return false
        end)
        return function() stopped = true end
    end

    return function() end -- no scheduler on this build
end

-- gameDelay(ms, fn) -- run fn once on the game thread after about ms. pcall-guarded.
function async.gameDelay(ms, fn)
    if type(fn) ~= "function" then return end

    if type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(ms, function() pcall(fn) end)
    elseif type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(ms, function()
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(function() pcall(fn) end)
            else
                pcall(fn)
            end
        end)
    end
end

return async
