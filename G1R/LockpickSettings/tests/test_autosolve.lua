-- test_autosolve.lua  --  Auto-Solve driver decision logic (engine mocked).
--
-- The driver is engine-facing but names no UE4SS global: it reads a live-session
-- table and presses through an injected engine. Here both are fakes. The fake
-- engine APPLIES presses like the game (up/down move the clamped selection,
-- left/right turn the selected piece), so the tick-driven state machine can be
-- run to completion and asserted on. These pin the review fixes: the press
-- direction is the exact inverse of the hint color mapping, an uncalibrated nudge
-- that resolves either way is not a deviation, and a lock with no observable
-- selection aborts honestly instead of mis-targeting.
local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local Driver = require("autosolve.driver")
local hint = require("nextmove.hint")

local function silent() end

-- Build a fake live session plus a fake engine. gameMap is the world's true
-- press-to-step sign; it defaults to the believed mapping (a consistent world),
-- override it to model a lock whose real direction disagrees with the belief.
local function makeWorld(opts)
    local presses = {}
    local s = {
        pieceCount = opts.pieceCount,
        rotStart = opts.rotStart,
        steps = {},
        sign = opts.sign or 1,
        inputToAxis = opts.inputToAxis,
        screenRight = opts.screenRight,
        selectedRow = opts.selectedRow or 0,
        selectedSig = opts.selectedSig,
        stateUnknown = false,
        hintGeometry = true,
        stop = false,
        flags = {},
        scene = {}, -- fast mode reads/writes the scene interpolation speed
    }
    for id = 0, s.pieceCount - 1 do s.steps[id] = 0 end
    local function rot(id) return s.rotStart[id] + s.sign * (s.steps[id] or 0) end
    s.solver = {
        moveValid = function(_, st, x, d)
            local r = st.rotStart[x] + st.sign * (st.steps[x] or 0) + d
            return r >= -3 and r <= 3
        end,
        -- greedy single-piece descent: target the first off-center piece
        plan = opts.plan or function(_, st)
            for id = 0, st.pieceCount - 1 do
                local r = st.rotStart[id] + st.sign * (st.steps[id] or 0)
                if r ~= 0 then return { piece = id, dir = (r > 0) and -1 or 1 } end
            end
            return nil
        end,
    }
    s.resyncSelection = function(self) return self.selectedRow end
    local gameMap = opts.gameMap or (opts.inputToAxis or opts.screenRight or 1)
    local engine = {
        pressInput = function(_, which)
            presses[#presses + 1] = which
            if which == "up" then
                s.selectedRow = math.min(s.pieceCount - 1, s.selectedRow + 1)
            elseif which == "down" then
                s.selectedRow = math.max(0, s.selectedRow - 1)
            else
                local p = (which == "right") and 1 or -1
                -- rotation changes by p*gameMap*sign, so steps by p*gameMap
                local id = s.selectedRow
                s.steps[id] = (s.steps[id] or 0) + p * gameMap
            end
            return true
        end,
        -- fast mode cranks the scene interpolation speed on arm and restores it
        -- on stop; the values do not affect the decision logic under test
        getSceneInterp = function(_) return 20 end,
        setSceneInterp = function(_, _) return true end,
    }
    return s, engine, presses, rot
end

local function newDriver(engine)
    return Driver.new({ engine = engine, getTask = function() return {} end,
        log = silent })
end

local function runToEnd(driver, s, cap)
    cap = cap or 200
    for _ = 1, cap do
        if not driver:running() then break end
        driver:step(s)
    end
end

T.add("press direction is the exact inverse of the hint color mapping", function()
    local d = Driver.new({ log = silent })
    local palette = { hintLeft = "left", hintRight = "right", hintNeutral = "neutral" }
    for _, sign in ipairs({ 1, -1 }) do
        for _, m in ipairs({ 1, -1 }) do
            for _, dir in ipairs({ 1, -1 }) do
                local tag = " sign=" .. sign .. " m=" .. m .. " dir=" .. dir
                local s1 = { sign = sign, inputToAxis = m, nextMove = { dir = dir } }
                T.eq(d:pressDir(s1, { dir = dir }), hint.color(s1, palette),
                    "inputToAxis" .. tag)
                local s2 = { sign = sign, screenRight = m, nextMove = { dir = dir } }
                T.eq(d:pressDir(s2, { dir = dir }), hint.color(s2, palette),
                    "screenRight" .. tag)
            end
        end
    end
end)

T.add("full-auto drives a single off-center piece to the goal", function()
    local s, engine, presses, rot = makeWorld({
        pieceCount = 1, rotStart = { [0] = 2 }, sign = 1, screenRight = 1,
        selectedSig = true, selectedRow = 0,
    })
    local d = newDriver(engine)
    d:toggleFast(s)
    runToEnd(d, s)
    T.ok(not d:running(), "disengaged on solve")
    T.eq(rot(0), 0, "piece centered")
    T.eq(#presses, 2, "two turns, rotation 2 to 0")
    for _, p in ipairs(presses) do T.eq(p, "left", "all turns same direction") end
end)

T.add("full-auto selects the target piece before turning it", function()
    local s, engine, presses, rot = makeWorld({
        pieceCount = 3, rotStart = { [0] = 0, [1] = 0, [2] = 1 }, sign = 1,
        screenRight = 1, selectedSig = true, selectedRow = 0,
    })
    local d = newDriver(engine)
    d:toggleFast(s)
    runToEnd(d, s)
    T.ok(not d:running())
    T.eq(rot(2), 0, "target piece centered")
    local ups = 0
    for _, p in ipairs(presses) do if p == "up" then ups = ups + 1 end end
    T.ok(ups >= 2, "drove selection up to the target row")
end)

T.add("an uncalibrated nudge that resolves the opposite way is not a deviation", function()
    -- piece off-center at rot 2; the planner offers nothing, and no mapping is
    -- known so the nudge presses "right". The world resolves "right" NEGATIVE
    -- (gameMap=-1), i.e. toward center. With the fix every nudge is accepted
    -- (either sign counts) and the piece reaches 0; with the old code each nudge
    -- reads as an "unexpected state" deviation and the run stops after two.
    local logs = {}
    local function rec(m) logs[#logs + 1] = m end
    local s, engine, _, rot = makeWorld({
        pieceCount = 1, rotStart = { [0] = 2 }, sign = 1,
        selectedSig = true, selectedRow = 0, gameMap = -1,
        plan = function() return nil end,
    })
    local d = Driver.new({ engine = engine, getTask = function() return {} end,
        log = rec })
    d:toggleFast(s)
    runToEnd(d, s, 120)
    T.ok(not d:running(), "disengaged")
    T.eq(rot(0), 0, "nudges accepted both ways and reached center")
    local sawDeviation = false
    for _, m in ipairs(logs) do
        if m:find("deviation", 1, true) then sawDeviation = true end
    end
    T.ok(not sawDeviation, "did not misclassify a nudge as a deviation")
end)

T.add("waits while the solver is still searching, does not give up or nudge", function()
    -- a hard lock: plan() returns nil but leaves an UNFINISHED search on s.plan
    -- (the solver runs in budget slices across ticks). The driver must wait, not
    -- time out and nudge. Regression for "no solvable move found" firing on a
    -- solvable-but-slow lock while the hint still showed a move.
    local s, engine, presses = makeWorld({
        pieceCount = 1, rotStart = { [0] = 2 }, sign = 1, screenRight = 1,
        selectedSig = true, selectedRow = 0,
        plan = function(_, st) st.plan = { finished = false } return nil end,
    })
    local d = newDriver(engine)
    d:toggleFast(s)
    for _ = 1, 50 do if d:running() then d:step(s) end end
    T.ok(d:running(), "still engaged after 50 searching ticks (did not give up)")
    T.eq(#presses, 0, "did not nudge while the solver was still searching")
end)

T.add("stops when the route cycles without progress (model mismatch)", function()
    -- a lock whose model oscillates: the move always lands as asked, but the
    -- planner keeps pushing the same piece back and forth and never reaches the
    -- goal (piece 1 is never targeted). The driver must detect the cycle and
    -- stop, not press forever. Regression for the BT_Chest_02_Lock endless loop.
    local logs = {}
    local function rec(m) logs[#logs + 1] = m end
    local s, engine = makeWorld({
        pieceCount = 2, rotStart = { [0] = 1, [1] = 2 }, sign = 1, screenRight = 1,
        selectedSig = true, selectedRow = 0,
        plan = function(_, st)
            local r0 = st.rotStart[0] + st.sign * (st.steps[0] or 0)
            if r0 > 0 then return { piece = 0, dir = -1 } end
            return { piece = 0, dir = 1 } -- piece 1 stays off-center: never solves
        end,
    })
    local d = Driver.new({ engine = engine, getTask = function() return {} end,
        log = rec })
    d:toggleFast(s)
    runToEnd(d, s, 300)
    T.ok(not d:running(), "disengaged instead of looping forever")
    local cyc = false
    for _, m in ipairs(logs) do if m:find("cycling", 1, true) then cyc = true end end
    T.ok(cyc, "stopped with a cycling / no-progress reason")
end)

T.add("aborts honestly when selection is not observable (no glow)", function()
    local s, engine, presses = makeWorld({
        pieceCount = 2, rotStart = { [0] = 0, [1] = 1 }, sign = 1,
        screenRight = 1, selectedSig = nil, selectedRow = 0,
    })
    local d = newDriver(engine)
    d:toggleFast(s)
    runToEnd(d, s, 20)
    T.ok(not d:running(), "disengaged")
    T.eq(#presses, 0, "never pressed without a confirmable selection")
end)

T.add("a second toggle cancels an in-progress run", function()
    -- many pieces off-center so the run is still going after a few ticks; the
    -- second toggle must stop it (F6-to-cancel, and the auto-off cancel path).
    local s, engine = makeWorld({
        pieceCount = 3, rotStart = { [0] = 3, [1] = 3, [2] = 3 }, sign = 1,
        screenRight = 1, selectedSig = true, selectedRow = 0,
    })
    local d = newDriver(engine)
    d:toggleFast(s)
    d:step(s) -- begin a move
    T.ok(d:running(), "engaged and running")
    d:toggleFast(s)
    T.ok(not d:running(), "second toggle cancelled the run")
end)

os.exit(T.run())
