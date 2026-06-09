-- driver.lua  --  Auto-Solve feature: drive the lock to open (engine-facing).
--
-- Turns the solver's route into executed moves. It is NOT a pure file (it uses
-- the injected engine adapter to press the task input UFunctions), but like the
-- session it names NO UE4SS global: all engine access is through the pcall-
-- wrapped facade, and all per-lock state lives on the live Session (s), which
-- already owns settle detection, the glow-based selection truth (selSync), the
-- move processing and the at-goal/refusal evidence. The driver only DECIDES and
-- PRESSES; it re-uses the session's measurement instead of re-implementing it.
--
-- It runs as a tick-driven state machine: main arms it by setting s.autopilot,
-- and the session calls driver:step(s) ONCE per SETTLED tick. That cadence is
-- the move-honoured signal: a turn animates over a tick or two, so the next
-- press only fires once the previous one has demonstrably landed. No game-thread
-- stall, no second loop, no press fired mid-animation.
--
-- MOVE-AND-PRESERVE: this file never touches the solver math. It calls
-- s.solver:plan(s) and s.solver:moveValid(s, x, d) and reads the measured state;
-- it does not encode states, rotate the base-7 digits, or replan by hand.

local setmetatable = setmetatable
local math = math
local table = table

-- Tuning. Settled ticks are ~400ms, so these are in tick units unless noted.
local WAIT_TICKS = 8       -- wait this long for a plan before nudging (~3s)
local NUDGE_MAX_FULL = 3   -- exploratory "possible" moves before giving up (full-auto)
local NUDGE_MAX_SINGLE = 1 -- one exploratory move at most for a single F6
local SELECT_TICKS = 4     -- give selection this many ticks to reach the target
local MOVE_GRACE = 2       -- settled checks showing no change before "no effect"
local DEVIATION_MAX = 2    -- consecutive deviations that stop a full-auto run
local CYCLE_LIMIT = 3      -- stop full-auto if any state recurs this many times:
                           -- a correct route never revisits a state, so this
                           -- means the route is oscillating because the live
                           -- lock's connections disagree with the model

local Driver = {}
Driver.__index = Driver

-- opts: { engine = adapter, getTask = function() return freshTask end,
--         log = function(msg) end, debug = boolean }
function Driver.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Driver)
    self.engine = opts.engine
    self.getTask = opts.getTask or function() return nil end
    self.log = opts.log or function() end
    self.debug = opts.debug and true or false
    self:reset()
    return self
end

-- clear all run state; mode nil means disengaged
function Driver:reset()
    self.mode = nil       -- nil | "single" | "full"
    self.phase = nil      -- "idle" | "selecting" | "moving"
    self.move = nil       -- the move being executed { piece, dir, nudge }
    self.target = nil     -- the piece we are selecting toward
    self.preRot = nil     -- the target piece's rotation before the press
    self.dirPress = nil   -- "left"/"right" for the turn
    self.boundSession = nil -- the session this run belongs to
    self.everMoved = false -- has any issued press ever moved a piece this run
    self.visits = {}      -- state-key -> times reached, for cycle detection
    self.waitTicks = 0
    self.selectTicks = 0
    self.moveTicks = 0
    self.nudges = 0
    self.deviations = 0
end

function Driver:running()
    return self.mode ~= nil
end

-- a run belongs to one lock: a mode left set from a previous or already-stopped
-- session must not make the next hotkey press read as "cancel". Drop it.
function Driver:freshen(s)
    if self.mode and (self.boundSession ~= s or not s or s.stop) then
        self:reset()
    end
end

-- ---------------------------------------------------------------- arming --

-- F6: execute exactly the next move, then disengage. Does nothing (with a line)
-- while a run is already in progress, per the design: F6 never cancels.
function Driver:armSingle(s)
    self:freshen(s)
    if self:running() then
        self.log("Auto-solve already running, F6 ignored")
        return
    end
    if not s then
        self.log("Auto-solve: no active lock")
        return
    end
    self:reset()
    self.mode = "single"
    self.phase = "idle"
    self.boundSession = s
    self:engage(s)
    self.log("Auto-solve: stepping one move")
end

-- Shift+F6: toggle full-auto. A second press cancels; a successful open also
-- disengages on its own (handled in step()).
function Driver:toggleFull(s)
    self:freshen(s)
    if self.mode == "full" then
        self:finish(s, "cancelled", false)
        return
    end
    if self.mode == "single" then
        self.log("Auto-solve already running, full-auto ignored")
        return
    end
    if not s then
        self.log("Auto-solve: no active lock")
        return
    end
    self:reset()
    self.mode = "full"
    self.phase = "idle"
    self.boundSession = s
    self:engage(s)
    self.log("Auto-solve: full-auto started")
end

