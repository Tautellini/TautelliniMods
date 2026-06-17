-- test_policy.lua  --  the shipped next-move LOOKUP end to end.
--
-- Proves the Lua side of the precompute: util.bytes reconstructs the shipped data
-- (an integer array), util.inflate decodes the DEFLATE blobs, nextmove.policy encodes
-- the live state and looks up the move, and following that move from random states always
-- reaches the goal. The offline generator + inflate byte-exactness are validated
-- separately (tools/validate_policies.py, tools/dump_hashes.lua); this is the
-- in-engine-runtime (Lua 5.4) proof of the open/encode/lookup/decode path.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local Policy = require("nextmove.policy")
local Graphs = require("data.lockgraphs")
local Index = require("data.lockpolicies_index")

-- the shipped data (integer array) + a reader (offsets in the index are 0-based)
local bin = require("util.bytes").fromInts(require("data.lockpolicies"))
local function readBlob(off, len) return bin:sub(off + 1, off + len) end

local policy = Policy.new({ index = Index, readBlob = readBlob })

-- apply move (piece x by dir d) under an edge set; returns new rots or nil if the
-- atomic move would push any piece off the rail. rots/edges are 0-indexed.
local function applyMove(rots, x, d, edges, n)
    local nr = {}
    for i = 0, n - 1 do nr[i] = rots[i] end
    nr[x] = nr[x] + d
    for _, e in ipairs(edges[x] or {}) do nr[e.b] = nr[e.b] + d * e.dir end
    for i = 0, n - 1 do if nr[i] < -3 or nr[i] > 3 then return nil end end
    return nr
end

-- the live edge set for precision k = authored connections minus the first k
local function buildEdges(conns, k, n)
    local edges = {}
    for i = 0, n - 1 do edges[i] = {} end
    for i = k + 1, #conns do
        local c = conns[i]
        edges[c.a][#edges[c.a] + 1] = { b = c.b, dir = c.dir }
    end
    return edges
end

T.add("encode is base-7 (rot+3), nil off the rail", function()
    local place = { [0] = 1, [1] = 7, [2] = 49 }
    T.eq(Policy._encode({ [0] = 0, [1] = 0, [2] = 0 }, 3, place), 3 + 21 + 147)
    T.eq(Policy._encode({ [0] = 1, [1] = -1, [2] = 3 }, 3, place),
        (1 + 3) + (-1 + 3) * 7 + (3 + 3) * 49)
    T.eq(Policy._encode({ [0] = 4 }, 1, { [0] = 1 }), nil)
    T.eq(Policy._encode({ [0] = -4 }, 1, { [0] = 1 }), nil)
end)

T.add("a known lock opens and looks up", function()
    -- BT_Tower_Door_Lock is in the shipped set; opening any variant must succeed
    T.ok(policy:has("BT_Tower_Door_Lock"), "lock present in index")
    local lock = policy:open("BT_Tower_Door_Lock", 1)
    T.ok(lock ~= nil, "open precision 1")
    -- at the goal (all centered) there is no move
    local n = Index["BT_Tower_Door_Lock"].n
    local goal = {}
    for i = 0, n - 1 do goal[i] = 0 end
    T.eq(lock:move(goal), nil, "no move at goal")
end)

-- follow the looked-up move from random reachable states to the goal, across a
-- spread of locks and all three precision variants
T.add("policy reaches the goal from random states", function()
    math.randomseed(20260617)
    local names = {}
    for name in pairs(Index) do names[#names + 1] = name end
    table.sort(names)
    -- sample ~15 locks across the set (full inflation of all 1038 blobs is slow;
    -- the Python validator already covers every lock semantically)
    local stride = math.max(1, math.floor(#names / 15))
    local cases, failures = 0, 0
    for si = 1, #names, stride do
        local name = names[si]
        local n = Index[name].n
        local conns = Graphs[name].connections
        for k = 0, 2 do
            local lock = policy:open(name, k)
            if not lock then failures = failures + 1 break end
            local edges = buildEdges(conns, k, n)
            for _ = 1, 8 do
                cases = cases + 1
                local rots = {}
                for i = 0, n - 1 do rots[i] = 0 end
                for _ = 1, math.random(0, 30) do
                    local cand = {}
                    for x = 0, n - 1 do
                        for _, d in ipairs({ -1, 1 }) do
                            if applyMove(rots, x, d, edges, n) then
                                cand[#cand + 1] = { x, d }
                            end
                        end
                    end
                    if #cand > 0 then
                        local c = cand[math.random(#cand)]
                        rots = applyMove(rots, c[1], c[2], edges, n)
                    end
                end
                local steps = 0
                while true do
                    local mv = lock:move(rots)
                    if not mv then
                        for i = 0, n - 1 do
                            if rots[i] ~= 0 then failures = failures + 1 break end
                        end
                        break
                    end
                    local nr = applyMove(rots, mv.piece, mv.dir, edges, n)
                    if not nr then failures = failures + 1 break end
                    rots = nr
                    steps = steps + 1
                    if steps > 1000 then failures = failures + 1 break end
                end
            end
        end
    end
    T.ok(cases > 100, "exercised a meaningful number of cases (" .. cases .. ")")
    T.eq(failures, 0, "every followed policy reached the goal")
end)

os.exit(T.run())
