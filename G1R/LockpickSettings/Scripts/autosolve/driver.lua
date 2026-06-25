-- driver.lua -- Auto-Solve: drive the lock open (engine-facing). A tick-driven state
-- machine: main arms it (s.autopilot = self); the session calls step(s) once per
-- SETTLED tick. Each step looks up the next move (s:lookupMove()), drives selection
-- via the glow, presses the turn, checks it next tick. No route/replan/nudge -- the
-- policy already knows the move. Names no UE4SS global; state lives on the Session.

local setmetatable = setmetatable
local math, table = math, table

local SELECT_TICKS = 4   -- settled ticks allowed to reach the target piece
local STUCK_LIMIT = 3    -- pressed moves with no state change before giving up
local CYCLE_LIMIT = 3    -- a distinct post-move state revisited this often = looping
-- Absolute per-lock settled-tick backstop. The OPTIMAL solve runs up to ~92 moves from the
-- authored start (138 from a worst-case scrambled start), measured across every lock at k=0 (the
-- unskilled, full-graph variant, which is the longest); each move costs ~2-3 settled ticks (drive
-- selection, then turn). The old 90 therefore died around ~35-45 moves -- the unskilled "limited
-- moves" failures (a correct BFS-optimal policy never stalls or loops, so this cap was the ONLY
-- thing killing a solvable lock). STUCK_LIMIT/CYCLE_LIMIT catch real non-progress within 3 ticks,
-- so this stays a pure runaway backstop and can be generous: 1000 covers the 138-move worst case
-- at ~7 ticks/move, leaving wide headroom for any selection overhead we can't measure offline.
local MAX_STEPS = 1000
local FAST_INTERP = 250.0 -- default solve-time animation speed; config overrides

local Driver = {}
Driver.__index = Driver

-- opts: { engine, getTask, log, debug, speed }
function Driver.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Driver)
    self.engine = opts.engine
    self.getTask = opts.getTask or function() return nil end
    self.log = opts.log or function() end
    self.debug = opts.debug and true or false
    self.speed = (type(opts.speed) == "number" and opts.speed > 0)
        and opts.speed or FAST_INTERP
    self:reset()
    return self
end

function Driver:reset()
    self.mode = nil          -- nil | "fast"
    self.phase = nil         -- "idle" | "selecting"
    self.target = nil
    self.dirPress = nil
    self.boundSession = nil
    self.selectTicks = 0
    self.lastState = nil
    self.stuck = 0
    self.noMove = 0          -- consecutive settled states with no policy move
    self.awaitingMove = false
    self.seen = {}           -- distinct post-move states visited, for cycle detection
    self.totalSteps = 0      -- settled steps this run (hard anti-churn cap)
    self.varsTried = nil     -- precision variants the sweep has tried this run
    self.origInterp = nil
end

function Driver:running()
    return self.mode ~= nil
end

-- a run belongs to one lock: drop a stale mode, un-cranking its scene first
function Driver:freshen(s)
    if self.mode and (self.boundSession ~= s or not s or s.stop) then
        self:restoreInterp()
        self:reset()
    end
end

-- toggle the fast solver on the session; a second call cancels an in-progress run
function Driver:toggleFast(s)
    self:freshen(s)
    if self.mode == "fast" then
        self:finish(s, "cancelled", false, false) -- user cancel: never count against the lock
        return
    end
    if not s or s.stop or s.opened then
        self.log("Auto-solve: no active lock")
        return
    end
    self:reset()
    self.mode = "fast"
    self.phase = "idle"
    self.boundSession = s
    self.origInterp = self.engine.getSceneInterp(s.scene)
    self.engine.setSceneInterp(s.scene, self.speed)
    s.autopilot = self
    pcall(function() s:clearTints() end) -- silent while solving
    self.log("Auto-solve started")
end

