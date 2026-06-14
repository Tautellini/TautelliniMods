-- solver.lua  --  the lockpick route planner (PURE: zero UE4SS globals)
--
-- This file has NO engine dependencies. The identical file is loaded by the
-- shipped mod (under UE4SS LuaJIT) AND by the test suite (under bare luajit,
-- see ../tests/). Keep it that way: never name FindAllOf/FName/K2_*/print or
-- any UE4SS global here. Logging is an injected dependency (Solver.new opts).
--
-- The search is a MOVE-AND-PRESERVE lift of the former main.lua free
-- functions: the base-7 state encoding, the bucket head/tail deque, the
-- 1500-expansion budget slice, the 80000-expansion variant cap, the four
-- greedy variants and their order, and the route reconstruction are
-- BYTE-IDENTICAL to the original and to the Python mirrors
-- (tools/sim_planner.py, tools/sim_astar_faithful.py). Any divergence on any
-- of the 416 mined locks is a regression even if it looks cleaner.
--
-- Integer-encoded persistent greedy best-first search on h = sum of distances
-- to center. States are base-7 numbers (one digit per piece, digit =
-- rotation + 3), so successor generation is pure arithmetic: no table copies,
-- no string keys. Searches are RESUMABLE: a budget slice runs per tick and
-- progress is never repeated. Moves are ATOMIC (mover and all dragged
-- partners must stay on their rails).
--
-- A SINGLE greedy run finds a route fast but can wander catastrophically
-- (measured up to 70x the optimal length on a mined lock). The planner
-- therefore runs FOUR greedy VARIANTS and keeps the shortest route. The
-- variants differ only in tie-breaking: piece-iteration order
-- (forward/reverse) x the side a same-h bucket is popped from (LIFO/FIFO).
-- That tie-break diversity collapses the worst case to <1.7x optimal and the
-- mean to ~1.06x over all 416 locks, while every variant still always finds a
-- route. True optimality (A*) is NOT pursued: the heuristic is too weak under
-- the connection drags to solve the hardest 7-piece locks in real time
-- (300k+ states), and near-optimal-never-catastrophic is what players need.
--
-- THE SEAM (do not change): a Solver instance is nearly stateless (it holds
-- only its injected logger/debug flag). All per-lock search state and the
-- plan latches (plan, deadHypo, hypoList, confirmed, noRouteFor, noRouteEk)
-- live on the STATE passed to :plan(state) and :moveValid(state, ...), which
-- is the live Session. They MUST be read and written through that state, not
-- copied onto the Solver, or a second source of truth re-opens the
-- left-right-left-right replan oscillation that route-following exists to
-- kill. The Session owns those fields; the Solver only operates on them.

-- Capture the stdlib (and OOP primitive) refs we use as locals at load: the
-- UE4SS Lua state is shared, another mod can clobber a global mid-session.
local setmetatable = setmetatable
local ipairs, pairs = ipairs, pairs
local math, table, string = math, table, string

local Solver = {}
Solver.__index = Solver -- set ONCE at load, never mutate after this

-- opts: { log = function(msg) end | nil, debug = boolean }
function Solver.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Solver)
    self.log = opts.log or function() end -- no-op when not injected (tests)
    self.debug = opts.debug and true or false
    return self
end

local SEARCH_VARIANTS = {
    { rev = false, fifo = false },
    { rev = true,  fifo = false },
    { rev = false, fifo = true  },
    { rev = true,  fifo = true  },
}

