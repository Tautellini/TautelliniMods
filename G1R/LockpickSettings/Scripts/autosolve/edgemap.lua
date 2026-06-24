-- edgemap.lua -- DEV DIAGNOSTIC (debug-gated, never armed in normal play). Answers WHY a lock
-- "disagrees with the precision variant". The shipped policy assumes the game removes the FIRST
-- k connections (build_policies.py: edges = conns[k:]). This maps the lock's ACTUAL live active
-- out-edges by reversible probe moves, compares them to every shipped variant, and reports
-- whether the live lock matches a different variant (a wrong COUNT -- the precision->variant
-- mapping is off) or no first-k variant at all (a wrong SELECTION -- the game removed a
-- connection that is not the first k, or added one the export lacks). The latter means the
-- "drop first k" model cannot be right for this lock and live edge-learning is needed.
--
-- Runs as a session autopilot (the driver's :step(s) contract), so it reuses the session's
-- settle detection, rotation decode (s.steps/rotStart/sign) and selection glow. NON-DESTRUCTIVE:
-- every probe turn is undone. Engage via the debug F-key wired in main (only when debugSolver).

local setmetatable = setmetatable
local pairs, tonumber, type = pairs, tonumber, type
local table = table

local SELECT_GIVEUP = 6   -- settled steps allowed to reach a target selection before skipping it
local MAX_STEPS = 240     -- absolute backstop (a full map is about 4 * pieces steps)

local EdgeMap = {}
EdgeMap.__index = EdgeMap

-- opts: { engine, getTask, getGraph (lockName -> {pieces, connections}), log }
function EdgeMap.new(opts)
    opts = opts or {}
    local self = setmetatable({}, EdgeMap)
    self.engine = opts.engine
    self.getTask = opts.getTask or function() return nil end
    self.getGraph = opts.getGraph or function() return nil end
    self.log = opts.log or function() end
    self.mode = nil
    return self
end

function EdgeMap:running() return self.mode ~= nil end

-- the session cleanup path calls this on any autopilot; we crank nothing, so it is a no-op
function EdgeMap:restoreInterp() end

function EdgeMap:absRots(s)
    local r = {}
    for id = 0, s.pieceCount - 1 do r[id] = s.rotStart[id] + s.sign * (s.steps[id] or 0) end
    return r
end

local function rotsStr(r, n)
    local t = {}
    for id = 0, n - 1 do t[#t + 1] = tostring(r[id]) end
    return "[" .. table.concat(t, ",") .. "]"
end

-- engage: the session tick will call :step(s) each settled tick
function EdgeMap:start(s)
    if not s or s.stop or s.opened or s.stateUnknown or not s.hintGeometry then
        self.log("EdgeMap: no usable live lock to map (need a settled, geometry-readable minigame)")
        return false
    end
    self.graph = self.getGraph(s.lockName)
    if not (self.graph and self.graph.connections) then
        self.log("EdgeMap: no authored graph for '" .. tostring(s.lockName) .. "', cannot compare")
        return false
    end
    self.mode = "map"
    self.phase = "select"
    self.piece = 0
    self.observed = {}      -- [mover] = { [partner] = dir } or false when unprobeable
    self.dir = "right"
    self.totalSteps = 0
    self.selectTicks = 0
    self.before = nil
    self.startRots = self:absRots(s)
    s.autopilot = self
    self.log(("EdgeMap: mapping '%s' (variant read k=%s), start rots %s -- driving reversible "
        .. "probe moves, hold still"):format(tostring(s.lockName), tostring(s.precisionK),
        rotsStr(self.startRots, s.pieceCount)))
    return true
end

function EdgeMap:press(s, which)
    return self.engine.pressInput(self.getTask(), which)
end

function EdgeMap:finish(s, why)
    if s then s.autopilot = nil end
    self.mode = nil
    self.log("EdgeMap: " .. why)
end

function EdgeMap:step(s)
    if not self.mode then s.autopilot = nil; return end
    if s.stop or s.opened then self:report(s); self:finish(s, "lock closed mid-map (partial)"); return end
    self.totalSteps = self.totalSteps + 1
    if self.totalSteps > MAX_STEPS then
        self:report(s); self:finish(s, "step budget reached (partial map)"); return
    end

    if self.phase == "select" then
        if self.piece >= s.pieceCount then self:report(s); self:finish(s, "map complete"); return end
        s:resyncSelection()
        if not s.selectedSig then self:report(s); self:finish(s, "selection not observable, cannot map"); return end
        if s.selectedRow == self.piece then
            self.phase, self.selectTicks, self.dir = "probe", 0, "right"
            return
        end
        self.selectTicks = self.selectTicks + 1
        if self.selectTicks > SELECT_GIVEUP then
            self.observed[self.piece] = false   -- could not select it to probe
            self.piece, self.phase, self.selectTicks = self.piece + 1, "select", 0
            return
        end
        local need = self.piece - s.selectedRow
        self:press(s, need > 0 and "up" or "down")
        return
    end

    if self.phase == "probe" then
        self.before = self:absRots(s)
        self:press(s, self.dir)
        self.phase = "observe"
        return
    end

    if self.phase == "observe" then
        local after = self:absRots(s)
        local moverDelta = after[self.piece] - self.before[self.piece]
        if moverDelta == 0 then
            -- the turn was refused (mover at a rail end this way); try the other way once
            if self.dir == "right" then self.dir = "left"; self.phase = "probe"; return end
            self.observed[self.piece] = false   -- unprobeable from this state (both turns off-rail)
            self.piece, self.phase = self.piece + 1, "select"
            return
        end
        local partners = {}
        for id = 0, s.pieceCount - 1 do
            if id ~= self.piece then
                local d = after[id] - self.before[id]
                if d ~= 0 then partners[id] = d / moverDelta end   -- edge dir = partnerDelta / moverDelta
            end
        end
        self.observed[self.piece] = partners
        self:press(s, self.dir == "right" and "left" or "right")  -- undo (atomic moves reverse cleanly)
        self.phase = "verify"
        return
    end

    if self.phase == "verify" then
        local now = self:absRots(s)
        for id = 0, s.pieceCount - 1 do
            if now[id] ~= self.before[id] then
                self.log(("EdgeMap: WARNING piece %d not fully restored (%s -> %s)"):format(
                    self.piece, rotsStr(self.before, s.pieceCount), rotsStr(now, s.pieceCount)))
                break
            end
        end
        self.piece, self.phase = self.piece + 1, "select"
        return
    end
end

-- directed (a>b -> dir) set of the authored connections with the first k dropped
local function variantSet(conns, k)
    local set = {}
    for i = k + 1, #conns do
        local c = conns[i]
        set[c.a .. ">" .. c.b] = c.dir
    end
    return set
end

function EdgeMap:report(s)
    local n = s.pieceCount
    -- 1. the raw live observation
    local obs, obsLines, unprobeable = {}, {}, {}
    for a = 0, n - 1 do
        local parts = self.observed[a]
        if parts == false then
            unprobeable[#unprobeable + 1] = tostring(a)
        elseif type(parts) == "table" then
            local segs = {}
            for b, dir in pairs(parts) do
                obs[a .. ">" .. b] = dir
                segs[#segs + 1] = b .. "(" .. (dir > 0 and "+1" or "-1") .. ")"
            end
            table.sort(segs)
            obsLines[#obsLines + 1] = a .. "->{" .. table.concat(segs, ",") .. "}"
        end
    end
    self.log("EdgeMap: LIVE active out-edges for '" .. tostring(s.lockName) .. "': "
        .. (#obsLines > 0 and table.concat(obsLines, "  ") or "(none observed)"))
    if #unprobeable > 0 then
        self.log("EdgeMap: pieces not probeable from this state (every turn off-rail): "
            .. table.concat(unprobeable, ","))
    end
    -- 2. compare to each shipped first-k variant, counting only probed movers
    local conns = self.graph.connections
    local matches = {}
    for k = 0, 2 do
        if k <= #conns then
            local exp = variantSet(conns, k)
            local missing, extra = {}, {}
            for key, dir in pairs(exp) do
                local mover = tonumber(key:match("^(%d+)>"))
                if self.observed[mover] ~= false then
                    if obs[key] == nil then missing[#missing + 1] = key
                    elseif obs[key] ~= dir then missing[#missing + 1] = key .. "(dir!)" end
                end
            end
            for key in pairs(obs) do if exp[key] == nil then extra[#extra + 1] = key end end
            if #missing == 0 and #extra == 0 then
                matches[#matches + 1] = k
                self.log("EdgeMap: variant k=" .. k .. " is CONSISTENT with the probed edges"
                    .. (k == s.precisionK and "   <- the precision read" or ""))
            else
                self.log(("EdgeMap: variant k=%d differs (expected-not-seen: %s | seen-not-expected: %s)"):format(
                    k, #missing > 0 and table.concat(missing, ",") or "none",
                    #extra > 0 and table.concat(extra, ",") or "none"))
            end
        end
    end
    -- 3. headline verdict. More than one consistent variant = the probed pins do not discriminate
    -- them; a constrained start state (too many pins at the rail edge) blocked the deciding probes.
    if #matches == 0 then
        self.log("EdgeMap: VERDICT -> WRONG SELECTION. No variant matches the live lock; the game removed a "
            .. "connection that is not the first k (or the export lacks one it added). The 'drop first k' "
            .. "model is wrong for this lock -- it needs live edge-learning, not a fixed variant.")
    elseif #matches > 1 then
        self.log(("EdgeMap: VERDICT -> INCONCLUSIVE. Variants %s all fit the %d probed mover(s); they differ "
            .. "only on pins this start state would not let me turn (every move off-rail). Re-run from a less "
            .. "constrained lock, or just let the driver's variant sweep settle it live."):format(
            table.concat(matches, "/"), #obsLines))
    elseif matches[1] == s.precisionK then
        self.log("EdgeMap: VERDICT -> live matches the READ variant k=" .. matches[1] .. ". The prune model is "
            .. "fine here; the disagreement is elsewhere (geometry, selection, or a transient misread).")
    else
        self.log(("EdgeMap: VERDICT -> WRONG COUNT. Live matches variant k=%d but we read k=%s. The driver's "
            .. "variant sweep recovers this lock."):format(matches[1], tostring(s.precisionK)))
    end
end

return EdgeMap
