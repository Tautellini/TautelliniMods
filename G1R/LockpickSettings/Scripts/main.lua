-- LockpickSettings for Gothic 1 Remake
-- Two features, configured in config.lua:
--   1. Extra tries: when the lockpicking minigame starts and
--      LockpickDurability is at a known vanilla tier base
--      (config.baseTries), it is raised to base + config.extraTries.
--      Defaults: 2/4/6 -> 12/14/16. The durability value itself
--      identifies the skill tier: already-raised values are recognized
--      and left alone (idempotent), unknown values are left untouched
--      and logged. Nothing can stack across sessions, saves or reloads.
--   2. Next-move hint (config.showNextMove): the piece to move next is
--      tinted (green = turn left, blue = turn right), recomputed after
--      every move. The connection graphs ship in lockgraphs.lua
--      (extracted offline from the compiled AngelScript blob); all live
--      state is MEASURED: piece positions from the MPC_Lockpicking
--      material collection, rotations from scene geometry (the game
--      re-scrambles starts per attempt), the goal is the rail center.
--      A bidirectional BFS plans under the verified rules (atomic
--      moves, no freezing); runtime-removed connections are pruned from
--      observed moves and hypothesized when planning fails. The screen
--      direction for the colors is re-read from the camera every
--      repaint.
--   3. Connection display (config.showConnections): the pieces the
--      currently selected piece would drag along glow purple. Selection
--      is counted from the minigame task's engine-dispatched Up/Down
--      input handlers (keyboard AND controller) and re-anchored by the
--      identified mover on every actual move.
--      One lean poll tick (2.5x/s, cached references only, no object
--      scans) watches for settled moves and re-asserts all tints.

-- UE4SS mods share one Lua state: another mod overwriting a standard
-- global (seen in the wild: ipairs replaced by a table, crashing our
-- loops) must not break us. Capture everything we rely on as locals.
local ipairs, pairs, tostring, tonumber = ipairs, pairs, tostring, tonumber
local type, pcall, print, require = type, pcall, print, require
local math, table, string, os = math, table, string, os

local function log(msg)
    print("[LockpickSettings] " .. tostring(msg) .. "\n")
end

-- ---------------------------------------------------------------- config --
package.loaded["config"] = nil -- so UE4SS hot reload (CTRL+R) picks up edits
local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end
local BaseTries      = Config.baseTries or { untrained = 2, trained = 4, master = 6 }
local ExtraTries     = tonumber(Config.extraTries) or 10
local NextMoveActive = Config.showNextMove == true -- runtime state, default off
local ConnActive     = Config.showConnections == true -- runtime state
local HotkeyName     = Config.nextMoveHotkey
local ConnHotkeyName = Config.connectionsHotkey
local DebugSolver    = Config.debugSolver == true
local NextMoveBroken = false

package.loaded["lockgraphs"] = nil
local okGraphs, LockGraphs = pcall(require, "lockgraphs")
if not okGraphs or type(LockGraphs) ~= "table" then
    log("ERROR in lockgraphs.lua, next-move hint unavailable ("
        .. tostring(LockGraphs) .. ")")
    LockGraphs, NextMoveActive, NextMoveBroken = {}, false, true
end

-- value -> tier lookup tables, built once
local Tiers = {} -- vanilla base -> { name, target }
local Targets = {} -- boosted target -> tier name
for name, base in pairs(BaseTries) do
    local target = base + ExtraTries
    Tiers[base] = { name = name, target = target }
    Targets[target] = name
end

local function lookup(tbl, value)
    -- table keys are exact values; tolerate float fuzz
    for k, v in pairs(tbl) do
        if math.abs(value - k) < 0.001 then return v end
    end
    return nil
end