local function buildSearch(s, skipEdge, variant)
    local n, place = s.pieceCount, s.place
    local out = {}
    for x = 0, n - 1 do
        local lst = {}
        for _, e in ipairs(s.edges[x] or {}) do
            if not (skipEdge and skipEdge.a == x and skipEdge.b == e.b) then
                -- cache the base-7 place value ON the original edge (place is constant
                -- for the session) so the hot loop reads a plain field e.pb instead of
                -- indexing place[e.b], with NO per-search table allocation
                if e.pb == nil then e.pb = place[e.b] end
                lst[#lst + 1] = e
            end
        end
        out[x] = lst
    end
    -- the goal is ALWAYS the rail center (player canon, machine-
    -- confirmed by open captures of [0,0,...] arrangements); an
    -- earlier off-center theory came from sessions whose measurements
    -- were drift-poisoned and is dead
    local gRot = 0
    local gd = gRot + 3
    local startS, goalS, h0 = 0, 0, 0
    for id = 0, n - 1 do
        local rot = s.rotStart[id] + s.sign * (s.steps[id] or 0)
        startS = startS + (rot + 3) * place[id]
        goalS = goalS + gd * place[id]
        h0 = h0 + math.abs(rot - gRot)
    end
    if startS == goalS then
        return { done = true, result = nil, atGoal = true }
    end
    local v = SEARCH_VARIANTS[variant or 1]
    -- bucket priority queue on h. Each bucket is a deque addressed by
    -- head/tail so FIFO and LIFO pops share one structure without ever
    -- nil-ing a slot (Lua's # is unreliable over holes).
    local buckets = {}
    buckets[h0] = { startS } -- only the start bucket; the rest are created lazily on push,
                             -- so a search allocates a handful of bucket tables, not 6n+1
    return {
        out = out,
        gd = gd,
        goalS = goalS,
        originS = startS,
        seen = { [startS] = 0 }, -- entering move per state; 0 = origin
        parent = {}, -- predecessor state, for route reconstruction
        buckets = buckets,
        head = { [h0] = 1 }, -- next index to pop per bucket (FIFO)
        tail = { [h0] = 1 }, -- last filled index per bucket
        minH = h0,
        maxH = 6 * n,
        rev = v.rev, fifo = v.fifo,
        expended = 0,
        done = false, result = nil,
    }
end

-- moves are packed as (piece+1)*4 + (1 if dir==+1 else 0)
local function decodeMove(p)
    return { piece = math.floor(p / 4) - 1, dir = (p % 4 == 1) and 1 or -1 }
end

-- one budget slice of a greedy variant; persistent across ticks
local function stepSearch(s, search, budget)
    if search.done then return end
    local n, place, out = s.pieceCount, s.place, search.out
    local seen, buckets, parent = search.seen, search.buckets, search.parent
    local head, tail = search.head, search.tail
    local goalS, maxH = search.goalS, search.maxH
    local gd = search.gd or 3
    local fifo = search.fifo
    local floor, abs = math.floor, math.abs
    -- iterate pieces forward or reverse per the variant; both, with the
    -- pop side, only change which equal-h state is expanded first
    local x0, x1, xs = 0, n - 1, 1
    if search.rev then x0, x1, xs = n - 1, 0, -1 end
    while budget.left > 0 do
        -- advance to the lowest non-empty bucket
        local hb = search.minH
        while (head[hb] or 1) > (tail[hb] or 0) do
            hb = hb + 1
            if hb > maxH then
                search.minH = hb
                search.done = true -- explored everything reachable
                return
            end
        end
        search.minH = hb
        local bucket = buckets[hb]
        local S
        if fifo then
            local hd = head[hb] or 1
            S = bucket[hd]
            head[hb] = hd + 1
        else
            local t = tail[hb]
            S = bucket[t]
            tail[hb] = t - 1
        end
        budget.left = budget.left - 1
        search.expended = search.expended + 1
        if search.expended > 80000 then
            search.done = true -- give up on this variant, not on the game
            return
        end
        for x = x0, x1, xs do
            local px = place[x]
            local dx = floor(S / px) % 7
            for d = -1, 1, 2 do
                local nx = dx + d
                if nx >= 0 and nx <= 6 then
                    local delta = d * px
                    local valid = true
                    local h = abs(nx - gd) - abs(dx - gd)
                    local lst = out[x]
                    for i = 1, #lst do
                        local e = lst[i]
                        local pb = e.pb -- precomputed in buildSearch (was place[e.b])
                        local db = floor(S / pb) % 7
                        local nb = db + d * e.dir
                        if nb < 0 or nb > 6 then
                            valid = false
                            break
                        end
                        delta = delta + d * e.dir * pb
                        h = h + abs(nb - gd) - abs(db - gd)
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
                            local nt = (tail[nh] or 0) + 1
                            local b = buckets[nh]
                            if not b then b = {}; buckets[nh] = b end
                            b[nt] = T
                            tail[nh] = nt
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
local function routeFromSearch(search)
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
    return route, pre
end

local function finishRoute(plan, search)
    plan.route, plan.preIndex = routeFromSearch(search)
    plan.goalS = search.goalS
    plan.finished = true
end

-- would the game accept moving x by d under the believed state and the
-- live edge model? Mirrors stepSearch validity (atomic, rail -3..3).
-- The edge model only over-approximates (authored edges, pruned but
-- never added), so model-valid implies physically valid; a refusal of
-- a model-valid move means the edge model over-pruned (or, with the
-- full set intact, that graph or measurement is wrong).
function Solver:moveValid(s, x, d)
    local rx = s.rotStart[x] + s.sign * (s.steps[x] or 0) + d
    if rx < -3 or rx > 3 then return false end
    for _, e in ipairs(s.edges[x] or {}) do
        local rb = s.rotStart[e.b] + s.sign * (s.steps[e.b] or 0) + d * e.dir
        if rb < -3 or rb > 3 then return false end
    end
    return true
end

-- planning under dead-edge uncertainty: the game removes roughly
-- LockpickPrecision connections per lock invisibly, and a phantom edge
-- can make the model reject moves reality allows. Phases: a kept
-- hypothesis first (cheap revalidation), then the full edge set, then
-- each unconfirmed edge hypothesized dead in turn. Each phase runs to
-- a DEFINITIVE conclusion across as many ticks as needed.
--
-- s is the live state (the Session). The plan latches it reads and writes
-- (plan, deadHypo, hypoList, confirmed, noRouteFor, noRouteEk) live on s;
-- this method NEVER copies them onto the Solver instance.
function Solver:plan(s)
    if s.stateUnknown then return nil end
    -- a settle can still catch a mid-glide frame; a rotation outside
    -- the rail has no base-7 digit and marks the snapshot as garbage.
    -- PAUSE (the next settle re-snaps absolutely and self-heals),
    -- never plan on it and never kill the session over it
    for id = 0, s.pieceCount - 1 do
        local r = s.rotStart[id] + s.sign * (s.steps[id] or 0)
        if r < -3 or r > 3 then return nil end
    end
    local curS = encodeCur(s)
    local ek = edgesKey(s)
    -- a definitive no-route verdict holds until the state or the edge
    -- model changes; without the latch the sweep would re-run on
    -- every tick
    if s.noRouteFor == curS and s.noRouteEk == ek then return nil end
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
    -- small slices: never hold the game thread long (a sustained 100ms+
    -- stall once aborted the game). Greedy dives toward the goal and
    -- almost always finds it well inside one slice, so this cap rarely
    -- binds; ~1500 expansions is a few ms.
    local budget = { left = 1500 }
    while budget.left > 0 do
        if not plan.search then
            if plan.phase == "hypo0" then
                plan.search = buildSearch(s, s.deadHypo, 1)
            elseif plan.phase == "base" then
                -- run each greedy VARIANT in turn, keeping the shortest
                -- route (see SEARCH_VARIANTS): one greedy run can wander
                -- to 70x optimal, the best of four stays under 1.7x
                plan.variant = (plan.variant or 0) + 1
                plan.search = buildSearch(s, nil, plan.variant)
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
                    -- no route under the full edge set nor any single-
                    -- dead-edge hypothesis: the game removed MORE than
                    -- one connection in a way one hypothesis cannot
                    -- cover. The anchor is a direct read and not in
                    -- question. Pause for this state and model; a
                    -- prune, a restore or any move lifts the latch
                    -- and planning resumes.
                    if self.debug then
                        self.log("solver: no route fits the believed state, "
                            .. "hint paused until the edge model improves")
                    end
                    s.noRouteFor, s.noRouteEk = curS, ek
                    plan.finished = true
                    return nil
                end
                if plan.phase == "sweep" then
                    plan.search = buildSearch(s, s.hypoList[plan.hypoIdx], 1)
                end
            end
            if plan.search.atGoal then
                plan.finished = true
                return nil
            end
        end
        stepSearch(s, plan.search, budget)
        if plan.search.done then
            if plan.phase == "base" then
                -- a variant finished. Keep the shortest route across
                -- the four; commit once all are in (or earlier if a
                -- later variant hit the expansion cap with one already
                -- in hand). All variants share the same reachable set,
                -- so if the FIRST finds no route the goal is
                -- unreachable under this model: drop to the sweep.
                local hadResult = plan.search.result
                if hadResult then
                    local r, pre = routeFromSearch(plan.search)
                    if not plan.bestRoute or #r < #plan.bestRoute then
                        plan.bestRoute, plan.bestPre = r, pre
                        plan.bestGoalS = plan.search.goalS
                    end
                end
                plan.search = nil
                if not plan.bestRoute and not hadResult then
                    -- first variant exhausted with no route: the goal
                    -- is unreachable under the full edge model, try the
                    -- single-dead-edge sweep instead
                    plan.phase = "sweep"
                    plan.variant = nil
                elseif plan.variant >= #SEARCH_VARIANTS then
                    -- every variant has run: commit the shortest route
                    plan.route, plan.preIndex, plan.goalS =
                        plan.bestRoute, plan.bestPre, plan.bestGoalS
                    plan.finished = true
                    if self.debug then
                        self.log(string.format("solver: route planned, %d moves "
                            .. "(best of %d greedy variants)",
                            #plan.route, #SEARCH_VARIANTS))
                    end
                    local i = plan.preIndex[curS]
                    return i and decodeMove(plan.route[i]) or nil
                end
                -- else: more variants remain; the loop builds the next
            elseif plan.search.result then
                -- hypo0 or sweep: the first route found wins
                if plan.phase == "sweep" then
                    s.deadHypo = s.hypoList[plan.hypoIdx]
                    plan.edgesKey = edgesKey(s) -- keep the route valid
                    if self.debug then
                        self.log(string.format(
                            "solver: plan assumes edge %d->%d inactive",
                            s.deadHypo.a, s.deadHypo.b))
                    end
                end
                finishRoute(plan, plan.search)
                plan.search = nil
                if self.debug then
                    self.log(string.format("solver: route planned, %d moves",
                        #plan.route))
                end
                local i = plan.preIndex[curS]
                return i and decodeMove(plan.route[i]) or nil
            else
                -- hypo0/sweep with no route: advance the phase
                if plan.phase == "hypo0" then
                    s.deadHypo = nil
                    plan.phase = "base"
                    plan.edgesKey = edgesKey(s)
                end
                plan.search = nil
            end
        end
    end
    if self.debug then self.log("solver: planning continues next tick") end
    return nil
end

return Solver
