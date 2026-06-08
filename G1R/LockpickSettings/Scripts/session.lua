-- session.lua  --  the live minigame lifecycle (engine-facing class)
--
-- The single per-lock stateful object that was the `s` table threaded through
-- ~25 free functions. Making it a class is a pure refactor, not a redesign:
-- each method aliases `local s = self` so the bodies stay byte-faithful to the
-- original. It HAS-A Solver and a Tinter and USES Geometry + the engine facade
-- (flat composition, no base class, no __index chains in the hot loop). It OWNS
-- all measured state AND the plan latches; the Solver reads/writes those
-- through the passed `s`. MOVE-AND-PRESERVE: the measurement and edge-learning
-- logic is play-verified, do not "improve" it.
--
-- Engine access is only ever through the injected pcall-wrapped facade (or a
-- property read on an object the facade handed us); this file names no UE4SS
-- global. main.lua owns ALL registration and the notify caches and drives the
-- start orchestration (scramble gate, actor collection, scheduling); it calls
-- Session.start to build the object and arms the poll loop.

local setmetatable = setmetatable
local ipairs, pairs = ipairs, pairs
local tostring = tostring
local math, table, os, string = math, table, os, string

local Geometry = require("geometry")

local Session = {}
Session.__index = Session

-- ----------------------------------------------------- internal helpers --
-- s-threaded module locals (the original free functions): kept as locals so
-- the bodies transcribe verbatim and the methods call them unchanged.

-- moving X drags exactly its live out-edge partners (direct, no cascade)
local function directSet(s, x)
    local set = { [x] = true }
    for _, e in ipairs(s.edges[x] or {}) do set[e.b] = true end
    return set
end