-- arm the session: the session tick will call step() once per settle. The
-- driver does NOT touch the shared hint flag (that is the user's preference); it
-- plans on its own. Running with the hint on (F7) additionally paints the driven
-- piece and enables the session's refusal self-healing, but neither is required.
function Driver:engage(s)
    s.autopilot = self
end

-- ------------------------------------------------------------- the loop --

function Driver:step(s)
    if not self.mode then
        if s then s.autopilot = nil end
        return
    end
    if s.stop then self:reset() return end
    -- usability: the planner needs the bar-anchored frame. stateUnknown or a
    -- missing frame means there is nothing safe to plan against.
    if s.stateUnknown or not s.hintGeometry then
        self:finish(s, "lock state not usable", false)
        return
    end
    -- the goal is every pin centered; reaching it auto-opens the lock (canon)
    if self:atGoal(s) then
        self:finish(s, "lock solved", true)
        return
    end
    local phase = self.phase
    if phase == "idle" then
        self:stepIdle(s)
    elseif phase == "selecting" then
        self:stepSelecting(s)
    elseif phase == "moving" then
        self:stepMoving(s)
    end
end

-- decide the next move (or wait, or nudge)
function Driver:stepIdle(s)
    local move = s.solver:plan(s)
    if move then
        self.waitTicks = 0
        self:beginMove(s, move)
        return
    end
    -- The solver searches in budget slices across ticks; a hard lock (a long
    -- route, or a replan forced when a move reveals a pruned edge) can need many
    -- ticks. While it is STILL SEARCHING, wait patiently and do NOT nudge:
    -- nudging perturbs the state and restarts the search, which is what made
    -- hard locks give up with "no solvable move found" while the hint, having no
    -- timeout, still found the move. The solver always concludes on its own (a
    -- route, or a no-route latch that finishes the plan), so this cannot wait
    -- forever.
    if s.plan and not s.plan.finished then
        self.waitTicks = 0
        return
    end
    -- the search has CONCLUDED with no move (no route under the believed model),
    -- or there is no plan: genuinely stuck. Wait a brief grace, then nudge.
    self.waitTicks = self.waitTicks + 1
    if self.waitTicks < WAIT_TICKS then return end
    -- waited long enough: make a "possible" move to progress and let direction
    -- calibrate from the observed result. Bounded so a truly stuck lock stops.
    local budget = (self.mode == "single") and NUDGE_MAX_SINGLE or NUDGE_MAX_FULL
    if self.nudges >= budget then
        self:finish(s, "no solvable move found", false)
        return
    end
    local nx = self:findNudge(s)
    if not nx then
        self:finish(s, "no legal move available to make progress", false)
        return
    end
    self.nudges = self.nudges + 1
    self.waitTicks = 0
    self.log("Auto-solve: no planned move, trying a possible move on piece "
        .. nx.piece)
    self:beginMove(s, { piece = nx.piece, dir = nx.dir, nudge = true })
end

-- a piece movable BOTH ways: the press is accepted whichever way the (possibly
-- uncalibrated) mapping resolves, so it never costs durability. It makes progress
-- and, when the hooks observe it, lets the session calibrate inputToAxis.
function Driver:findNudge(s)
    for x = 0, s.pieceCount - 1 do
        if s.solver:moveValid(s, x, 1) and s.solver:moveValid(s, x, -1) then
            return { piece = x, dir = 1 }
        end
    end
    return nil
end

-- set up a move: resolve the press direction, drive selection, then turn
function Driver:beginMove(s, move)
    self.move = move
    self.target = move.piece
    self.preRot = self:rot(s, move.piece)
    self.dirPress = self:pressDir(s, move)
    self.selectTicks = 0
    s:resyncSelection()
    if s.selectedRow == self.target then
        self:issueMove(s)
        return
    end
    -- driving selection means pressing Up/Down and confirming the new row from
    -- the glow. Without an observable glow (selectedSig nil) we cannot confirm
    -- selection from reality and would have to trust input counting, which the
    -- driver deliberately does not. Stop honestly instead of mis-targeting.
    if not s.selectedSig then
        self:finish(s, "selection is not observable on this lock", false)
        return
    end
    self.phase = "selecting"
    self:driveSelection(s)
end

-- "left"/"right" for the turn, or nil if the direction is not yet derivable. A
-- nudge on a both-ways piece is accepted either way, so it defaults to "right".
function Driver:pressDir(s, move)
    local m = s.inputToAxis or s.screenRight
    if not m then
        if move.nudge then return "right" end
        return nil
    end
    return (move.dir * m * s.sign > 0) and "right" or "left"
end

-- press selection toward the target. The glow (confirmed via resyncSelection on
-- the next tick) is the truth, so we can fire every needed step at once; the
-- glow follows the game's own handler, not the UE4SS hook, so this does not
-- depend on a Lua-initiated press re-entering the input hook. Capped at the piece
-- count, and re-checked next tick in case any press was dropped.
function Driver:driveSelection(s)
    local cur = s.selectedRow
    local need = self.target - cur
    if need == 0 then return end
    local which = need > 0 and "up" or "down"
    local count = math.min(math.abs(need), s.pieceCount)
    for _ = 1, count do
        self.engine.pressInput(self.getTask(), which)
    end
    self.selectTicks = self.selectTicks + 1
end

function Driver:stepSelecting(s)
    s:resyncSelection()
    if s.selectedRow == self.target then
        self:issueMove(s)
        return
    end
    if self.selectTicks >= SELECT_TICKS then
        self:onDeviation(s, "could not select the target piece")
        return
    end
    self:driveSelection(s)
end

-- turn the selected piece; the result is checked on a later settled tick
function Driver:issueMove(s)
    if not self.dirPress then
        self:onDeviation(s, "move direction not calibrated")
        return
    end
    self.preRot = self:rot(s, self.target) -- freshest reading before the press
    self.moveTicks = 0
    self.phase = "moving"
    self.engine.pressInput(self.getTask(), self.dirPress)
end

-- a turn animates, so the session early-returns during motion and only steps us
-- again once settled: by then s.steps reflects the outcome.
function Driver:stepMoving(s)
    local cur = self:rot(s, self.target)
    local changed = cur ~= self.preRot
    if changed then self.everMoved = true end
    if changed then
        -- a NUDGE only needs to move SOMETHING: its job is to make progress and
        -- reveal the direction, so either sign counts as success. A real move
        -- must land on the predicted rotation; anything else is a deviation.
        if self.move.nudge or cur == self.preRot + self.move.dir then
            self.deviations = 0
            if self.move.nudge then
                self.phase, self.move = "idle", nil
            elseif self.mode == "single" then
                self:finish(s, "move done", true)
            elseif self:cycling(s) then
                -- the move landed as asked, but we have now reached this exact
                -- arrangement several times: the route is oscillating because the
                -- live lock's connections disagree with the model. Stop instead
                -- of pressing forever.
                self:finish(s, "cycling without progress (this lock's "
                    .. "connections do not match the model)", false)
            else
                self.phase, self.move = "idle", nil
            end
        else
            self:onDeviation(s, "unexpected state after the move")
        end
        return
    end
    -- unchanged: a refusal (shake back to start) or a press the game ignored.
    -- Allow a grace tick in case the settle detector caught the frame early.
    self.moveTicks = self.moveTicks + 1
    if self.moveTicks < MOVE_GRACE then return end
    if self.everMoved then
        self:onDeviation(s, "the move had no effect (refused or dropped)")
    else
        -- nothing this run has ever moved: the documented input-state-dependent
        -- case where programmatic presses are inert on this build
        self:onDeviation(s, "no movement yet (programmatic input may be inert "
            .. "on this game build)")
    end
end

-- single-step stops on any deviation; full-auto re-reads, replans and continues
-- once, stopping only on a second consecutive deviation.
function Driver:onDeviation(s, why)
    if self.mode == "single" then
        self:finish(s, why, false)
        return
    end
    self.deviations = self.deviations + 1
    if self.deviations >= DEVIATION_MAX then
        self:finish(s, "stopped after repeated deviations (" .. why .. ")", false)
        return
    end
    if self.debug then
        self.log("Auto-solve: deviation (" .. why .. "), replanning")
    end
    s.plan, s.nextMove = nil, nil -- force a fresh route from the current state
    self.phase, self.move = "idle", nil
end

-- ------------------------------------------------------------- helpers --

function Driver:rot(s, id)
    return s.rotStart[id] + s.sign * (s.steps[id] or 0)
end

function Driver:atGoal(s)
    for id = 0, s.pieceCount - 1 do
        if self:rot(s, id) ~= 0 then return false end
    end
    return true
end

-- a string key for the current rotation arrangement, for cycle detection
function Driver:stateKey(s)
    local t = {}
    for id = 0, s.pieceCount - 1 do t[#t + 1] = self:rot(s, id) end
    return table.concat(t, ",")
end

-- record reaching the current arrangement; true once it has recurred enough
-- times to call it a cycle (the route keeps undoing itself)
function Driver:cycling(s)
    local key = self:stateKey(s)
    self.visits[key] = (self.visits[key] or 0) + 1
    return self.visits[key] >= CYCLE_LIMIT
end

-- end the run, clear the seam, log one line (success or stop)
function Driver:finish(s, why, success)
    if s then s.autopilot = nil end
    self:reset()
    if success then
        self.log("Auto-solve: " .. why)
    else
        self.log("Auto-solve stopped: " .. why)
    end
end

return Driver
