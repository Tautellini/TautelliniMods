-- session.lua -- the live minigame lifecycle (engine-facing class).
-- One per-lock object: MEASURES the live lock (anchor/geometry, MPC slots, settle,
-- selection glow) and answers the next move by a LOOKUP in the shipped policy for the
-- lock's precision variant -- no search, no edge-learning. Engine access only through
-- the injected pcall-wrapped facade; names no UE4SS global. main owns registration.

local setmetatable = setmetatable
local ipairs, pairs = ipairs, pairs
local tostring = tostring
local math, table, os = math, table, os

local Geometry = require("nextmove.geometry")

local Session = {}
Session.__index = Session

-- current absolute rotations (0-indexed), or nil if any pin is off the rail (a
-- garbage mid-glide read; the caller pauses and the next settle heals it).
local function currentRots(s)
    local r = {}
    for id = 0, s.pieceCount - 1 do
        local v = s.rotStart[id] + s.sign * (s.steps[id] or 0)
        if v < -3 or v > 3 then return nil end
        r[id] = v
    end
    return r
end

-- the next move by policy lookup ({piece,dir}, or nil at goal / off-rail / no policy)
local function planMove(s)
    if s.stateUnknown or not s.lockPolicy then return nil end
    local r = currentRots(s)
    if not r then return nil end
    return s.lockPolicy:move(r)
end

-- selection ground truth: the piece wearing the game's selected-look (not our tint)
-- IS selected. Input counting desyncs mid-animation; this corrects it every tick.
local function selSync(s)
    if not s.selectedSig then return end
    local sig = s.selectedSig
    local best, bestD = nil, 0.05
    for id, e in pairs(s.pieces) do
        local mid = e.mids[1]
        if mid then
            local c = s.engine.readHighlight(mid)
            if c then
                local own = s.painted[id]
                local mine = own and s.num.colorDist2(c, own) < 0.05
                if not mine and s.num.colorDist2(c, sig) < bestD then
                    best, bestD = id, s.num.colorDist2(c, sig)
                end
            end
        end
    end
    if best and best ~= s.selectedRow then
        if s.debug then
            s.log("solver: selection resynced " .. s.selectedRow .. " -> " .. best)
        end
        s.selectedRow = best
    end
end

-- update rotations from the settled slot cloud: absolute grid snap around the anchor,
-- so shakes/resets/missed settles can't drift the tracked state.
local function measureRots(s, now)
    if not (s.axis and s.cpProj) then return end
    for id = 0, s.pieceCount - 1 do
        local v = now[id]
        if v then
            s.steps[id] = Geometry.snapRot(v, s.axis, s.cpProj, s.stepSize)
                - s.rotStart[id]
        end
    end
end