local function liveInstances(className)
    local out = {}
    local ok, found = pcall(FindAllOf, className)
    if ok and found then
        for _, obj in ipairs(found) do
            if obj:IsValid() and not string.find(obj:GetFullName(), "Default__", 1, true) then
                out[#out + 1] = obj
            end
        end
    end
    return out
end

-- ------------------------------------------------------------ attributes --
local function findPlayerAttrSet()
    for _, s in ipairs(liveInstances("AttributeSet_Lockpicking")) do
        if string.find(s:GetFullName(), "PlayerState", 1, true) then
            return s
        end
    end
    return nil
end

-- ----------------------------------------------------------------- boost --
local function boostTries()
    local attr = findPlayerAttrSet()
    if not attr then
        log("Minigame started but no player attribute set found")
        return
    end
    local dur = attr.LockpickDurability
    local cur = dur.CurrentValue
    local tier = lookup(Tiers, cur)
    if tier then
        dur.BaseValue, dur.CurrentValue = tier.target, tier.target
        log(string.format("Minigame: %s tier, tries %.0f -> %d", tier.name, cur, tier.target))
    elseif lookup(Targets, cur) then
        -- already boosted, nothing to do
    else
        log(string.format("Minigame: durability %.2f not a known tier, leaving it alone "
            .. "(check config.baseTries)", cur))
    end
end

-- ---------------------------------------------------------------- solver --
-- hint colors come from the config and encode the lock turn to make:
-- green (left) / blue (right) by default
local function colorFrom(v, fallback)
    if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
        return { R = tonumber(v[1]), G = tonumber(v[2]), B = tonumber(v[3]), A = 1.0 }
    end
    return fallback
end
local HintColorLeft  = colorFrom(Config.hintColorLeft,
    { R = 0.10, G = 1.00, B = 0.15, A = 1.0 })
local HintColorRight = colorFrom(Config.hintColorRight,
    { R = 0.15, G = 0.45, B = 1.00, A = 1.0 })
local PartnerColor   = colorFrom(Config.partnerColor,
    { R = 0.55, G = 0.10, B = 1.00, A = 1.0 })

local Session = nil -- at most one live minigame session

local function currentLockName()
    for _, cls in ipairs({ "GameplayAbilityOpen", "GameplayAbilityDoor" }) do
        for _, ab in ipairs(liveInstances(cls)) do
            if string.find(ab:GetFullName(), "PlayerState", 1, true) then
                local name
                local ok = pcall(function() name = ab.m_Lock:ToString() end)
                if ok and name and name ~= "" and name ~= "None" then return name end
            end
        end
    end
    return nil
end

local function mpcHandles()
    local lib, mpc, scene
    pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary") end)
    pcall(function() mpc = StaticFindObject("/Game/Blueprints/LockPick/MPC_Lockpicking.MPC_Lockpicking") end)
    for _, sub in ipairs(liveInstances("LockPickSubsystem")) do
        pcall(function()
            local sc = sub.m_LockSceneActor
            if sc and sc:IsValid() then scene = sc end
        end)
        if scene then break end
    end
    if lib and lib:IsValid() and mpc and mpc:IsValid() and scene then
        return lib, mpc, scene
    end
    return nil
end

local function readSlot(s, i)
    local v
    local ok = pcall(function()
        local c = s.lib:GetVectorParameterValue(s.scene, s.mpc, FName("Slot_" .. i))
        v = { c.R, c.G, c.B }
    end)
    if not ok then return nil end
    return v
end

-- NOTE: no TMap iteration anywhere. An earlier debug breadcrumb walked
-- the scene's m_RotationToBarOffset via reflection; TMap access is the
-- one operation class that can access-violate natively (pcall cannot
-- catch that), and the open rotation is a known constant (0, the rail
-- center) anyway.

local function writeColor(e, color)
    for _, mid in ipairs(e.mids) do
        pcall(function() mid:SetVectorParameterValue(FName("HighlightColor"), color) end)
    end
end

-- Lock-in model: a piece at the open rotation (rail center, rot 0) is
-- frozen. This is a MODEL fact, not an observation: the bars visually
-- track each piece's rotation continuously (m_RotationToBarOffset), so
-- bar movement carries no extra information and is not read at all
-- (an earlier bar-transition detector produced false lock-ins and
-- poisoned the step calibration).

-- re-assert the green every tick (the game's move FX rewrites the
-- channel); restore the previous target once when the target changes
-- hint color encodes the SCREEN direction of the suggested move:
-- green = move the piece left, blue = move it right. Screen mapping =
-- rail axis projected on the camera's right vector (s.screenRight).
local function hintColor(s)
    if not s.nextMove then return HintColorLeft end
    -- colors name the PLAYER INPUT: turning the lock right moves its
    -- pin LEFT (verified player knowledge), so blue (= turn right) is
    -- shown when the pin must travel screen-left.
    -- pin screen direction = dir * sign * screenRight
    local pressRight = (s.nextMove.dir or 1) * s.sign * (s.screenRight or 1) < 0
    return pressRight and HintColorRight or HintColorLeft
end

local cameraRightProj -- defined below, needed by retint

-- unified tinting, re-asserted every tick (the game's move FX rewrites
-- the channel). Layers: the hint (green/blue) outranks the partner
-- purple; the currently SELECTED piece is never written (its native
-- brightening must survive), except by the hint, which is the action
-- cue. Restores are deferred while a piece is selected.
local function retint(s)
    local desired = {}
    local selId = nil
    if ConnActive then
        selId = s.selectedRow
        for _, e in ipairs(s.edges[selId] or {}) do
            desired[e.b] = PartnerColor
        end
    end
    local hintId = (NextMoveActive and s.nextMove) and s.nextMove.piece or nil
    if hintId then
        -- refresh the screen mapping every repaint (camera blend safety)
        if s.axis then
            s.screenRight = cameraRightProj(s) or s.screenRight
        end
        desired[hintId] = hintColor(s)
    end
    local newTinted = {}
    for id, e in pairs(s.pieces) do
        local want = desired[id]
        if want then
            if id ~= selId or id == hintId then
                writeColor(e, want)
                newTinted[id] = true
            elseif s.tinted[id] then
                newTinted[id] = true -- deferred while selected
            end
        elseif s.tinted[id] then
            if id == selId then
                newTinted[id] = true -- deferred restore while selected
            elseif e.default then
                writeColor(e, e.default)
            end
        end
    end
    s.tinted = newTinted
end

-- BFS over rail states. Kept deliberately small: expansion budget low
-- enough to never hitch or build GC pressure (suspected cause of an
-- earlier abort crash); locks are designed to be solvable in few moves.
local function solverReplan(s, budget)
    if s.openRot == nil then return nil end
    budget = budget or { left = 8000 }
    local n, sign, rotStart = s.pieceCount, s.sign, s.rotStart
    local target, start, atGoal = {}, {}, true
    for id = 0, n - 1 do
        target[id] = sign * (s.openRot - rotStart[id])
        start[id] = s.steps[id] or 0
        if start[id] ~= target[id] then atGoal = false end
    end
    if atGoal then return nil end
    local function key(st)
        local p = {}
        for id = 0, n - 1 do p[#p + 1] = st[id] end
        return table.concat(p, ",")
    end
    -- successor generator. Moves are ATOMIC: if the mover or any
    -- dragged partner would leave its rail (-3..3), the game rejects
    -- the whole move. No piece ever freezes (verified live). Moves are
    -- invertible, which makes the search bidirectional below.
    local skipEdge = s.skipEdge -- dead-edge hypothesis, see solverPlan
    local function expand(st, fn)
        for x = 0, n - 1 do
            for d = -1, 1, 2 do
                local nx = st[x] + d
                if math.abs(rotStart[x] + sign * nx) <= 3 then
                    local valid = true
                    local nst = {}
                    for id = 0, n - 1 do nst[id] = st[id] end
                    nst[x] = nx
                    for _, e in ipairs(s.edges[x] or {}) do
                        if not (skipEdge and x == skipEdge.a and e.b == skipEdge.b) then
                            local np = nst[e.b] + d * e.dir
                            if math.abs(rotStart[e.b] + sign * np) > 3 then
                                valid = false
                                break
                            end
                            nst[e.b] = np
                        end
                    end
                    if valid then fn(nst, x, d) end
                end
            end
        end
    end
    -- bidirectional BFS: a forward frontier from the current state
    -- (tagged with the FIRST move) meets a backward frontier grown from
    -- the goal (tagged with the move toward the goal, inverted). This
    -- replaced a unidirectional search whose ~600ms game-thread stalls
    -- on 6-piece locks caused abort crashes.
    local fwdSeen = { [key(start)] = true } -- true = the start itself
    local bwdSeen = { [key(target)] = true } -- true = the goal itself
    local fq, fqi = { { st = start, first = nil } }, 1
    local bq, bqi = { { st = target } }, 1
    local result = nil
    local function resolveMeet(k)
        local f = fwdSeen[k]
        if type(f) == "table" then return f end
        local b = bwdSeen[k]
        if type(b) == "table" then return b end
        return nil
    end
    while result == nil do
        local fRemain, bRemain = #fq - fqi + 1, #bq - bqi + 1
        if fRemain <= 0 and bRemain <= 0 then break end
        budget.left = budget.left - 1
        if budget.left <= 0 then
            if DebugSolver then log("solver: search budget exhausted") end
            return nil
        end
        if fRemain > 0 and (bRemain <= 0 or fRemain <= bRemain) then
            local node = fq[fqi]
            fq[fqi] = false
            fqi = fqi + 1
            expand(node.st, function(nst, x, d)
                if result then return end
                local k = key(nst)
                if fwdSeen[k] == nil then
                    local first = node.first or { piece = x, dir = d }
                    fwdSeen[k] = first
                    if bwdSeen[k] then
                        result = first
                        return
                    end
                    fq[#fq + 1] = { st = nst, first = first }
                end
            end)
        else
            local node = bq[bqi]
            bq[bqi] = false
            bqi = bqi + 1
            expand(node.st, function(nst, x, d)
                if result then return end
                local k = key(nst)
                if not bwdSeen[k] then
                    -- backward edge nst -> node.st in forward terms is
                    -- the move (x, -d) from nst
                    bwdSeen[k] = { piece = x, dir = -d }
                    if fwdSeen[k] then
                        result = resolveMeet(k)
                        if result == nil then
                            -- met exactly at the start: the hint is this
                            -- backward move inverted at the start state
                            result = { piece = x, dir = -d }
                        end
                        return
                    end
                    bq[#bq + 1] = { st = nst }
                end
            end)
        end
    end
    if result then return result end
    if DebugSolver then log("solver: no solution under current model") end
    return nil
end

-- planning under dead-edge uncertainty: the game removes roughly
-- LockpickPrecision connections per lock invisibly, and a phantom edge
-- can make our model reject moves reality allows (e.g. a phantom
-- partner sitting at its rail end). If the full edge set yields no
-- plan, hypothesize each unconfirmed edge dead and keep the first
-- hypothesis that works; actual observations prune for real later.
local function solverPlan(s)
    -- never plan against an unknown state: when live geometry could not
    -- be derived, the fallback positions may be garbage (re-scrambled
    -- lock) and planning would burn full budgets every tick
    if s.stateUnknown then return nil end
    -- one shared budget for everything this call does: an unthrottled
    -- hypothesis sweep once ran ELEVEN full searches back to back on the
    -- game thread and crashed the game
    local budget = { left = 6000 }
    if s.deadHypo then
        s.skipEdge = s.deadHypo
        local r = solverReplan(s, budget)
        s.skipEdge = nil
        if r then return r end
        s.deadHypo = nil
    end
    local r = solverReplan(s, budget)
    if r then
        s.hypoIdx = nil
        return r
    end
    -- progressive dead-edge hypothesis sweep: budget-bounded, resumes on
    -- subsequent ticks instead of stalling the game thread
    if not s.hypoList then
        s.hypoList = {}
        for a, list in pairs(s.edges) do
            for _, e in ipairs(list) do
                s.hypoList[#s.hypoList + 1] = { a = a, b = e.b }
            end
        end
        table.sort(s.hypoList, function(p, q)
            return p.a < q.a or (p.a == q.a and p.b < q.b)
        end)
    end
    local idx = s.hypoIdx or 1
    while idx <= #s.hypoList and budget.left > 0 do
        local h = s.hypoList[idx]
        idx = idx + 1
        if not (s.confirmed and s.confirmed[h.a .. ">" .. h.b]) then
            s.skipEdge = h
            local r2 = solverReplan(s, budget)
            s.skipEdge = nil
            if r2 then
                s.deadHypo = h
                s.hypoIdx = nil
                if DebugSolver then
                    log(string.format(
                        "solver: plan assumes edge %d->%d inactive", h.a, h.b))
                end
                return r2
            end
        end
    end
    s.hypoIdx = (idx <= #s.hypoList) and idx or nil
    if s.hypoIdx and DebugSolver then
        log("solver: hypothesis sweep continues next tick")
    end
    return nil
end

-- pre-move axis calibration from slot geometry: pieces sharing a start
-- rotation reveal the row-stacking direction; subtracting it from a
-- pair with different rotations isolates the rail axis WITH its sign
-- (pointing toward increasing rotation). Enables direction colors
-- before the first move; sign heuristics are skipped when this works.
local function calibrateAxis(s)
    local rowDir = nil
    for a = 0, s.pieceCount - 1 do
        for b = a + 1, s.pieceCount - 1 do
            if s.rotStart[a] == s.rotStart[b] then
                local va, vb = s.slotStart[a], s.slotStart[b]
                local v = { vb[1] - va[1], vb[2] - va[2], vb[3] - va[3] }
                local len = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
                if len > 1.0 then
                    rowDir = { v[1] / len, v[2] / len, v[3] / len }
                    break
                end
            end
        end
        if rowDir then break end
    end
    if not rowDir then return false end
    for a = 0, s.pieceCount - 1 do
        for b = 0, s.pieceCount - 1 do
            local rd = s.rotStart[a] - s.rotStart[b]
            if rd ~= 0 then
                local va, vb = s.slotStart[a], s.slotStart[b]
                local v = { va[1] - vb[1], va[2] - vb[2], va[3] - vb[3] }
                local along = v[1] * rowDir[1] + v[2] * rowDir[2] + v[3] * rowDir[3]
                local rail = { v[1] - along * rowDir[1], v[2] - along * rowDir[2],
                    v[3] - along * rowDir[3] }
                local rlen = math.sqrt(rail[1] * rail[1] + rail[2] * rail[2]
                    + rail[3] * rail[3])
                local expect = math.abs(rd) * s.stepSize
                if rlen > 1.0 and rlen > expect * 0.6 and rlen < expect * 1.4 then
                    local sgn = (rd > 0) and 1 or -1
                    s.axis = { sgn * rail[1] / rlen, sgn * rail[2] / rlen,
                        sgn * rail[3] / rlen }
                    s.sign = 1
                    s.axisCalibrated = true
                    return true
                end
            end
        end
    end
    return false
end

-- which way is "screen right" along the rail: rail axis projected on
-- the camera's right vector. Read FRESH on every repaint via a cached
-- camera manager: a single early read could capture the still-blending
-- minigame camera and invert the colors for the whole session.
function cameraRightProj(s)
    local proj = nil
    pcall(function()
        if not (s.camMgr and s.camMgr:IsValid()) then
            local pc = FindFirstOf("PlayerController")
            s.camMgr = pc.PlayerCameraManager
        end
        local rot = s.camMgr:GetCameraRotation()
        local lib = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local r = lib:GetRightVector(rot)
        proj = s.axis[1] * r.X + s.axis[2] * r.Y + s.axis[3] * r.Z
    end)
    if proj and math.abs(proj) > 0.2 then
        return proj > 0 and 1 or -1
    end
    return nil
end

-- moving X drags exactly its live out-edge partners (direct, no cascade)
local function directSet(s, x)
    local set = { [x] = true }
    for _, e in ipairs(s.edges[x] or {}) do set[e.b] = true end
    return set
end

-- update steps from observed slots; calibrate the rail axis and its
-- sign; prune edges the game evidently removed (mover identified by
-- matching the moved set against {X} + live out-edges of X)
local function processMove(s, moved, count, prev, now)
    -- mover identification with edge-state learning. An exact cover
    -- (mover's partner set == moved set) CONFIRMS those edges as active.
    -- A superset candidate implies its absent partners are dead; any
    -- candidate contradicting a confirmed edge is eliminated, and a
    -- unique survivor prunes its dead edges (the game removes roughly
    -- LockpickPrecision connections per lock at runtime, invisible
    -- until observed).
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
    if exact then
        for _, e in ipairs(s.edges[exact] or {}) do
            s.confirmed[exact .. ">" .. e.b] = true
        end
        -- the mover IS the selected piece: ground-truth selection anchor
        s.selectedRow = exact
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
            for i = #es, 1, -1 do
                if not moved[es[i].b] then
                    log(string.format("Edge %d->%d inactive this session, pruned",
                        x, es[i].b))
                    table.remove(es, i)
                end
            end
            s.selectedRow = x -- mover = selection anchor
        end
    end
    -- absolute state measurement: steps = displacement from the session
    -- start projected on the rail axis, divided by the step size. No
    -- accumulation, so rounding errors, aggregated events and RESETS
    -- cannot drift the tracked state (resets simply land wherever the
    -- pieces physically are). Step estimate refined from single-step
    -- events only.
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
            if from and cur then
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
        if DebugSolver then log("solver: rail axis sign flipped") end
    end
    -- if the axis only became known through this move, map it to the screen
    if s.axis and not s.screenRight then
        s.screenRight = cameraRightProj(s)
    end
    -- plan only while the green is shown; tracking runs regardless
    local t0 = os.clock()
    s.nextMove = NextMoveActive and solverPlan(s) or nil
    if DebugSolver and NextMoveActive then
        local ms = (os.clock() - t0) * 1000
        if ms > 100 then log(string.format("solver: replan took %.0f ms", ms)) end
    end
    if DebugSolver then
        local rots = {}
        for id = 0, s.pieceCount - 1 do
            rots[#rots + 1] = tostring(s.rotStart[id] + s.sign * (s.steps[id] or 0))
        end
        log("solver: rots now [" .. table.concat(rots, ",") .. "] (0=open)")
    end
    if DebugSolver then
        local list = {}
        for id in pairs(moved) do list[#list + 1] = id end
        table.sort(list)
        log(string.format("solver: moved {%s}, next=%s",
            table.concat(list, ","),
            s.nextMove and ("piece " .. s.nextMove.piece) or "none"))
    end
end

local function solverTick(s)
    -- liveness via the piece ACTOR and the scene actor: actors are
    -- destroyed (pending-kill) the moment the minigame ends, so the
    -- session stops within one tick. Material instances are NOT a valid
    -- liveness signal: they merely become unreferenced and only die at
    -- the next garbage collection, which once let sessions outlive the
    -- minigame and crash on the GC purge of a save load.
    local alive = false
    pcall(function()
        alive = s.lifeActor:IsValid() and s.scene:IsValid()
    end)
    if not alive then
        s.stop = true
        if Session == s then Session = nil end
        return
    end
    -- read all slots; wait for motion to settle before processing
    local now, movingNow = {}, false
    for id = 0, s.pieceCount - 1 do
        now[id] = readSlot(s, id)
        if now[id] and s.slotNow[id] then
            local d = math.max(math.abs(now[id][1] - s.slotNow[id][1]),
                math.abs(now[id][2] - s.slotNow[id][2]),
                math.abs(now[id][3] - s.slotNow[id][3]))
            if d > 0.2 then movingNow = true end
        end
    end
    local prev = s.slotNow
    s.slotNow = now
    if movingNow then
        s.wasMoving = true
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
        if count > 0 then processMove(s, moved, count, prevProcessed, now) end
    end
    -- resume a budget-paused hypothesis sweep across ticks
    if NextMoveActive and not s.nextMove and s.hypoIdx then
        s.nextMove = solverPlan(s)
    end
    retint(s)
end

-- The session ALWAYS runs while a minigame is open (state tracking is
-- cheap); the hotkey only toggles whether the green is painted. This
-- makes mid-lock activation exact: by the time the player presses the
-- key, every move has already been accounted for.
local function startSession(attempt)
    if NextMoveBroken or Session ~= nil then return end
    local lockName = currentLockName()
    local graph = lockName and LockGraphs[lockName]
    if not graph then
        if lockName then
            log("No graph data for lock '" .. lockName .. "', next-move hint off")
        end
        return
    end
    local pieces, found = {}, 0
    local lifeActor = nil
    for _, a in ipairs(liveInstances("GothicLockPieceActor")) do
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
                    pcall(function()
                        local c = mid:K2_GetVectorParameterValue(FName("HighlightColor"))
                        pieces[id].default = { R = c.R, G = c.G, B = c.B, A = c.A }
                    end)
                end
            end
            if ty and rr and rr:IsValid() then
                table.insert(pieces[id].parts, { ty = ty, rr = rr })
            end
        end
    end
    if found < 2 then
        if attempt < 6 then
            ExecuteWithDelay(500, function()
                ExecuteInGameThread(function() startSession(attempt + 1) end)
            end)
        end
        return
    end
    local lib, mpc, scene = mpcHandles()
    if not lib then
        log("Lockpicking MPC not available, next-move hint off")
        return
    end
    local s = {
        lib = lib, mpc = mpc, scene = scene, lifeActor = lifeActor,
        pieces = pieces, pieceCount = #graph.pieces,
        edges = {}, rotStart = {}, steps = {},
        slotStart = {}, slotNow = {}, slotProcessed = {},
        sign = 1, axis = nil, nextMove = nil, tinted = {},
        selectedRow = 0, -- the game starts on the bottom row = piece 0
        wasMoving = false, stop = false,
    }
    for _, c in ipairs(graph.connections) do
        s.edges[c.a] = s.edges[c.a] or {}
        table.insert(s.edges[c.a], { b = c.b, dir = c.dir })
    end
    for _, p in ipairs(graph.pieces) do
        s.rotStart[p.id] = p.rot
        s.steps[p.id] = 0
    end
    pcall(function() s.stepSize = scene.m_LockPieceTranslationStep end)
    if not s.stepSize or s.stepSize <= 0 then s.stepSize = 6.3 end
    pcall(function() s.upOff = scene.m_LockBarUpOffset end)
    pcall(function() s.downOff = scene.m_LockBarDownOffset end)
    for id = 0, s.pieceCount - 1 do
        local slot = readSlot(s, id)
        if not slot then
            log("Slot_" .. id .. " unreadable, next-move hint off")
            return
        end
        s.slotStart[id] = slot
        s.slotNow[id] = slot
        s.slotProcessed[id] = slot
    end
    -- open position = the rail center, rotation 0 (user-verified:
    -- "all pins on position 4 of 7")
    s.openRot = 0
    -- THE GAME RE-SCRAMBLES STARTING POSITIONS PER ATTEMPT (verified:
    -- a reset landed on positions unrelated to the authored ones), so
    -- mined rotations must never be trusted for the current state. The
    -- live state is read from geometry instead: the scene actor sits at
    -- the rail center and its right vector is the rail axis; each
    -- piece's rotation = (slot - center) projected on the axis / step.
    -- Mined data contributes only the connection graph (name-stable).
    local derived = false
    local okGeo, errGeo = pcall(function()
        -- transform via reflected PROPERTIES only: UFunction calls on
        -- the property-derived scene wrapper fail inside UE4SS ("Array
        -- failed invariants check"), and silently did so from day one.
        -- The scene actor is spawned unattached, so relative == world.
        local root = scene.RootComponent
        local rl = root.RelativeLocation
        local rrot = root.RelativeRotation
        local loc = { X = rl.X, Y = rl.Y, Z = rl.Z }
        -- UE FRotationMatrix axes from pitch/yaw/roll, done in Lua
        local rad = math.pi / 180.0
        local cp, sp = math.cos(rrot.Pitch * rad), math.sin(rrot.Pitch * rad)
        local cy, sy = math.cos(rrot.Yaw * rad), math.sin(rrot.Yaw * rad)
        local cr, sr = math.cos(rrot.Roll * rad), math.sin(rrot.Roll * rad)
        -- the rail axis is one of the scene's local axes, but WHICH one
        -- differs between lock placements: try forward, right and up
        local candidates = {
            { name = "forward", v = { cp * cy, cp * sy, sp } },
            { name = "right", v = { sr * sp * cy - cr * sy,
                sr * sp * sy + cr * cy, -sr * cp } },
            { name = "up", v = { -(cr * sp * cy + sr * sy),
                cy * sr - cr * sp * sy, cr * cp } },
        }
        for _, cand in ipairs(candidates) do
            local axis = cand.v
            local centerProj = loc.X * axis[1] + loc.Y * axis[2] + loc.Z * axis[3]
            -- the scene origin can sit OFF the rail center by a constant
            -- (observed: residuals fine, range check failing): align on
            -- the common fractional offset (median residual), then pick
            -- the integer shift that keeps every rotation on the rail
            local qs, resid = {}, {}
            for id = 0, s.pieceCount - 1 do
                local sl = s.slotStart[id]
                qs[id] = (sl[1] * axis[1] + sl[2] * axis[2] + sl[3] * axis[3]
                    - centerProj) / s.stepSize
                resid[#resid + 1] = qs[id] - math.floor(qs[id] + 0.5)
            end
            table.sort(resid)
            local c = resid[math.floor((#resid + 1) / 2)]
            local rots, ok2, worst = {}, true, 0
            local minR, maxR = 99, -99
            for id = 0, s.pieceCount - 1 do
                local q = qs[id] - c
                local rr = math.floor(q + 0.5)
                local rs = math.abs(q - rr)
                if rs > worst then worst = rs end
                if rs > 0.25 then
                    ok2 = false
                    break
                end
                rots[id] = rr
                if rr < minR then minR = rr end
                if rr > maxR then maxR = rr end
            end
            if ok2 then
                local bestK = nil
                for k = -3 - minR, 3 - maxR do
                    if bestK == nil or math.abs(k) < math.abs(bestK) then
                        bestK = k
                    end
                end
                if bestK ~= nil then
                    s.axis = axis
                    s.axisCalibrated = true
                    s.sign = 1
                    for id = 0, s.pieceCount - 1 do
                        s.rotStart[id] = rots[id] + bestK
                    end
                    derived = true
                    if DebugSolver then
                        log(string.format("solver: rail axis = scene %s vector "
                            .. "(residual %.2f, frac %+.2f, shift %+d)",
                            cand.name, worst, c, bestK))
                    end
                    break
                end
            end
            if not derived and DebugSolver then
                log(string.format("solver: scene %s vector rejected "
                    .. "(residual %.2f)", cand.name, worst))
            end
        end
    end)
    if derived then
        s.screenRight = cameraRightProj(s)
        if DebugSolver then
            local rr = {}
            for id = 0, s.pieceCount - 1 do rr[#rr + 1] = s.rotStart[id] end
            log("solver: live start rots [" .. table.concat(rr, ",")
                .. "] (geometric), screenRight=" .. tostring(s.screenRight))
        end
    else
        -- without measured state, hints would be planned against garbage
        -- on re-scrambled locks: disable them for this lock. The
        -- connection display only needs edges and selection and stays.
        if not okGeo and DebugSolver then
            log("solver: geometry read failed: " .. tostring(errGeo))
        end
        s.stateUnknown = true
        log("Solver: live lock state not readable, next-move hint disabled "
            .. "for this lock (connection display unaffected)")
    end
    s.nextMove = NextMoveActive and solverPlan(s) or nil
    Session = s
    retint(s)
    log(string.format("Next-move hint: %s, %d pieces, %d connections, first hint: %s",
        lockName, s.pieceCount, #graph.connections,
        s.nextMove and ("piece " .. s.nextMove.piece) or "none"))
    LoopAsync(400, function()
        if Session ~= s or s.stop then return true end
        ExecuteInGameThread(function()
            local ok, err = pcall(solverTick, s)
            if not ok then
                s.stop = true
                if Session == s then Session = nil end
                log("Next-move hint error, stopping: " .. tostring(err))
            end
        end)
        return false
    end)
end

-- ---------------------------------------------------------------- toggle --
-- toggles only the green paint; the tracking session keeps running
local function setNextMove(active)
    if NextMoveBroken then return end
    NextMoveActive = active
    log("Next-move hint " .. (active and "ON" or "OFF"))
    local s = Session
    if s and not s.stop then
        if active then
            -- defer planning OFF the input-dispatch path, and coalesce:
            -- at most one pending replan regardless of toggle spam
            if s.replanPending then return end
            s.replanPending = true
            ExecuteWithDelay(50, function()
                ExecuteInGameThread(function()
                    local ok, err = pcall(function()
                        s.replanPending = false
                        if Session == s and not s.stop and NextMoveActive then
                            local t0 = os.clock()
                            s.nextMove = solverPlan(s)
                            if DebugSolver then
                                log(string.format(
                                    "solver: toggle replan %.0f ms, hint=%s",
                                    (os.clock() - t0) * 1000,
                                    s.nextMove and ("piece " .. s.nextMove.piece)
                                    or "none"))
                            end
                            retint(s)
                        end
                    end)
                    if not ok then log("Toggle error: " .. tostring(err)) end
                end)
            end)
        else
            retint(s) -- restores the tinted piece immediately
        end
    end
end

local lastToggle = 0
if type(HotkeyName) == "string" and HotkeyName ~= "" and not NextMoveBroken then
    if Key[HotkeyName] then
        pcall(RegisterKeyBind, Key[HotkeyName], function()
            -- debounce: rapid repeats (and duplicate registrations after
            -- a hot reload) piled up 100ms planning tasks until UE4SS
            -- aborted; one toggle per 300ms is plenty
            local now = os.clock()
            if now - lastToggle < 0.3 then return end
            lastToggle = now
            ExecuteInGameThread(function()
                pcall(setNextMove, not NextMoveActive)
            end)
        end)
    else
        log("ERROR: unknown nextMoveHotkey '" .. HotkeyName .. "', hotkey disabled")
    end
end

-- selection tracking for the connection display: the minigame task's
-- Up/Down input handlers fire via engine dispatch (keyboard AND
-- controller, verified in-game); every actual piece move additionally
-- re-anchors the selection via the identified mover, so the counter
-- cannot drift for long. Starts on the bottom row, clamps at the ends
-- (both game behavior); visual row = piece id.
local lastSelStep = 0
local function onSelectionStep(delta)
    -- dedup duplicate registrations after hot reloads: those fire within
    -- the same input dispatch, real presses are never this close
    local now = os.clock()
    if now - lastSelStep < 0.03 then return end
    lastSelStep = now
    local s = Session
    if not s or s.stop then return end
    s.selectedRow = math.max(0, math.min(s.pieceCount - 1, s.selectedRow + delta))
    if ConnActive then
        pcall(retint, s)
    end
end

if not NextMoveBroken then
    pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:UpPressed", function()
        pcall(onSelectionStep, 1)
    end)
    pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:DownPressed", function()
        pcall(onSelectionStep, -1)
    end)
end

-- toggle for the connection display
local lastConnToggle = 0
if type(ConnHotkeyName) == "string" and ConnHotkeyName ~= ""
    and not NextMoveBroken then
    if Key[ConnHotkeyName] then
        pcall(RegisterKeyBind, Key[ConnHotkeyName], function()
            local now = os.clock()
            if now - lastConnToggle < 0.3 then return end
            lastConnToggle = now
            ExecuteInGameThread(function()
                local ok, err = pcall(function()
                    ConnActive = not ConnActive
                    log("Connection display " .. (ConnActive and "ON" or "OFF"))
                    local s = Session
                    if s and not s.stop then retint(s) end
                end)
                if not ok then log("Connection toggle error: " .. tostring(err)) end
            end)
        end)
    else
        log("ERROR: unknown connectionsHotkey '" .. ConnHotkeyName
            .. "', hotkey disabled")
    end
end

-- world-change backstop: if a save is loaded, kill any session WITHOUT
-- touching stored object wrappers (they may dangle after the GC purge)
pcall(RegisterInitGameStatePostHook, function()
    local s = Session
    Session = nil
    if s then s.stop = true end
end)

-- --------------------------------------------------------------- trigger --
-- The callback runs on the game thread during task construction, before
-- the minigame snapshots durability.
local okNotify, errNotify = pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick",
    function()
        local ok, err = pcall(boostTries)
        if not ok then log("Boost error: " .. tostring(err)) end
        if not NextMoveBroken then
            ExecuteWithDelay(900, function()
                ExecuteInGameThread(function()
                    local ok2, err2 = pcall(startSession, 1)
                    if not ok2 then log("Next-move hint error: " .. tostring(err2)) end
                end)
            end)
        end
    end)
if not okNotify then
    log("ERROR: could not register minigame notification: " .. tostring(errNotify))
end

local loaded = {}
for name, base in pairs(BaseTries) do
    loaded[#loaded + 1] = string.format("%s %d->%d", name, base, base + ExtraTries)
end
local graphCount = 0
for _ in pairs(LockGraphs) do graphCount = graphCount + 1 end
local hintInfo = ", next-move hint unavailable"
if not NextMoveBroken then
    hintInfo = string.format(", next-move hint %s (%d lock graphs%s)",
        NextMoveActive and "on" or "off", graphCount,
        (type(HotkeyName) == "string" and HotkeyName ~= "" and Key[HotkeyName])
        and (", toggle: " .. HotkeyName) or "")
    hintInfo = hintInfo .. string.format(", connection display %s%s",
        ConnActive and "on" or "off",
        (type(ConnHotkeyName) == "string" and ConnHotkeyName ~= ""
            and Key[ConnHotkeyName])
        and (", toggle: " .. ConnHotkeyName) or "")
end
log("Loaded: " .. table.concat(loaded, ", ") .. hintInfo)