function Driver:step(s)
    if not self.mode then s.autopilot = nil; return end
    if s.stop then self:restoreInterp(); self:reset(); return end
    -- the game-confirmed open beats any measurement: stop now, never press a
    -- tearing-down task (a native AV pcall can't catch)
    if s.opened then self:finish(s, "lock solved", true); return end
    if s.stateUnknown then
        self:finish(s, "lock state not usable", false); return
    end
    -- inflate the policy on the first step (off the open dispatch; see session.ensurePolicy).
    -- Bail cleanly if it cannot load instead of pressing blind.
    if not s:ensurePolicy() then
        self:finish(s, "lock policy not available", false); return
    end
    -- hard backstop: a settled step that finds neither the goal nor a stop must still be
    -- bounded. Every non-finishing path below falls through to another step, so cap the
    -- total. This alone guarantees we never spin the game-thread queue forever.
    self.totalSteps = self.totalSteps + 1
    if self.totalSteps > MAX_STEPS then
        self:finish(s, "exceeded the per-lock step budget (giving up to avoid churn)", false)
        return
    end

    -- judge the previous press: unchanged state = stuck (refused move = the live edges
    -- disagree with the chosen variant); a distinct state we have already moved through =
    -- the policy is cycling, never converging (same root cause, but the state changes).
    local state = self:stateKey(s)
    if self.awaitingMove then
        self.awaitingMove = false
        if state == self.lastState then
            self.stuck = self.stuck + 1
            if self.stuck >= STUCK_LIMIT then
                if self:trySweep(s, "no progress") then return end
                self:finish(s, "no progress (live lock disagrees with the "
                    .. "precision variant)", false)
                return
            end
        else
            self.stuck = 0
            self.seen[state] = (self.seen[state] or 0) + 1
            if self.seen[state] >= CYCLE_LIMIT then
                if self:trySweep(s, "state cycling") then return end
                self:finish(s, "lock state cycling, not converging (live lock "
                    .. "disagrees with the precision variant)", false)
                return
            end
        end
    end
    self.lastState = state

    local move = s:lookupMove()
    if not move then
        -- nil at goal = solved; nil off-goal on a settled state = off the variant's
        -- policy (precision mismatch / transient misread): one retry, then stop
        if self:atGoal(s) then self:finish(s, "lock solved", true); return end
        self.noMove = (self.noMove or 0) + 1
        if self.noMove >= 2 then
            if self:trySweep(s, "no move for the state") then return end
            self:finish(s, "no move for this state (off the policy's reachable "
                .. "set, likely a precision/variant mismatch)", false)
        end
        return
    end
    self.noMove = 0

    -- drive selection to the target via the glow, then turn it
    s:resyncSelection()
    if s.selectedRow ~= move.piece then
        if not s.selectedSig then
            self:finish(s, "selection is not observable on this lock", false)
            return
        end
        -- count selecting ticks since the last EXECUTED move, not per target: a target
        -- that flips every tick (an unstable live read) used to reset this each tick and
        -- hid the runaway. A real drive reaches the piece in one tick, so the budget is
        -- only spent when selection genuinely cannot settle.
        if self.phase ~= "selecting" then
            self.phase, self.selectTicks = "selecting", 0
        end
        self.target = move.piece
        self.selectTicks = self.selectTicks + 1
        if self.selectTicks > SELECT_TICKS then
            self:finish(s, "could not reach the target piece (selection unstable)", false)
            return
        end
        self:driveSelection(s, move.piece)
        return
    end

    self.phase = "idle"
    local pd = self:pressDir(s, move.dir)
    if not pd then
        self:finish(s, "move direction not derivable", false)
        return
    end
    self.awaitingMove = true
    self:press(s, pd)
end

-- press the live task; a failed dispatch = the input is gone, so stop
function Driver:press(s, which)
    local ok = self.engine.pressInput(self.getTask(), which)
    if not ok then
        self:finish(s, "minigame input no longer reachable (lock closed or exited)",
            false)
    end
    return ok
end

-- press Up/Down toward the target row (the glow confirms it next tick)
function Driver:driveSelection(s, target)
    local need = target - s.selectedRow
    if need == 0 then return end
    local which = need > 0 and "up" or "down"
    for _ = 1, math.min(math.abs(need), s.pieceCount) do
        if not self:press(s, which) then return end
    end
end

-- "left"/"right" for a rotation-dir move via screenRight (controls inverted), or nil
function Driver:pressDir(s, dir)
    local m = s.screenRight
    if not m then return nil end
    return (dir * s.sign * m > 0) and "right" or "left"
end

function Driver:rot(s, id)
    return s.rotStart[id] + s.sign * (s.steps[id] or 0)
end

function Driver:atGoal(s)
    for id = 0, s.pieceCount - 1 do
        if self:rot(s, id) ~= 0 then return false end
    end
    return true
end

-- rotation arrangement as a string key, for stuck detection
function Driver:stateKey(s)
    local t = {}
    for id = 0, s.pieceCount - 1 do t[#t + 1] = self:rot(s, id) end
    return table.concat(t, ",")
end

-- restore the cranked animation speed on the BOUND session's scene. IsValid-gated.
-- MUST run on every disengage path or the crank leaks into later hint-only play.
function Driver:restoreInterp()
    local bs = self.boundSession
    if self.origInterp ~= nil and bs and bs.scene then
        self.engine.setSceneInterp(bs.scene, self.origInterp)
    end
    self.origInterp = nil
end

-- on a "disagrees" give-up, retry the lock with the OTHER precision variants before quitting.
-- The game removes the first round(LockpickPrecision) connections (confirmed by reversing the
-- minigame), so the SELECTION is exactly our first-k model; what can be off is the precision
-- VALUE we read at open versus the one the game used at setup. Tries k=0 first (least pruned, the
-- full graph), then 1, 2; resets the per-attempt counters and keeps the run going from the current
-- live state. Returns true if it switched (caller returns), false when every variant is exhausted.
function Driver:trySweep(s, reason)
    if not s.usePrecision then return false end
    self.varsTried = self.varsTried or { [s.precisionK or 0] = true }
    for k = 0, 2 do
        if not self.varsTried[k] then
            self.varsTried[k] = true
            if s:usePrecision(k) then
                self.stuck, self.noMove = 0, 0
                self.lastState, self.awaitingMove, self.seen = nil, false, {}
                self.phase = "idle"
                self.log("Auto-solve: variant disagreed (" .. reason
                    .. "), retrying as precision variant k=" .. k)
                return true
            end
        end
    end
    return false
end

-- gaveUp (default: any non-success) marks the SESSION as "auto-solve could not solve this
-- lock", which main reads to stop re-arming it. A user cancel passes gaveUp=false so a
-- deliberate toggle-off never counts against the lock.
function Driver:finish(s, why, success, gaveUp)
    if gaveUp == nil then gaveUp = not success end
    self:restoreInterp()
    if s then
        s.autopilot = nil
        if gaveUp then s.autoFails = (s.autoFails or 0) + 1 end
    end
    self:reset()
    if success then
        self.log("Auto-solve: " .. why)
    else
        self.log("Auto-solve stopped: " .. why)
    end
end

return Driver