-- the open arrangement should measure all-0; a mismatch is the canary for a broken
-- read path (log it, nothing to fix live).
local function verifyOpenState(s)
    if not (s.axis and s.cpProj and s.slotNow) then return end
    local rots, off = {}, false
    for id = 0, s.pieceCount - 1 do
        local v = s.slotNow[id]
        if v then
            local r = Geometry.snapRot(v, s.axis, s.cpProj, s.stepSize)
            rots[#rots + 1] = tostring(r)
            if r ~= 0 then off = true end
        else
            rots[#rots + 1] = "?"
        end
    end
    s.log("Solver: OPEN captured, rots [" .. table.concat(rots, ",")
        .. "] (0 = bar column)")
    if off then
        s.log("Solver: WARNING, open arrangement is off the bar column; the "
            .. "measurement disagrees with ground truth (a pin may have been "
            .. "mid-settle, harmless; recurring = a bug)")
    end
end

-- end the session and clear main's live-session slot
function Session:halt()
    self.stop = true
    if self.onStop then self.onStop() end
end

-- Build the session from the collected actors. Returns the session (even when
-- geometry fails: hint off, connection display still runs), nil+"retry" (too few
-- pieces), or nil+"fail" (unrecoverable read, already logged).
-- ctx: lockName, graph, precisionK, lockPolicy, actorList, engine, num, tinter,
-- handles, flags, log, debug, schedule, onStop, unreliableActors.
function Session.start(ctx)
    local log, debug = ctx.log, ctx.debug
    local engine, num = ctx.engine, ctx.num
    local graph = ctx.graph
    local pieces, found = {}, 0
    local lifeActor = nil
    for _, a in ipairs(ctx.actorList) do
        -- IsValid-gate the ACTOR before any field read: a world-wide FindAllOf can return
        -- dead pieces from a finished/already-unlocked lock, and reading a freed UObject is
        -- a native AV that pcall cannot catch. Dead actors are skipped; if too few survive
        -- the session simply does not start (no crash on an already-open chest).
        local okv, valid = pcall(function() return a and a:IsValid() end)
        local id, mid, ty, rr
        if okv and valid then
            pcall(function() id = a.m_PieceId end)
            pcall(function() mid = a.m_MaterialInstanceDynamic end)
            pcall(function() ty = tostring(a.m_LockPieceType) end)
            pcall(function() rr = a.m_RuntimeRootComponent end)
        end
        if id ~= nil then
            lifeActor = lifeActor or a
            if not pieces[id] then
                pieces[id] = { mids = {}, default = nil, parts = {} }
                found = found + 1
            end
            if mid and mid:IsValid() then
                table.insert(pieces[id].mids, mid)
                if not pieces[id].default then
                    local c = engine.readHighlight(mid)
                    if c then
                        pieces[id].default = { R = c.R, G = c.G, B = c.B, A = c.A }
                    end
                end
            end
            if ty then
                table.insert(pieces[id].parts,
                    { ty = ty, rr = rr, actor = a, mid = mid })
            end
        end
    end
    if found < 2 then return nil, "retry" end
    -- piece 0 starts selected, so its captured color is the brightened look: take the
    -- restore default from another piece, reuse piece 0's capture as the glow signature.
    local selectedSig = (pieces[0] and pieces[0].default) or nil
    local commonDefault = nil
    for id, e in pairs(pieces) do
        if id ~= 0 and e.default then commonDefault = e.default; break end
    end
    if commonDefault then
        for _, e in pairs(pieces) do e.default = commonDefault end
    end
    if selectedSig and commonDefault then
        if num.colorDist2(selectedSig, commonDefault) < 0.02 then
            selectedSig = nil -- not distinctive, keep counting blind
        end
    else
        selectedSig = nil
    end
    -- reuse the handles main resolved for this open (one subsystem scan/open); scan
    -- here only if none were passed. readSlot IsValid-gates the scene, so a handle
    -- that died in the gap degrades safely.
    local lib, mpc, scene
    if ctx.handles then
        lib, mpc, scene = ctx.handles.lib, ctx.handles.mpc, ctx.handles.scene
    end
    if not lib then lib, mpc, scene = engine.mpcHandles() end
    if not lib then
        log("Lockpicking MPC not available, next-move hint off")
        return nil, "fail"
    end
    local s = setmetatable({
        lib = lib, mpc = mpc, scene = scene, lifeActor = lifeActor,
        pieces = pieces, pieceCount = #graph.pieces,
        edges = {}, rotStart = {}, steps = {},
        slotStart = {}, slotNow = {},
        sign = 1, axis = nil, nextMove = nil, tinted = {}, painted = {},
        selectedRow = 0, selectedSig = selectedSig, lastTickSel = 0,
        wasMoving = false, stop = false,
        lockName = ctx.lockName, lockPolicy = ctx.lockPolicy,
        engine = engine, num = num, tinter = ctx.tinter,
        flags = ctx.flags, log = log, debug = debug,
        schedule = ctx.schedule, onStop = ctx.onStop,
    }, Session)
    s.geometry = Geometry.new(s.pieceCount, { log = log, debug = debug })
    -- connection display edge set = authored connections minus the first precisionK
    -- (the prune rule), so it never shows a partner the game dropped
    local k = ctx.precisionK or 0
    for i = k + 1, #graph.connections do
        local c = graph.connections[i]
        s.edges[c.a] = s.edges[c.a] or {}
        table.insert(s.edges[c.a], { b = c.b, dir = c.dir })
    end
    for _, p in ipairs(graph.pieces) do
        s.rotStart[p.id] = p.rot
        s.steps[p.id] = 0
    end
    pcall(function() s.stepSize = scene.m_LockPieceTranslationStep end)
    if not s.stepSize or s.stepSize <= 0 then s.stepSize = 6.3 end
    for id = 0, s.pieceCount - 1 do
        local slot = engine.readSlot(s, id)
        if not slot then
            log("Slot_" .. id .. " unreadable, next-move hint off")
            return nil, "fail"
        end
        s.slotStart[id] = slot
        s.slotNow[id] = slot
    end
    -- gather part-root positions per (piece, type), engine-read and 45-unit-gated
    -- against the piece's own slot (a live part sits within ~28 units; stale same-id
    -- actors sit far away). The anchor math reads these, never the scene location.
    local partPos = {}
    local liveMids = {}
    for id = 0, s.pieceCount - 1 do
        partPos[id] = {}
        liveMids[id] = {}
        local slot = s.slotStart[id]
        for _, part in ipairs((pieces[id] or {}).parts or {}) do
            if part.rr then
                local p = engine.readRootPos(part)
                if p then
                    local d2 = (p[1] - slot[1]) ^ 2 + (p[2] - slot[2]) ^ 2
                        + (p[3] - slot[3]) ^ 2
                    if d2 < 45 ^ 2 then
                        local cur = partPos[id][part.ty]
                        if not cur or d2 < cur.d2 then
                            partPos[id][part.ty] = { p = p, d2 = d2 }
                        end
                        if part.mid and part.mid:IsValid() then
                            table.insert(liveMids[id], part.mid)
                        end
                    end
                end
            end
        end
    end
    -- unreliable FindAllOf set: repaint ONLY materials proven at the live slot (stale
    -- same-id actors carry dead MIDs; writing one is a native crash).
    if ctx.unreliableActors then
        for id = 0, s.pieceCount - 1 do
            if s.pieces[id] then s.pieces[id].mids = liveMids[id] end
        end
    end
    -- the rail axis/step/anchor are pure math; pcall so a fault there can't crash the
    -- minigame. Without a frame the hint is off but the connection display stays.
    local frame, geoFail
    local okGeo, errGeo = pcall(function()
        frame, geoFail = s.geometry:derive(s.slotStart, partPos)
    end)
    if okGeo and frame then
        s.axis = frame.axis
        s.sign = frame.sign
        s.stepSize = frame.stepSize
        s.cpProj = frame.cpProj
        s.screenRight = frame.screenRight
        for id = 0, s.pieceCount - 1 do s.rotStart[id] = frame.rotStart[id] end
        s.hintGeometry = true
        if debug then
            local rr = {}
            for id = 0, s.pieceCount - 1 do rr[#rr + 1] = tostring(s.rotStart[id]) end
            log("solver: live start rots [" .. table.concat(rr, ",")
                .. "] (bar-anchored), screenRight=" .. tostring(s.screenRight))
        end
    else
        if not okGeo and debug then
            log("solver: geometry read failed: " .. tostring(errGeo))
        end
        s.stateUnknown = true
        log("Solver: " .. (geoFail or "live lock state not readable")
            .. ", next-move hint disabled for this lock (connection display "
            .. "unaffected)")
    end
    s.nextMove = s.flags.nextMove and planMove(s) or nil
    return s
end

-- per-tick body (main's loop calls it): liveness, settle detection, opened epilogue,
-- re-measure + lookup, then tints (silent while driving) or the driver step.
function Session:tick()
    local s = self
    -- liveness: piece + scene actors die the moment the minigame ends. The task is
    -- the live signal for an OPENED lock (whose actors linger for minutes).
    local alive = false
    pcall(function()
        alive = s.lifeActor:IsValid() and s.scene:IsValid()
        if alive and not s.opened and s.task and s.task.obj then
            alive = s.task.obj:IsValid()
        end
    end)
    if not alive then
        pcall(function()
            if s.openSignalT and os.clock() - s.openSignalT < 3.0
                and not s.openVerified then
                s.openVerified = true
                for id = 0, s.pieceCount - 1 do
                    local v = s.engine.readSlot(s, id)
                    if v then s.slotNow[id] = v end
                end
                verifyOpenState(s)
            end
        end)
        s:halt()
        return
    end
    -- opened: actors linger; wait out the final animation, verify, restore, free.
    if s.opened then
        if os.clock() - s.opened > 2.0 then
            for id = 0, s.pieceCount - 1 do
                local v = s.engine.readSlot(s, id)
                if v then s.slotNow[id] = v end
            end
            if not s.openVerified then
                s.openVerified = true
                verifyOpenState(s)
            end
            s.nextMove = nil
            pcall(function() s.tinter:retint(s) end)
            s:halt()
        end
        return
    end
    selSync(s)
    -- read slots; wait for motion to settle before measuring
    local now, moving = {}, false
    for id = 0, s.pieceCount - 1 do
        now[id] = s.engine.readSlot(s, id)
        if now[id] and s.slotNow[id] then
            local d = math.max(math.abs(now[id][1] - s.slotNow[id][1]),
                math.abs(now[id][2] - s.slotNow[id][2]),
                math.abs(now[id][3] - s.slotNow[id][3]))
            if d > 0.2 then moving = true end
        end
    end
    s.slotNow = now
    if moving then
        -- mid-glide: never measure/plan/tint/DRIVE on an unsettled state. The driver
        -- advances once per SETTLED tick; stepping it mid-animation tripped its
        -- no-progress stop.
        s.wasMoving = true
        return
    end
    if s.wasMoving then
        s.wasMoving = false
        measureRots(s, now)
        if s.flags.nextMove and not s.autopilot then s.nextMove = planMove(s) end
    end
    s.lastTickSel = s.selectedRow
    -- mode exclusivity: while driving, the driver is the only active execution; the
    -- displays go silent (a display toggle cancels it from main).
    if s.autopilot then
        local drv = s.autopilot
        local ok, err = pcall(function() drv:step(s) end)
        if not ok then
            s.autopilot = nil
            pcall(function() drv:restoreInterp() end) -- un-crank the move animation
            pcall(function() s.tinter:retint(s) end)  -- restore displays
            s.log("Auto-solve error, disengaged: " .. tostring(err))
        end
    else
        local ok, err = pcall(function() s.tinter:retint(s) end)
        if not ok and s.debug then s.log("Tint repaint error: " .. tostring(err)) end
    end
end

-- the policy move for the live state; the driver uses it
function Session:lookupMove()
    return planMove(self)
end

-- restore every painted piece to default; the driver calls this on engage so the
-- lock looks untouched while solving
function Session:clearTints()
    for id, e in pairs(self.pieces) do
        if self.tinted[id] and e.default then
            self.engine.writeColor(e, e.default)
        end
        self.painted[id] = nil
    end
    self.tinted = {}
    self.nextMove = nil
end

-- selection tracking for the connection display (main's Up/Down hooks call this);
-- clamps at the ends, visual row = piece id.
function Session:onSelectionStep(delta)
    local s = self
    s.selectedRow = math.max(0, math.min(s.pieceCount - 1, s.selectedRow + delta))
    pcall(function() selSync(s) end)
    if s.flags.connections and not s.autopilot then
        pcall(function() s.tinter:retint(s) end)
    end
end

-- Left/Right no longer measured (the policy fixes the move); kept so main's hook wiring stays valid
function Session:onMovePress(_dir) end

-- hint toggled: when ON, defer the re-plan off the input path; when OFF, restore
function Session:onHintToggled()
    local s = self
    if s.flags.nextMove then
        if s.replanPending then return end
        s.replanPending = true
        s.schedule(50, function()
            pcall(function()
                s.replanPending = false
                if not s.stop and s.flags.nextMove and not s.autopilot then
                    s.nextMove = planMove(s)
                    s.tinter:retint(s)
                end
            end)
        end)
    else
        s.nextMove = nil
        s.tinter:retint(s)
    end
end

function Session:onConnectionsToggled()
    if not self.autopilot then self.tinter:retint(self) end
end

-- re-read the selection from the glow; the driver confirms a selection drive with it
function Session:resyncSelection()
    pcall(function() selSync(self) end)
    return self.selectedRow
end

return Session
