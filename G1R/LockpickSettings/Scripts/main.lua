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
local PartnerColorSame = colorFrom(Config.partnerColorSame,
    { R = 0.55, G = 0.10, B = 1.00, A = 1.0 })
local PartnerColorOpp  = colorFrom(Config.partnerColorOpposite,
    { R = 1.00, G = 0.15, B = 0.15, A = 1.0 })

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
    local axisDir = (s.nextMove.dir or 1) * s.sign
    if s.inputToAxis then
        -- observationally calibrated: input * inputToAxis = pin axis
        -- direction, learned from the player's own moves
        local pressRight = axisDir * s.inputToAxis > 0
        return pressRight and HintColorRight or HintColorLeft
    end
    -- uncalibrated fallback (before the first observed move): camera
    -- projection, sign set by the one session observed under the
    -- slot-cloud geometry (the first real move recalibrates exactly)
    local pressRight = axisDir * (s.screenRight or 1) > 0
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
            -- direction-coded: purple partners travel WITH the selected
            -- piece, red partners travel AGAINST it
            desired[e.b] = (e.dir == 1) and PartnerColorSame or PartnerColorOpp
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
-- ------------------------------------------------------ search machine --
-- Integer-encoded persistent bidirectional BFS. States are base-7
-- numbers (one digit per piece, digit = rotation + 3), so successor
-- generation is pure arithmetic: no table copies, no string keys,
-- roughly an order of magnitude faster than the previous BFS. Searches
-- are RESUMABLE: a budget slice runs per tick and progress is never
-- repeated (the previous design re-ran the base search every tick and
-- froze the game on hard locks). Moves are ATOMIC (mover and all
-- dragged partners must stay on their rails) and invertible, which
-- makes the bidirectional meet valid.

