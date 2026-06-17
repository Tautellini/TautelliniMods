-- driver.lua -- Auto-Solve: drive the lock open (engine-facing). A tick-driven state
-- machine: main arms it (s.autopilot = self); the session calls step(s) once per
-- SETTLED tick. Each step looks up the next move (s:lookupMove()), drives selection
-- via the glow, presses the turn, checks it next tick. No route/replan/nudge -- the
-- policy already knows the move. Names no UE4SS global; state lives on the Session.

local setmetatable = setmetatable
local math, table = math, table

local SELECT_TICKS = 4   -- settled ticks allowed to reach the target piece
local STUCK_LIMIT = 3    -- pressed moves with no state change before giving up
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
        self:finish(s, "cancelled", false)
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
    if s.stateUnknown or not s.lockPolicy then
        self:finish(s, "lock state not usable", false); return
    end

    -- judge the previous press: unchanged state = stuck (refused move = the live edges
    -- disagree with the chosen variant)
    local state = self:stateKey(s)
    if self.awaitingMove then
        self.awaitingMove = false
        if state == self.lastState then
            self.stuck = self.stuck + 1
            if self.stuck >= STUCK_LIMIT then
                self:finish(s, "no progress (live lock disagrees with the "
                    .. "precision variant)", false)
                return
            end
        else
            self.stuck = 0
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
        if self.phase ~= "selecting" or self.target ~= move.piece then
            self.phase, self.target, self.selectTicks = "selecting", move.piece, 0
        end
        self.selectTicks = self.selectTicks + 1
        if self.selectTicks > SELECT_TICKS then
            self:finish(s, "could not select the target piece", false)
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

function Driver:finish(s, why, success)
    self:restoreInterp()
    if s then s.autopilot = nil end
    self:reset()
    if success then
        self.log("Auto-solve: " .. why)
    else
        self.log("Auto-solve stopped: " .. why)
    end
end

return Driver