-- update steps from observed slots; calibrate the rail axis and its sign;
-- prune edges the game evidently removed (mover identified by matching the
-- moved set against {X} + live out-edges of X)
local function processMove(s, moved, count, prev, now)
    -- pressesSinceMove is consumed by the calibration below and only reset at
    -- the END of this function
    -- mover identification with edge-state learning. An exact cover (mover's
    -- partner set == moved set) CONFIRMS those edges as active. A superset
    -- candidate implies its absent partners are dead; any candidate
    -- contradicting a confirmed edge is eliminated, and a unique survivor
    -- prunes its dead edges (the game removes roughly LockpickPrecision
    -- connections per lock at runtime, invisible until observed).
    s.confirmed = s.confirmed or {}
    local exact, supers = nil, {}
    for x in pairs(moved) do
        local ds = directSet(s, x)
        local covers = true
        for id in pairs(moved) do
            if not ds[id] then covers = false break end
        end
        if covers then
            local nds = 0
            for _ in pairs(ds) do nds = nds + 1 end
            if nds == count then
                exact = (exact == nil) and x or false -- false = ambiguous
            else
                supers[#supers + 1] = x
            end
        end
    end
    -- the selection read makes the mover KNOWN rather than inferred: use it to
    -- resolve the ambiguous cases. ONLY when the glow read is stable across
    -- ticks: it flaps between paired rows around move animations, and a flapped
    -- resolution once pruned a REAL connection (the planner then hinted a
    -- totally blocked piece, seen in-game)
    if s.selectedSig and moved[s.selectedRow]
        and s.selectedRow == s.lastTickSel then
        local sel = s.selectedRow
        if exact == false then
            local ds = directSet(s, sel)
            local covers, nds = true, 0
            for id in pairs(moved) do
                if not ds[id] then covers = false break end
            end
            if covers then
                for _ in pairs(ds) do nds = nds + 1 end
                if nds == count then exact = sel end
            end
        elseif exact == nil and #supers > 1 then
            for _, x in ipairs(supers) do
                if x == sel then
                    supers = { sel }
                    break
                end
            end
        end
    end
    if exact then
        for _, e in ipairs(s.edges[exact] or {}) do
            s.confirmed[exact .. ">" .. e.b] = true
        end
        -- the mover IS the selected piece: ground-truth selection anchor
        s.selectedRow = exact
        -- calibrate the input-to-axis mapping for the hint colors: the last
        -- Left/Right press plus the mover's observed displacement pin down
        -- which input direction moves pins toward +axis. ONLY from single-piece
        -- moves with exactly one press behind them: dragged pairs make the
        -- mover ambiguous and the glow read flaps between the pair, so
        -- calibrating off a partner kept flipping the mapping in-game; stale
        -- presses from fast play did the same. The ONLY color mechanism besides
        -- the deterministic camera rule: a MEASUREMENT from a clean single-press
        -- single-piece move.
        if s.lastInput and os.clock() - s.lastInput.t < 2.0 and s.axis
            and s.pressesSinceMove == 1 and count == 1 then
            local a, b = prev[exact], now[exact]
            if a and b then
                local dproj = (b[1] - a[1]) * s.axis[1]
                    + (b[2] - a[2]) * s.axis[2] + (b[3] - a[3]) * s.axis[3]
                if math.abs(dproj) > 2.0 then
                    local newMap = (dproj >= 0 and 1 or -1) * s.lastInput.dir
                    if s.inputToAxis ~= newMap then
                        s.inputToAxis = newMap
                        if s.debug then
                            s.log("solver: color mapping calibrated from input ("
                                .. newMap .. ")")
                        end
                        -- the measured truth must agree with the stage rule; a
                        -- mismatch means the colors were wrong until this move
                        -- and the stage constant needs a second look. Say it
                        -- loudly, always.
                        if s.screenRight and s.screenRight ~= newMap then
                            s.log("Solver: WARNING, measured press mapping "
                                .. "contradicts the stage geometry rule; "
                                .. "colors corrected from this move on, "
                                .. "please report this lock")
                        end
                    end
                end
            end
        end
    elseif exact == nil and #supers > 0 then
        local viable = {}
        for _, x in ipairs(supers) do
            local consistent = true
            for _, e in ipairs(s.edges[x] or {}) do
                if not moved[e.b] and s.confirmed[x .. ">" .. e.b] then
                    consistent = false
                    break
                end
            end
            if consistent then viable[#viable + 1] = x end
        end
        if #viable == 1 then
            local x = viable[1]
            local es = s.edges[x]
            local pruned = false
            for i = #es, 1, -1 do
                if not moved[es[i].b] then
                    s.log(string.format("Edge %d->%d inactive this session, pruned",
                        x, es[i].b))
                    -- journal every prune: an unexplainable refused move later
                    -- means a prune was wrong and restores them all
                    s.prunedLog = s.prunedLog or {}
                    table.insert(s.prunedLog,
                        { a = x, b = es[i].b, dir = es[i].dir })
                    table.remove(es, i)
                    pruned = true
                end
            end
            s.selectedRow = x -- mover = selection anchor
            if pruned then
                -- the sweep list mirrors the edge set; a stale entry could
                -- hypothesize a no-longer-existing edge dead. A better edge
                -- model also lifts the no-route latch: what had no route may
                -- have one now
                s.hypoList = nil
                s.noRouteFor, s.noRouteEk = nil, nil
            end
        end
    end
    -- absolute state measurement: steps = displacement from the session start
    -- projected on the rail axis, divided by the step size. No accumulation, so
    -- rounding errors, aggregated events and RESETS cannot drift the tracked
    -- state. Step estimate refined from single-step events only.
    if not s.axis then
        -- fallback: axis from the direction of the first observed move
        for id in pairs(moved) do
            local a, b = prev[id], now[id]
            if a and b then
                local dx = { b[1] - a[1], b[2] - a[2], b[3] - a[3] }
                local len = math.sqrt(dx[1] * dx[1] + dx[2] * dx[2] + dx[3] * dx[3])
                if len > 3.0 then
                    s.axis = { dx[1] / len, dx[2] / len, dx[3] / len }
                    break
                end
            end
        end
    end
    if s.axis then
        for id in pairs(moved) do
            local a, b = prev[id], now[id]
            if a and b then
                local dproj = (b[1] - a[1]) * s.axis[1] + (b[2] - a[2]) * s.axis[2]
                    + (b[3] - a[3]) * s.axis[3]
                if math.floor(math.abs(dproj) / s.stepSize + 0.5) == 1
                    and math.abs(dproj) > 5.0 and math.abs(dproj) < 7.5 then
                    s.stepSize = 0.7 * s.stepSize + 0.3 * math.abs(dproj)
                end
            end
        end
        for id = 0, s.pieceCount - 1 do
            local from, cur = s.slotStart[id], now[id]
            if cur and s.cpProj then
                -- absolute grid snap around the anchored center: shakes, resets
                -- and missed settles cannot drift it
                s.steps[id] = Geometry.snapRot(cur, s.axis, s.cpProj, s.stepSize)
                    - s.rotStart[id]
            elseif from and cur then
                local proj = (cur[1] - from[1]) * s.axis[1]
                    + (cur[2] - from[2]) * s.axis[2]
                    + (cur[3] - from[3]) * s.axis[3]
                s.steps[id] = math.floor(proj / s.stepSize + 0.5)
            end
        end
    end
    -- axis sign: every absolute rotation must stay within -3..3
    local function plausible(sig)
        for id = 0, s.pieceCount - 1 do
            if math.abs(s.rotStart[id] + sig * (s.steps[id] or 0)) > 3 then
                return false
            end
        end
        return true
    end
    if not s.axisCalibrated and not plausible(s.sign) and plausible(-s.sign) then
        s.sign = -s.sign
        if s.debug then s.log("solver: rail axis sign flipped") end
    end
    -- a rotation outside the rail is a garbage snapshot: the solver pauses on it
    -- and the next settled snap self-heals. Plan only while the green is shown;
    -- tracking runs regardless
    local t0 = os.clock()
    s.nextMove = s.flags.nextMove and s.solver:plan(s) or nil
    if s.debug and s.flags.nextMove then
        local ms = (os.clock() - t0) * 1000
        if ms > 100 then s.log(string.format("solver: replan took %.0f ms", ms)) end
    end
    if s.debug then
        local rots = {}
        for id = 0, s.pieceCount - 1 do
            rots[#rots + 1] = tostring(s.rotStart[id] + s.sign * (s.steps[id] or 0))
        end
        s.log("solver: rots now [" .. table.concat(rots, ",") .. "] (0=open)")
    end
    if s.debug then
        local list = {}
        for id in pairs(moved) do list[#list + 1] = id end
        table.sort(list)
        s.log(string.format("solver: moved {%s}, next=%s",
            table.concat(list, ","),
            s.nextMove and ("piece " .. s.nextMove.piece) or "none"))
    end
    s.pressesSinceMove = 0 -- this move's presses are accounted for
end

-- selection ground truth: the piece currently wearing the game's selected-look
-- signature (excluding our own tints) IS the selected one. Input counting
-- desyncs when the game ignores presses mid-animation; this read corrects it
-- every tick, and hands the edge learner the true mover instead of an inferred
-- one.
local function selSync(s)
    if not s.selectedSig then return end
    local sig = s.selectedSig
    local best, bestD = nil, 0.05
    -- scan ALL pieces, but never let OUR OWN paint testify: a tint near the
    -- glow signature once resynced the selection onto a merely-hinted piece
    for id, e in pairs(s.pieces) do
        local mid = e.mids[1]
        if mid then
            local c = s.engine.readHighlight(mid)
            if c then
                local own = s.painted[id]
                local mine = own and s.num.colorDist2(c, own) < 0.05
                local d = s.num.colorDist2(c, sig)
                if not mine and d < bestD then
                    best, bestD = id, d
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

-- document the OPEN arrangement: the open instant is ground truth and has
-- repeatedly settled debates that drifting measurements started. With the
-- bar-column anchor every pin must measure 0 here; a mismatch is the canary for
-- a broken read path (log it loudly, nothing to fix at runtime).
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
        s.log("Solver: WARNING, open arrangement is off the bar column; "
            .. "the measurement disagrees with ground truth (a pin may "
            .. "have been mid-settle, harmless; recurring = a bug)")
    end
end

-- ------------------------------------------------------------ lifecycle --

-- end the session and clear main's live-session slot (the onStop closure only
-- nils the slot if this is still the live one). Replaces the old
-- `s.stop = true; if Session == s then Session = nil end`.
function Session:halt()
    self.stop = true
    if self.onStop then self.onStop() end
end

-- Build the session from the collected piece actors. main owns the scramble
-- gate, actor collection and scheduling and calls this. Returns the session on
-- success (even when geometry fails, in which case the hint is disabled but the
-- connection display still runs), nil + "retry" when too few pieces were found
-- (main reschedules), or nil + "fail" on an unrecoverable read (already logged).
--
-- ctx fields: lockName, graph, actorList, engine, num, solver, tinter, flags,
-- log, debug, schedule, onStop.
function Session.start(ctx)
    local log, debug = ctx.log, ctx.debug
    local engine, num = ctx.engine, ctx.num
    local graph = ctx.graph
    local pieces, found = {}, 0
    local lifeActor = nil
    for _, a in ipairs(ctx.actorList) do
        local id, mid, ty, rr
        pcall(function() id = a.m_PieceId end)
        pcall(function() mid = a.m_MaterialInstanceDynamic end)
        pcall(function() ty = tostring(a.m_LockPieceType) end)
        pcall(function() rr = a.m_RuntimeRootComponent end)
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
                -- the part ACTOR is kept for the column anchor reads at session
                -- start; rr is OPTIONAL (latch actors carry no runtime root,
                -- requiring one silently dropped them)
                table.insert(pieces[id].parts, { ty = ty, rr = rr, actor = a })
            end
        end
    end
    if found < 2 then
        return nil, "retry"
    end
    -- normalize the restore color: the game STARTS with the bottom row
    -- (piece 0) selected, so its captured color is the brightened selected
    -- look, and restoring it later would paint a phantom selection. Take the
    -- default from a piece that is NOT selected at start. That brightened
    -- capture is also a GIFT: it is the signature of the game's selected look,
    -- in a parameter we can READ, making the selection observable.
    local selectedSig = (pieces[0] and pieces[0].default) or nil
    local commonDefault = nil
    for id, e in pairs(pieces) do
        if id ~= 0 and e.default then
            commonDefault = e.default
            break
        end
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
    local lib, mpc, scene = engine.mpcHandles()
    if not lib then
        log("Lockpicking MPC not available, next-move hint off")
        return nil, "fail"
    end
    local s = setmetatable({
        lib = lib, mpc = mpc, scene = scene, lifeActor = lifeActor,
        pieces = pieces, pieceCount = #graph.pieces,
        edges = {}, rotStart = {}, steps = {},
        slotStart = {}, slotNow = {}, slotProcessed = {},
        sign = 1, axis = nil, nextMove = nil, tinted = {}, painted = {},
        selectedRow = 0, -- the game starts on the bottom row = piece 0
        selectedSig = selectedSig,
        wasMoving = false, stop = false,
        atGoalTicks = 0,
        pressesSinceMove = 0, lastTickSel = 0,
        lockName = ctx.lockName,
        -- injected collaborators and config
        engine = engine, num = num, solver = ctx.solver, tinter = ctx.tinter,
        flags = ctx.flags, log = log, debug = debug,
        schedule = ctx.schedule, onStop = ctx.onStop,
    }, Session)
    s.geometry = Geometry.new(s.pieceCount, { log = log, debug = debug })
    for _, c in ipairs(graph.connections) do
        s.edges[c.a] = s.edges[c.a] or {}
        table.insert(s.edges[c.a], { b = c.b, dir = c.dir })
    end
    for _, p in ipairs(graph.pieces) do
        s.rotStart[p.id] = p.rot
        s.steps[p.id] = 0
    end
    s.place = Geometry.placeValues(s.pieceCount) -- base-7, 0-indexed
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
        s.slotProcessed[id] = slot
    end
    -- open position = the rail center, rotation 0 (player canon). Mined
    -- rotations are never trusted for the current state: it is MEASURED. The
    -- live state comes from the MPC slots and the fixed bar/latch part columns,
    -- never from the scene location. Mined data contributes the connection
    -- graph (name-stable).
    --
    -- gather the part-root positions per (piece, type), engine-read and
    -- 45-unit-gated against the piece's own slot (a live part sits within ~28
    -- units; stale same-id actors of earlier minigames sit far away). Geometry
    -- stays pure arithmetic and receives only these number arrays.
    local partPos = {}
    for id = 0, s.pieceCount - 1 do
        partPos[id] = {}
        local slot = s.slotStart[id]
        for _, part in ipairs((pieces[id] or {}).parts or {}) do
            if part.rr then
                local p = engine.readRootPos(part)
                if p then
                    local d2 = (p[1] - slot[1]) ^ 2
                        + (p[2] - slot[2]) ^ 2
                        + (p[3] - slot[3]) ^ 2
                    local cur = partPos[id][part.ty]
                    if d2 < 45 ^ 2 and (not cur or d2 < cur.d2) then
                        partPos[id][part.ty] = { p = p, d2 = d2 }
                    end
                end
            end
        end
    end
    -- the rail axis, step and bar-column anchor are pure math: hand the slot
    -- cloud and the gated part positions to Geometry. Defensive pcall: a math
    -- error there is a bug, but must not crash the minigame.
    local derived = false
    local frame, geoFail
    local okGeo, errGeo = pcall(function()
        frame, geoFail = s.geometry:derive(s.slotStart, partPos)
    end)
    if okGeo and frame then
        s.axis = frame.axis
        s.axisCalibrated = true
        s.sign = frame.sign
        s.stepSize = frame.stepSize
        s.cpProj = frame.cpProj
        for id = 0, s.pieceCount - 1 do
            s.rotStart[id] = frame.rotStart[id]
        end
        s.hintGeometry = true
        s.screenRight = frame.screenRight
        derived = true
        if debug then
            local rr = {}
            for id = 0, s.pieceCount - 1 do rr[#rr + 1] = s.rotStart[id] end
            log("solver: live start rots [" .. table.concat(rr, ",")
                .. "] (bar-anchored), screenRight=" .. tostring(s.screenRight))
        end
    else
        -- without the bar column, hints would be planned against a guessed
        -- frame: disable them for this lock instead. The connection display
        -- only needs edges and selection and stays.
        if not okGeo and debug then
            log("solver: geometry read failed: " .. tostring(errGeo))
        end
        s.stateUnknown = true
        log("Solver: " .. (geoFail or "live lock state not readable")
            .. ", next-move hint disabled for this lock (connection "
            .. "display unaffected)")
    end
    s.nextMove = s.flags.nextMove and s.solver:plan(s) or nil
    return s
end

-- the LoopAsync poll body (armed by main): liveness via the piece ACTOR and the
-- scene actor; settle detection; the opened epilogue; shake-refusal handling;
-- the at-goal grace; then re-assert the tints.
function Session:tick()
    local s = self
    -- liveness via the piece ACTOR and the scene actor: actors are destroyed
    -- (pending-kill) the moment the minigame ends, so the session stops within
    -- one tick. Material instances are NOT a valid liveness signal: they merely
    -- become unreferenced and only die at the next GC, which once let sessions
    -- outlive the minigame and crash on the GC purge of a save load.
    local alive = false
    pcall(function()
        alive = s.lifeActor:IsValid() and s.scene:IsValid()
    end)
    if not alive then
        -- backstop: if the success hooks missed (unknown ability variant), a
        -- death moments after an open signal still verifies; the FINAL settled
        -- state is always documented.
        pcall(function()
            if s.debug then
                local rr = {}
                for id = 0, s.pieceCount - 1 do
                    rr[#rr + 1] = tostring(s.rotStart[id]
                        + s.sign * (s.steps[id] or 0))
                end
                s.log("solver: session ended, last rots ["
                    .. table.concat(rr, ",") .. "]")
            end
            if s.openSignalT and os.clock() - s.openSignalT < 3.0
                and not s.openVerified then
                s.openVerified = true
                -- refresh: the last cached read may be mid-glide
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
    -- OPENED epilogue: the win signal arrived but the actors LINGER (an opened
    -- chest's pieces stayed valid for minutes). Close the session ourselves:
    -- wait out the final animation, verify the open arrangement, restore tints,
    -- free the slot.
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
            if s.debug then s.log("solver: session closed after open") end
        end
        return
    end
    -- fresh selection truth BEFORE move processing: the learner uses it
    selSync(s)
    -- read all slots; wait for motion to settle before processing
    local now, movingNow = {}, false
    for id = 0, s.pieceCount - 1 do
        now[id] = s.engine.readSlot(s, id)
        if now[id] and s.slotNow[id] then
            local d = math.max(math.abs(now[id][1] - s.slotNow[id][1]),
                math.abs(now[id][2] - s.slotNow[id][2]),
                math.abs(now[id][3] - s.slotNow[id][3]))
            if d > 0.2 then movingNow = true end
        end
    end
    s.slotNow = now
    if movingNow then
        s.wasMoving = true
        s.atGoalTicks = 0
        return
    end
    if s.wasMoving then
        s.wasMoving = false
        -- motion just settled: diff against the last processed state
        local moved, count = {}, 0
        for id = 0, s.pieceCount - 1 do
            if now[id] and s.slotProcessed[id] then
                local d = math.max(math.abs(now[id][1] - s.slotProcessed[id][1]),
                    math.abs(now[id][2] - s.slotProcessed[id][2]),
                    math.abs(now[id][3] - s.slotProcessed[id][3]))
                if d > 1.0 then
                    moved[id] = true
                    count = count + 1
                end
            end
        end
        local prevProcessed = s.slotProcessed
        s.slotProcessed = now
        if count > 0 then
            processMove(s, moved, count, prevProcessed, now)
        elseif s.flags.nextMove and s.hintGeometry and not s.stateUnknown
            and (s.pressesSinceMove or 0) > 0 and s.lastInput
            and os.clock() - s.lastInput.t < 1.5 then
            -- motion that settled back where it started, WITH a fresh press
            -- behind it, is the game's SHAKE: a refused move, confirmed by the
            -- game itself. The press requirement keeps idle settle-wobble from
            -- fabricating refusals out of thin air.
            s.shakeRefusal = true
        end
    end
    -- canon checks while settled, only while the hint is on. The anchor is a
    -- direct read, so contradictions no longer trigger an anchor search: they
    -- heal themselves, heal the edge model, or honestly stop the hint.
    if s.flags.nextMove and s.hintGeometry and not s.stateUnknown then
        local atGoal = true
        for id = 0, s.pieceCount - 1 do
            if s.rotStart[id] + s.sign * (s.steps[id] or 0) ~= 0 then
                atGoal = false
                break
            end
        end
        if atGoal then
            s.atGoalTicks = s.atGoalTicks + 1
            -- consume a shake observed AT the goal too: leaving the flag set
            -- would let a later, unrelated settle act on it
            s.shakeRefusal = nil
            -- the lock auto-opens on the last correct move (canon) and the open
            -- animation plus signal take a moment: a long grace covers them. A
            -- lock STILL shut after the grace contradicts canon, and with the
            -- anchor a direct read there is nothing left to correct: say so and
            -- stop.
            if s.atGoalTicks >= 12 and not s.openSignalT then
                s.stateUnknown = true
                s.plan, s.nextMove = nil, nil
                s.log("Solver: pins measured centered but the lock did "
                    .. "not open, measurement distrusted, next-move "
                    .. "hint disabled for this lock (connection "
                    .. "display unaffected)")
            end
        else
            s.atGoalTicks = 0
            local shake = s.shakeRefusal
            s.shakeRefusal = nil
            -- the game-confirmed SHAKE is the ONLY refusal evidence: press
            -- counting is gone (the shake supersedes it) and nothing here may
            -- touch the colors. Only a selection STABLE across two settled
            -- ticks may testify: the glow read flaps between paired rows around
            -- move animations, and a flapped selection once convicted a healthy
            -- model.
            if shake and s.selectedRow == s.lastTickSel then
                local x, d = s.selectedRow, nil
                -- the PRESSED key mapped through the measured mapping, or
                -- through the stage geometry rule. NEVER assume the player
                -- pressed the hinted direction: a press into a physical wall is
                -- normal play.
                local m = s.inputToAxis or s.screenRight
                if m and s.lastInput
                    and os.clock() - s.lastInput.t < 2.0 then
                    d = s.lastInput.dir * m * s.sign
                end
                -- re-snap every rotation from FRESH slot reads before believing
                -- a contradiction: the settle detector can fire on a mid-glide
                -- frame. The fresh snap is the same absolute measurement
                -- processMove does.
                if s.cpProj and s.axis then
                    for id = 0, s.pieceCount - 1 do
                        local v = s.engine.readSlot(s, id)
                        if v then
                            s.steps[id] = Geometry.snapRot(
                                v, s.axis, s.cpProj, s.stepSize) - s.rotStart[id]
                        end
                    end
                end
                local refusedValid
                if d then
                    refusedValid = s.solver:moveValid(s, x, d)
                else
                    -- direction unknown on a non-hinted piece: only
                    -- both-ways-movable makes ANY press hard evidence
                    refusedValid = s.solver:moveValid(s, x, 1)
                        and s.solver:moveValid(s, x, -1)
                end
                if refusedValid then
                    -- the game refused a move the model allows. The anchor is a
                    -- direct read, so the model can only be wrong about EDGES: a
                    -- wrongly pruned connection makes the physical drag set
                    -- bigger than the model's. Restore every journaled prune and
                    -- let the learner re-prove them. With nothing to restore,
                    -- replan once and give the measurement a second chance
                    -- (strike one); only a REPEATED contradiction disables the
                    -- hint for this lock. Colors are NEVER touched here.
                    if s.prunedLog and #s.prunedLog > 0 then
                        for _, e in ipairs(s.prunedLog) do
                            s.edges[e.a] = s.edges[e.a] or {}
                            table.insert(s.edges[e.a],
                                { b = e.b, dir = e.dir })
                        end
                        s.log(string.format("Solver: refused move, "
                            .. "restored %d pruned connections",
                            #s.prunedLog))
                        s.prunedLog = {}
                        s.hypoList = nil
                        s.noRouteFor, s.noRouteEk = nil, nil
                        s.plan, s.nextMove = nil, nil
                        if s.flags.nextMove then
                            s.nextMove = s.solver:plan(s)
                        end
                    else
                        s.refusalStrikes = (s.refusalStrikes or 0) + 1
                        s.plan, s.nextMove = nil, nil
                        if s.refusalStrikes >= 2 then
                            s.stateUnknown = true
                            s.log("Solver: the game repeatedly refused "
                                .. "moves the full model allows, graph "
                                .. "or measurement wrong, next-move "
                                .. "hint disabled for this lock "
                                .. "(connection display unaffected)")
                        else
                            if s.debug then
                                s.log("solver: refused model-valid move, "
                                    .. "replanned (strike one)")
                            end
                            if s.flags.nextMove then
                                s.nextMove = s.solver:plan(s)
                            end
                        end
                    end
                end
            end
        end
    end
    -- the cross-tick selection stability gate, shared by the edge learner
    -- (processMove, next tick) and the shake testimony above: updated at the END
    -- of every settled tick, regardless of the hint toggle
    s.lastTickSel = s.selectedRow
    -- resume an unfinished plan across ticks: the four greedy variants run over
    -- a few slices, so the first hint of a freshly (re)planned lock can take a
    -- tick or two to appear
    if s.flags.nextMove and s.plan and not s.nextMove and not s.plan.finished then
        s.nextMove = s.solver:plan(s)
    end
    s.tinter:retint(s)
end

-- selection tracking for the connection display: main's Up/Down hook handlers
-- call this. Starts on the bottom row, clamps at the ends (both game behavior);
-- visual row = piece id.
function Session:onSelectionStep(delta)
    local s = self
    s.selectedRow = math.max(0, math.min(s.pieceCount - 1, s.selectedRow + delta))
    -- instant truth check: the game has already moved its glow within this very
    -- input dispatch, so read it now instead of waiting for the next tick
    pcall(function() selSync(s) end)
    if s.flags.connections then
        pcall(function() s.tinter:retint(s) end)
    end
end

-- Left/Right presses feed the color-mapping MEASUREMENT only; refusals are
-- detected from the game's own shake, never from press counting. main's
-- hook handlers call this.
function Session:onMovePress(dir)
    local s = self
    local now = os.clock()
    if now - (s.lastPressT or 0) > 0.005 then
        s.lastPressT = now
        s.pressesSinceMove = (s.pressesSinceMove or 0) + 1
    end
    s.lastInput = { dir = dir, t = now }
end

-- the next-move hotkey was toggled (main flipped s.flags.nextMove already):
-- when turning ON, defer planning OFF the input-dispatch path and coalesce at
-- most one pending replan; when turning OFF, restore the tinted piece at once.
function Session:onHintToggled()
    local s = self
    if s.flags.nextMove then
        -- coalesce: at most one pending replan regardless of toggle spam
        if s.replanPending then return end
        s.replanPending = true
        s.schedule(50, function()
            local ok, err = pcall(function()
                s.replanPending = false
                if not s.stop and s.flags.nextMove then
                    local t0 = os.clock()
                    s.nextMove = s.solver:plan(s)
                    if s.debug then
                        s.log(string.format(
                            "solver: toggle replan %.0f ms, hint=%s",
                            (os.clock() - t0) * 1000,
                            s.nextMove and ("piece " .. s.nextMove.piece)
                            or "none"))
                    end
                    s.tinter:retint(s)
                end
            end)
            if not ok then s.log("Toggle error: " .. tostring(err)) end
        end)
    else
        s.tinter:retint(s) -- restores the tinted piece immediately
    end
end

-- the connection display was toggled (main flipped s.flags.connections): just
-- re-assert the tints.
function Session:onConnectionsToggled()
    self.tinter:retint(self)
end

return Session
