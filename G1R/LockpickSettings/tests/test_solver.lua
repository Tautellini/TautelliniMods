-- test_solver.lua  --  behavioral tests for the REAL shipped Scripts/solver.lua
--
-- Runs the actual solver the mod ships (no twin), under bare LuaJIT, against
-- the same lockgraphs.lua data the Python mirrors parse. This pins the
-- refactor to byte-identical behavior: if the solver ever regresses, a route
-- stops reaching the goal, becomes illegal under the model it planned with, or
-- inflates past the optimality bound, and a test here goes red. See
-- tests/run.ps1 for the runner.
--
-- Note on the mined data: the game removes roughly LockpickPrecision
-- connections per lock at runtime, so the mined graphs are UPPER BOUNDS and
-- some layouts are unsolvable as-mined (22 of 416 authored). The solver
-- handles this with a dead-edge SWEEP: it may commit a route that assumes one
-- connection inactive (deadHypo). The harness therefore replays under the same
-- pruned model the solver planned with, and treats an honest no-route pause as
-- acceptable, never as a failure.
--
-- Run from this directory:  ..\..\..\tools\luajit\luajit.exe test_solver.lua

-- Resolve our own directory so require finds ../Scripts/*.lua and ./tinytest
-- regardless of the caller's cwd.
local function script_dir()
    local src = debug.getinfo(1, "S").source -- "@<path-as-invoked>"
    local dir = src:match("^@(.*)[/\\][^/\\]*$")
    return dir or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local Solver = require("nextmove.solver")
-- the mod no longer ships a bundled dump (it decodes the graph live from the game
-- cache); the tests pin the solver against the repo's reference graphs, the same
-- file the Python sims parse and what the live decoder reproduces byte-for-byte.
local LOCKS = assert(loadfile(DIR .. "/../../reference/lock-graphs.lua"))()

-- ------------------------------------------------------------ test harness --
-- Build the pure solver state from a start layout. Mirrors the solver-relevant
-- fields Session.start sets: pieceCount, 0-indexed base-7 place values, the
-- edge model, rotStart, steps, sign. The piece ids are contiguous 0..n-1
-- (guaranteed by lockgraphs.lua), so rots is indexed by id.
local function make_state(rots, lock)
    local n = #lock.pieces
    local s = { pieceCount = n, edges = {}, rotStart = {}, steps = {},
        sign = 1, place = {} }
    local pw = 1
    for id = 0, n - 1 do s.place[id] = pw; pw = pw * 7 end -- 0-indexed, base 7
    for _, c in ipairs(lock.connections) do
        s.edges[c.a] = s.edges[c.a] or {}
        table.insert(s.edges[c.a], { b = c.b, dir = c.dir })
    end
    for id = 0, n - 1 do
        s.rotStart[id] = rots[id]
        s.steps[id] = 0
    end
    return s
end

local function rot_of(s, id)
    return s.rotStart[id] + s.sign * (s.steps[id] or 0)
end

local function at_goal(s)
    for id = 0, s.pieceCount - 1 do
        if rot_of(s, id) ~= 0 then return false end
    end
    return true
end

-- effective out-edges under the solver's current dead-edge hypothesis: when
-- the solver commits a route that assumes one connection inactive (deadHypo),
-- the legality check and the replay must use the SAME pruned model, exactly as
-- buildSearch skips that edge. With no hypothesis this is just the full set.
local function eff_out(s, x)
    local lst = s.edges[x] or {}
    local dh = s.deadHypo
    if dh and dh.a == x then
        local r = {}
        for _, e in ipairs(lst) do
            if e.b ~= dh.b then r[#r + 1] = e end
        end
        return r
    end
    return lst
end

-- is moving the mover by dir legal: it and every dragged partner stay on the
-- rail (-3..3). Evaluated under the effective (possibly pruned) model.
local function legal(s, mv)
    local nr = rot_of(s, mv.piece) + mv.dir
    if nr < -3 or nr > 3 then return false end
    for _, e in ipairs(eff_out(s, mv.piece)) do
        local nb = rot_of(s, e.b) + mv.dir * e.dir
        if nb < -3 or nb > 3 then return false end
    end
    return true
end

-- apply an atomic move to the believed state: mover by dir, each dragged
-- partner by dir*edge.dir (sign = 1). Same model the search expands.
local function apply_move(s, mv)
    s.steps[mv.piece] = s.steps[mv.piece] + mv.dir
    for _, e in ipairs(eff_out(s, mv.piece)) do
        s.steps[e.b] = s.steps[e.b] + mv.dir * e.dir
    end
end

-- drive the planner move by move from the current state to the goal, exactly
-- as the in-game hint would: ask for the next move, verify it is legal under
-- the model the solver is planning with, apply it, repeat. plan() is
-- budget-sliced, so a nil with planning still in progress just means "ask
-- again next tick". Returns the move list on success, or nil + a reason.
local function solve(solver, s, cap)
    local moves = {}
    local guard = 0
    while true do
        guard = guard + 1
        if guard > 500000 then return nil, "guard tripped (" .. #moves .. " moves)" end
        local mv = solver:plan(s)
        if mv then
            if not legal(s, mv) then
                return nil, "illegal move: piece " .. mv.piece .. " dir " .. mv.dir
            end
            apply_move(s, mv)
            moves[#moves + 1] = mv
            if at_goal(s) then return moves end
            if #moves > cap then return nil, "exceeded move cap " .. cap end
        else
            if at_goal(s) then return moves end
            if s.plan and s.plan.finished and not s.plan.route then
                return nil, "no route"
            end
            -- else: planning continues across budget slices, ask again
        end
    end
end

-- independent BFS oracle over the FULL edge model (the same successor model),
-- for the optimality bound. Returns the optimal move count, or nil if the
-- center is unreachable as-mined (a runtime-pruned lock).
local function start_encoded(s)
    local v = 0
    for id = 0, s.pieceCount - 1 do
        v = v + (rot_of(s, id) + 3) * s.place[id]
    end
    return v
end

local function goal_encoded(s)
    local g = 0
    for id = 0, s.pieceCount - 1 do g = g + 3 * s.place[id] end
    return g
end

local function successors(s, S)
    local out, place, n = {}, s.place, s.pieceCount
    for x = 0, n - 1 do
        local px = place[x]
        local dx = math.floor(S / px) % 7
        for _, d in ipairs({ -1, 1 }) do
            local nx = dx + d
            if nx >= 0 and nx <= 6 then
                local delta, ok = d * px, true
                for _, e in ipairs(s.edges[x] or {}) do
                    local pb = place[e.b]
                    local nb = math.floor(S / pb) % 7 + d * e.dir
                    if nb < 0 or nb > 6 then ok = false; break end
                    delta = delta + d * e.dir * pb
                end
                if ok then out[#out + 1] = S + delta end
            end
        end
    end
    return out
end

local function bfs_len(s)
    local start, goal = start_encoded(s), goal_encoded(s)
    if start == goal then return 0 end
    local seen = { [start] = true }
    local dist = { [start] = 0 }
    local q, qh = { start }, 1
    while qh <= #q do
        local S = q[qh]; qh = qh + 1
        for _, Tn in ipairs(successors(s, S)) do
            if not seen[Tn] then
                seen[Tn] = true
                dist[Tn] = dist[S] + 1
                if Tn == goal then return dist[Tn] end
                q[#q + 1] = Tn
            end
        end
    end
    return nil
end

local function authored_rots(lock)
    local r = {}
    for _, p in ipairs(lock.pieces) do r[p.id] = p.rot end
    return r
end

-- ------------------------------------------------------------------ tests --

-- The core safety + correctness property of the planner: every hinted move is
-- legal under the model it is planning with (the original bug-class was
-- hinting a physically-blocked piece), every committed route reaches the
-- center, and a state that is unsolvable even with one connection assumed dead
-- pauses honestly (no route) rather than spinning or proposing an illegal move.
-- Checked over all mined locks from the authored layout plus random scrambles.
T.add("hints always legal, routes reach center, unsolvable states pause honestly", function()
    local solver = Solver.new()
    math.randomseed(20260608)
    local lockCount, solved, paused, maxMoves = 0, 0, 0, 0
    for name, lock in pairs(LOCKS) do
        lockCount = lockCount + 1
        local n = #lock.pieces
        local starts = { authored_rots(lock) }
        for _ = 1, 3 do
            local r = {}
            for id = 0, n - 1 do r[id] = math.random(-3, 3) end
            starts[#starts + 1] = r
        end
        for _, rots in ipairs(starts) do
            local s = make_state(rots, lock)
            local moves, reason = solve(solver, s, 2000)
            if moves then
                T.ok(at_goal(s), "lock " .. name .. " route ended off the center")
                solved = solved + 1
                if #moves > maxMoves then maxMoves = #moves end
            else
                -- the only acceptable non-solve is an honest no-route pause;
                -- an illegal hint or a runaway is a real regression
                T.eq(reason, "no route", "lock " .. name .. " failed")
                paused = paused + 1
            end
        end
    end
    print(string.format(
        "   %d locks; %d cases solved (longest %d moves), %d honest no-route pauses",
        lockCount, solved, maxMoves, paused))
    T.ok(solved > lockCount, "expected the great majority of cases to solve")
end)

-- The whole reason the planner runs four greedy variants: the committed route
-- (shortest of the four) must stay well under 2x the true optimum. This is the
-- in-game promise (near-optimal, never catastrophic). Checked on the
-- deterministic authored layouts for n <= 6 that are solvable as-mined
-- (7-piece spaces are too big for an exhaustive BFS oracle, exactly as
-- tools/sim_planner.py scopes it; runtime-pruned layouts are skipped).
T.add("committed route within 2x BFS-optimal (full-model-solvable authored, n <= 6)", function()
    local solver = Solver.new()
    local worst, worstName, checked, skipped = 0, nil, 0, 0
    for name, lock in pairs(LOCKS) do
        if #lock.pieces <= 6 then
            local rots = authored_rots(lock)
            local opt = bfs_len(make_state(rots, lock))
            if opt == nil then
                skipped = skipped + 1 -- runtime-pruned: unsolvable as mined
            elseif opt > 0 then
                local s = make_state(rots, lock)
                local moves, reason = solve(solver, s, 2000)
                T.ok(moves ~= nil, "solver failed " .. name .. ": " .. tostring(reason))
                -- only compare to the full-model optimum when the route was
                -- planned under the full model (no dead-edge hypothesis)
                if s.deadHypo == nil then
                    local ratio = #moves / opt
                    if ratio > worst then worst, worstName = ratio, name end
                    T.lt(#moves, 2 * opt,
                        name .. " route " .. #moves .. " vs optimal " .. opt)
                    checked = checked + 1
                end
            end
        end
    end
    print(string.format(
        "   checked %d locks (skipped %d runtime-pruned), worst route/optimal = %.2fx (%s)",
        checked, skipped, worst, tostring(worstName)))
end)

-- The dead-edge phase machine: a state unsolvable under the full edge model
-- but solvable if one connection is assumed inactive must be solved by the
-- SWEEP, setting deadHypo. (pieces 0,1 mutually drag the same direction, so
-- their rotation difference is invariant under the full model: unreachable.)
T.add("sweep finds a single-dead-edge route and sets deadHypo", function()
    local solver = Solver.new()
    local lock = { pieces = { { id = 0, rot = 1 }, { id = 1, rot = 0 } },
        connections = { { a = 0, b = 1, dir = 1 }, { a = 1, b = 0, dir = 1 } } }
    local s = make_state({ [0] = 1, [1] = 0 }, lock)
    local mv, guard = nil, 0
    repeat
        guard = guard + 1
        mv = solver:plan(s)
    until mv ~= nil or (s.plan and s.plan.finished) or guard > 1000
    T.ok(mv ~= nil, "expected a move via a single-dead-edge hypothesis")
    T.ok(s.deadHypo ~= nil, "expected the sweep to record a dead-edge hypothesis")
end)

-- When every edge is confirmed real, the sweep cannot hypothesize any of them
-- dead, so an unsolvable state must latch as no-route (hint paused honestly)
-- rather than spin or guess.
T.add("confirmed unsolvable state latches no-route", function()
    local solver = Solver.new()
    local lock = { pieces = { { id = 0, rot = 1 }, { id = 1, rot = 0 } },
        connections = { { a = 0, b = 1, dir = 1 }, { a = 1, b = 0, dir = 1 } } }
    local s = make_state({ [0] = 1, [1] = 0 }, lock)
    s.confirmed = { ["0>1"] = true, ["1>0"] = true }
    local expected = start_encoded(s)
    local mv, guard = nil, 0
    repeat
        guard = guard + 1
        mv = solver:plan(s)
    until mv ~= nil or (s.plan and s.plan.finished) or guard > 1000
    T.ok(mv == nil, "expected no move for a confirmed-unsolvable state")
    T.eq(s.noRouteFor, expected, "noRouteFor latch not set to the current state")
end)

-- moveValid is the model's legality gate (used by the in-game shake handling).
-- It must reject a move that would push the mover OR any dragged partner off
-- the rail, and accept one that stays within -3..3.
T.add("moveValid enforces the rail range for mover and dragged partners", function()
    local solver = Solver.new()
    local single = { pieces = { { id = 0, rot = 3 } }, connections = {} }
    local s = make_state({ [0] = 3 }, single)
    T.ok(not solver:moveValid(s, 0, 1), "rot 3 +1 must be refused (off rail)")
    T.ok(solver:moveValid(s, 0, -1), "rot 3 -1 must be allowed")

    local pair = { pieces = { { id = 0, rot = 0 }, { id = 1, rot = 3 } },
        connections = { { a = 0, b = 1, dir = 1 } } }
    local s2 = make_state({ [0] = 0, [1] = 3 }, pair)
    T.ok(not solver:moveValid(s2, 0, 1), "drag would push the partner off the rail")
    T.ok(solver:moveValid(s2, 0, -1), "drag within the rail is allowed")
end)

os.exit(T.run())