local function buildSearch(s, skipEdge)
    local n, place = s.pieceCount, s.place
    local out = {}
    for x = 0, n - 1 do
        local lst = {}
        for _, e in ipairs(s.edges[x] or {}) do
            if not (skipEdge and skipEdge.a == x and skipEdge.b == e.b) then
                lst[#lst + 1] = e
            end
        end
        out[x] = lst
    end
    local startS, goalS, h0 = 0, 0, 0
    for id = 0, n - 1 do
        local rot = s.rotStart[id] + s.sign * (s.steps[id] or 0)
        startS = startS + (rot + 3) * place[id]
        goalS = goalS + 3 * place[id]
        h0 = h0 + math.abs(rot)
    end
    if startS == goalS then
        return { done = true, result = nil, atGoal = true }
    end
    -- bucket priority queue on h = sum of distances to center
    local buckets = {}
    for h = 0, 3 * n do buckets[h] = {} end
    buckets[h0][1] = startS
    return {
        out = out,
        goalS = goalS,
        originS = startS,
        seen = { [startS] = 0 }, -- entering move per state; 0 = origin
        parent = {}, -- predecessor state, for route reconstruction
        buckets = buckets,
        minH = h0,
        maxH = 3 * n,
        expended = 0,
        done = false, result = nil,
    }
end

-- moves are packed as (piece+1)*4 + (1 if dir==+1 else 0)
local function decodeMove(p)
    return { piece = math.floor(p / 4) - 1, dir = (p % 4 == 1) and 1 or -1 }
end

-- greedy best-first, persistent across ticks. A hint replans after
-- every move, so ANY route beats an optimal one that costs 100-250ms
-- game-thread slices (the bidirectional BFS did exactly that and its
-- sustained stalls aborted the game). Greedy on h = sum of distances
-- to center typically reaches the goal within a few thousand states.
local function stepSearch(s, search, budget)
    if search.done then return end
    local n, place, out = s.pieceCount, s.place, search.out
    local seen, buckets = search.seen, search.buckets
    local goalS, maxH = search.goalS, search.maxH
    local floor, abs = math.floor, math.abs
    while budget.left > 0 do
        -- pop the most promising state
        local bucket = buckets[search.minH]
        local bn = #bucket
        while bn == 0 do
            search.minH = search.minH + 1
            if search.minH > maxH then
                search.done = true -- explored everything reachable
                return
            end
            bucket = buckets[search.minH]
            bn = #bucket
        end
        local S = bucket[bn]
        bucket[bn] = nil
        budget.left = budget.left - 1
        search.expended = search.expended + 1
        if search.expended > 80000 then
            search.done = true -- give up on this phase, not on the game
            return
        end
        local parent = search.parent
        for x = 0, n - 1 do
            local px = place[x]
            local dx = floor(S / px) % 7
            for d = -1, 1, 2 do
                local nx = dx + d
                if nx >= 0 and nx <= 6 then
                    local delta = d * px
                    local valid = true
                    local h = abs(nx - 3) - abs(dx - 3)
                    local lst = out[x]
                    for i = 1, #lst do
                        local e = lst[i]
                        local pb = place[e.b]
                        local db = floor(S / pb) % 7
                        local nb = db + d * e.dir
                        if nb < 0 or nb > 6 then
                            valid = false
                            break
                        end
                        delta = delta + d * e.dir * pb
                        h = h + abs(nb - 3) - abs(db - 3)
                    end
                    if valid then
                        local T = S + delta
                        if seen[T] == nil then
                            seen[T] = (x + 1) * 4 + (d > 0 and 1 or 0)
                            parent[T] = S
                            if T == goalS then
                                search.done = true
                                search.result = true
                                return
                            end
                            local nh = search.minH + h
                            -- h is the delta vs the popped state's bucket;
                            -- clamp defensively
                            if nh < 0 then nh = 0 end
                            if nh > maxH then nh = maxH end
                            local b = buckets[nh]
                            b[#b + 1] = T
                            if nh < search.minH then search.minH = nh end
                        end
                    end
                end
            end
        end
    end
end

local function encodeCur(s)
    local S = 0
    for id = 0, s.pieceCount - 1 do
        S = S + (s.rotStart[id] + s.sign * (s.steps[id] or 0) + 3) * s.place[id]
    end
    return S
end

-- identifies the edge model a plan was built for; a prune or a new
-- hypothesis invalidates routes
local function edgesKey(s)
    local ec = 0
    for _, lst in pairs(s.edges) do ec = ec + #lst end
    return ec .. "|" .. (s.deadHypo and (s.deadHypo.a .. ">" .. s.deadHypo.b) or "-")
end

-- turn a completed search into a followable route: the move sequence
-- plus a state -> position index for O(1) following
local function finishRoute(plan, search)
    local rev = {}
    local T = search.goalS
    while T ~= search.originS do
        rev[#rev + 1] = { mv = search.seen[T], pre = search.parent[T] }
        T = search.parent[T]
    end
    local route, pre = {}, {}
    for i = #rev, 1, -1 do
        local k = #route + 1
        route[k] = rev[i].mv
        pre[rev[i].pre] = k
    end
    plan.route = route
    plan.preIndex = pre
    plan.goalS = search.goalS
    plan.finished = true
end

-- planning under dead-edge uncertainty: the game removes roughly
-- LockpickPrecision connections per lock invisibly, and a phantom edge
-- can make the model reject moves reality allows. Phases: a kept
-- hypothesis first (cheap revalidation), then the full edge set, then
-- each unconfirmed edge hypothesized dead in turn. Each phase runs to
-- a DEFINITIVE conclusion across as many ticks as needed.
local function solverPlan(s)
    if s.stateUnknown then return nil end
    local curS = encodeCur(s)
    local ek = edgesKey(s)
    local plan = s.plan
    -- ROUTE FOLLOWING: a finished plan is a full route to the goal, and
    -- hints walk it move by move. This is what makes greedy hints
    -- CONSISTENT: replanning from scratch after every move oscillated
    -- (left-right-left-right on the same piece, observed); a fixed
    -- route to the goal cannot. Replan only on deviation (a move off
    -- the route, including drag mispredictions) or on a model change.
    if plan and plan.finished then
        if plan.route and plan.edgesKey == ek then
            if curS == plan.goalS then return nil end
            local i = plan.preIndex[curS]
            if i then return decodeMove(plan.route[i]) end
        end
        s.plan, plan = nil, nil -- deviated, or the model changed
    end
    if plan and (plan.edgesKey ~= ek or plan.fromS ~= curS) then
        s.plan, plan = nil, nil -- unfinished plan for a stale state
    end
    if not plan then
        plan = {
            edgesKey = ek,
            fromS = curS,
            phase = s.deadHypo and "hypo0" or "base",
            hypoIdx = 0,
            search = nil,
            finished = false,
        }
        s.plan = plan
    end
    -- small slices: sustained 100ms+ game-thread stalls abort the game
    -- (proven twice tonight); greedy usually finishes well within one
    local budget = { left = 2500 }
    while budget.left > 0 do
        if not plan.search then
            if plan.phase == "hypo0" then
                plan.search = buildSearch(s, s.deadHypo)
            elseif plan.phase == "base" then
                plan.search = buildSearch(s, nil)
            else -- sweep over unconfirmed edges
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
                repeat
                    plan.hypoIdx = plan.hypoIdx + 1
                until plan.hypoIdx > #s.hypoList
                    or not (s.confirmed and s.confirmed[s.hypoList[plan.hypoIdx].a
                        .. ">" .. s.hypoList[plan.hypoIdx].b])
                if plan.hypoIdx > #s.hypoList then
                    plan.finished = true
                    if DebugSolver then
                        log("solver: no solution under any single-dead-edge "
                            .. "hypothesis")
                    end
                    return nil
                end
                plan.search = buildSearch(s, s.hypoList[plan.hypoIdx])
            end
            if plan.search.atGoal then
                plan.finished = true
                return nil
            end
        end
        stepSearch(s, plan.search, budget)
        if plan.search.done then
            if plan.search.result then
                if plan.phase == "sweep" then
                    s.deadHypo = s.hypoList[plan.hypoIdx]
                    plan.edgesKey = edgesKey(s) -- keep the route valid
                    if DebugSolver then
                        log(string.format(
                            "solver: plan assumes edge %d->%d inactive",
                            s.deadHypo.a, s.deadHypo.b))
                    end
                end
                finishRoute(plan, plan.search)
                plan.search = nil
                if DebugSolver then
                    log(string.format("solver: route planned, %d moves",
                        #plan.route))
                end
                local i = plan.preIndex[curS]
                return i and decodeMove(plan.route[i]) or nil
            end
            -- definitive no-solution for this phase: advance. The key
            -- tracks deadHypo, so keep it in sync or the plan would be
            -- discarded and progress lost on the next call.
            if plan.phase == "hypo0" then
                s.deadHypo = nil
                plan.phase = "base"
                plan.edgesKey = edgesKey(s)
            elseif plan.phase == "base" then
                plan.phase = "sweep"
            end
            plan.search = nil
        end
    end
    if DebugSolver then log("solver: planning continues next tick") end
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
        -- calibrate the input-to-axis mapping for the hint colors: the
        -- last Left/Right press plus the mover's observed displacement
        -- pin down which input direction moves pins toward +axis
        if s.lastInput and os.clock() - s.lastInput.t < 2.0 and s.axis then
            local a, b = prev[exact], now[exact]
            if a and b then
                local dproj = (b[1] - a[1]) * s.axis[1]
                    + (b[2] - a[2]) * s.axis[2] + (b[3] - a[3]) * s.axis[3]
                if math.abs(dproj) > 2.0 then
                    local newMap = (dproj >= 0 and 1 or -1) * s.lastInput.dir
                    if s.inputToAxis ~= newMap then
                        s.inputToAxis = newMap
                        if DebugSolver then
                            log("solver: color mapping calibrated from input ("
                                .. newMap .. ")")
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
    -- resume an unfinished plan across ticks (one budget slice per tick)
    if NextMoveActive and not s.nextMove and s.plan and not s.plan.finished then
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
    -- base-7 place values for the integer-encoded search
    s.place = {}
    local pw = 1
    for id = 0, s.pieceCount - 1 do
        s.place[id] = pw
        pw = pw * 7
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
        -- SLOTS ONLY: every read through the scene actor's wrapper chain
        -- degrades under some UE4SS configurations (struct fields coming
        -- back as UObjects), while the MPC slot reads have never failed.
        -- The rail axis comes from the slot cloud (differencing
        -- adjacent-row differences cancels the row direction), and the
        -- absolute anchor is the integer offset that fits every piece
        -- on the rail, unique whenever the pieces span enough of it.
        -- The axis sign is arbitrary: the model is symmetric and the
        -- colors resolve via the camera.
        local D = {}
        for id = 0, s.pieceCount - 2 do
            local a, b = s.slotStart[id], s.slotStart[id + 1]
            D[#D + 1] = { b[1] - a[1], b[2] - a[2], b[3] - a[3] }
        end
        local best, bestLen = nil, 4.0 -- ignore sub-step noise
        for i = 1, #D do
            for j = i + 1, #D do
                local e = { D[i][1] - D[j][1], D[i][2] - D[j][2],
                    D[i][3] - D[j][3] }
                local len = math.sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3])
                if len > bestLen then
                    best, bestLen = e, len
                end
            end
        end
        local candidates = {}
        if best then
            candidates[1] = { name = "slot-cloud", v = { best[1] / bestLen,
                best[2] / bestLen, best[3] / bestLen } }
        end
        for _, cand in ipairs(candidates) do
            local axis = cand.v
            -- project once, then FIT THE STEP SIZE: the grid is slightly
            -- nonuniform and the scene's step property is unreadable in
            -- some configurations (6.3 fallback), which alone pushed the
            -- residual to 0.26 on a full-spread lock. Scan for the step
            -- that snaps the projections onto a grid.
            local ps = {}
            for id = 0, s.pieceCount - 1 do
                local sl = s.slotStart[id]
                ps[id] = sl[1] * axis[1] + sl[2] * axis[2] + sl[3] * axis[3]
            end
            local bestStep, bestWorst, bestRots, bestMin, bestMax
            local step = 5.6
            while step <= 7.0 do
                local qs, qmean = {}, 0
                for id = 0, s.pieceCount - 1 do
                    qs[id] = ps[id] / step
                    qmean = qmean + qs[id]
                end
                qmean = qmean / s.pieceCount
                local resid = {}
                for id = 0, s.pieceCount - 1 do
                    qs[id] = qs[id] - qmean
                    resid[#resid + 1] = qs[id] - math.floor(qs[id] + 0.5)
                end
                table.sort(resid)
                local c = resid[math.floor((#resid + 1) / 2)]
                local rots, worst = {}, 0
                local minR, maxR = 99, -99
                for id = 0, s.pieceCount - 1 do
                    local q = qs[id] - c
                    local rr = math.floor(q + 0.5)
                    local rs = math.abs(q - rr)
                    if rs > worst then worst = rs end
                    rots[id] = rr
                    if rr < minR then minR = rr end
                    if rr > maxR then maxR = rr end
                end
                if maxR - minR <= 6
                    and (bestWorst == nil or worst < bestWorst) then
                    bestStep, bestWorst, bestRots = step, worst, rots
                    bestMin, bestMax = minR, maxR
                end
                step = step + 0.02
            end
            if bestWorst and bestWorst <= 0.30 then
                s.stepSize = bestStep
                -- choose the offset that fits the rail; prefer the most
                -- centered arrangement, and report remaining ambiguity
                local bestK, bestSpread, nValid = nil, 99, 0
                for k = -3 - bestMin, 3 - bestMax do
                    nValid = nValid + 1
                    local spread = math.max(math.abs(bestMin + k),
                        math.abs(bestMax + k))
                    if spread < bestSpread then
                        bestSpread, bestK = spread, k
                    end
                end
                if nValid > 1 and DebugSolver then
                    log(string.format("solver: start anchor ambiguous "
                        .. "(%d candidates), picked most centered", nValid))
                end
                if bestK ~= nil then
                    s.axis = axis
                    s.axisCalibrated = true
                    s.sign = 1
                    for id = 0, s.pieceCount - 1 do
                        s.rotStart[id] = bestRots[id] + bestK
                    end
                    derived = true
                    if DebugSolver then
                        log(string.format("solver: rail axis from slot cloud "
                            .. "(step %.2f, residual %.2f, shift %+d)",
                            bestStep, bestWorst, bestK))
                    end
                    break
                end
            end
            if not derived and DebugSolver then
                log(string.format("solver: slot-cloud axis rejected "
                    .. "(best residual %.2f)", bestWorst or 99))
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
    -- Left/Right presses calibrate the input-to-axis mapping for the
    -- hint colors: fixed assumptions about camera and pin conventions
    -- contradicted themselves across sessions, observation does not
    pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:LeftPressed", function()
        pcall(function()
            local s = Session
            if s and not s.stop then
                s.lastInput = { dir = -1, t = os.clock() }
            end
        end)
    end)
    pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:RightPressed", function()
        pcall(function()
            local s = Session
            if s and not s.stop then
                s.lastInput = { dir = 1, t = os.clock() }
            end
        end)
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
