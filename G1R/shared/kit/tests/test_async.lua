-- tests for kit.async (game-thread scheduling: Delayed Action System fast path,
-- LoopAsync + ExecuteInGameThread fallback). async.lua captures the UE4SS globals at
-- load time, so each path is exercised by setting fakes then loadfile-ing a fresh copy.
package.path = "./?.lua;" .. package.path

local T = require("tinytest")

local GLOBALS = {
    "LoopInGameThreadWithDelay", "ExecuteInGameThreadWithDelay", "CancelDelayedAction",
    "LoopAsync", "ExecuteWithDelay", "ExecuteInGameThread",
}
local function clearGlobals()
    for _, n in ipairs(GLOBALS) do _G[n] = nil end
end
local function freshAsync() return assert(loadfile("../async.lua"))() end

-- fast path: only the Delayed Action System globals exist
local function fastFakes()
    clearGlobals()
    local calls = { loops = {}, delays = {}, cancels = {} }
    _G.LoopInGameThreadWithDelay = function(ms, cb)
        local h = { ms = ms, cb = cb }
        calls.loops[#calls.loops + 1] = h
        return h
    end
    _G.ExecuteInGameThreadWithDelay = function(ms, cb)
        calls.delays[#calls.delays + 1] = { ms = ms, cb = cb }
    end
    _G.CancelDelayedAction = function(h) calls.cancels[#calls.cancels + 1] = h end
    return calls
end

-- fallback: only the legacy async globals exist
local function slowFakes()
    clearGlobals()
    local calls = { loops = {}, delays = {}, eigt = {} }
    _G.LoopAsync = function(ms, cb) calls.loops[#calls.loops + 1] = { ms = ms, cb = cb } end
    _G.ExecuteWithDelay = function(ms, cb) calls.delays[#calls.delays + 1] = { ms = ms, cb = cb } end
    _G.ExecuteInGameThread = function(cb) calls.eigt[#calls.eigt + 1] = cb end
    return calls
end

-- ------------------------------------------------------------- fast path --

T.add("fast: hasGameThreadTimers is true", function()
    fastFakes()
    T.ok(freshAsync().hasGameThreadTimers == true, "detects the Delayed Action System")
end)

T.add("fast: gameLoop runs the work on the game thread with NO nesting", function()
    local calls = fastFakes()
    local async = freshAsync()
    local ran = 0
    async.gameLoop(50, function() return function() ran = ran + 1 end end)
    T.eq(#calls.loops, 1)
    T.eq(calls.loops[1].ms, 50)
    calls.loops[1].cb() -- one game-thread tick; work runs inline, no ExecuteInGameThread to call
    T.eq(ran, 1)
end)

T.add("fast: gameLoop does nothing on a not-due wake", function()
    local calls = fastFakes()
    local async = freshAsync()
    local ran = 0
    async.gameLoop(50, function() return nil end)
    calls.loops[1].cb()
    T.eq(ran, 0)
end)

T.add("fast: decide returning true cancels the loop via the handle", function()
    local calls = fastFakes()
    local async = freshAsync()
    async.gameLoop(50, function() return true end)
    calls.loops[1].cb()
    T.eq(#calls.cancels, 1)
    T.ok(calls.cancels[1] == calls.loops[1], "cancelled the handle we were given")
end)

T.add("fast: the returned canceller cancels the loop", function()
    local calls = fastFakes()
    local async = freshAsync()
    local stop = async.gameLoop(50, function() return function() end end)
    stop()
    T.eq(#calls.cancels, 1)
end)

T.add("fast: gameDelay uses ExecuteInGameThreadWithDelay (no nesting)", function()
    local calls = fastFakes()
    local async = freshAsync()
    local ran = 0
    async.gameDelay(120, function() ran = ran + 1 end)
    T.eq(#calls.delays, 1)
    T.eq(calls.delays[1].ms, 120)
    calls.delays[1].cb()
    T.eq(ran, 1)
end)

-- -------------------------------------------------------------- fallback --

T.add("fallback: hasGameThreadTimers is false", function()
    slowFakes()
    T.ok(freshAsync().hasGameThreadTimers == false, "no Delayed Action System")
end)

T.add("fallback: gameLoop marshals the work via ExecuteInGameThread when due", function()
    local calls = slowFakes()
    local async = freshAsync()
    local ran = 0
    async.gameLoop(25, function() return function() ran = ran + 1 end end)
    T.eq(#calls.loops, 1)
    T.eq(calls.loops[1].ms, 25)
    local keep = calls.loops[1].cb() -- async-thread wake: decides due, marshals
    T.eq(keep, false) -- keep looping
    T.eq(ran, 0) -- not run until the game-thread pass executes
    T.eq(#calls.eigt, 1)
    calls.eigt[1]() -- the marshalled game-thread pass
    T.eq(ran, 1)
end)

T.add("fallback: a not-due wake marshals nothing", function()
    local calls = slowFakes()
    local async = freshAsync()
    async.gameLoop(25, function() return nil end)
    calls.loops[1].cb()
    T.eq(#calls.eigt, 0)
end)

T.add("fallback: decide returning true stops the LoopAsync (returns true)", function()
    local calls = slowFakes()
    local async = freshAsync()
    async.gameLoop(25, function() return true end)
    T.eq(calls.loops[1].cb(), true)
end)

T.add("fallback: a second wake is skipped while a pass is in flight", function()
    local calls = slowFakes()
    local async = freshAsync()
    async.gameLoop(25, function() return function() end end)
    local cb = calls.loops[1].cb
    cb() -- marshals pass #1 (not yet executed)
    cb() -- pass #1 still in flight -> must NOT marshal a second
    T.eq(#calls.eigt, 1)
    calls.eigt[1]() -- pass #1 completes, clears the in-flight guard
    cb() -- now a fresh marshal is allowed
    T.eq(#calls.eigt, 2)
end)

T.add("fallback: gameDelay nests ExecuteInGameThread inside ExecuteWithDelay", function()
    local calls = slowFakes()
    local async = freshAsync()
    local ran = 0
    async.gameDelay(200, function() ran = ran + 1 end)
    T.eq(#calls.delays, 1)
    T.eq(calls.delays[1].ms, 200)
    calls.delays[1].cb() -- the delayed async callback marshals to the game thread
    T.eq(#calls.eigt, 1)
    calls.eigt[1]()
    T.eq(ran, 1)
end)

-- ------------------------------------------------------- no scheduler --

T.add("no scheduler: gameLoop returns a no-op canceller and does not throw", function()
    clearGlobals()
    local async = freshAsync()
    local stop = async.gameLoop(25, function() return function() end end)
    T.ok(type(stop) == "function", "still returns a canceller")
    stop()
end)

os.exit(T.run())
