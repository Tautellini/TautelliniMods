-- LockpickSettings for Gothic 1 Remake
--
-- MINIGAME CANON (player-verified 2026-06-07, see README; when an
-- observation contradicts these rules, the MEASUREMENT is wrong):
--   * 7 pin positions per piece; THE GOAL IS ALWAYS ALL PINS ON
--     POSITION 4 (center); the lock opens BY ITSELF on the last
--     correct move, no confirm input exists
--   * controls inverted: pressing LEFT moves a pin RIGHT
--   * moves are atomic: refused entirely (shake, nothing moves) if
--     the pin or any dragged partner pin would leave the rail, and a
--     refusal COSTS DURABILITY (counts as a fail)
--   * starts can equal the authored layout; breaks re-scramble
--
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
--      material collection (the one channel that has never failed),
--      snapped ABSOLUTELY onto the rail grid every settle. The goal is
--      the rail center (canon). The anchor (which column is the
--      center) comes from, in order: the remembered open position of
--      this lock, the bar/latch part columns measured by float
--      distance trilateration, part location reads, else the
--      most-centered guess hardened by pure geometry (a unique
--      candidate window IS the truth) and by evidence (a pin leaving
--      the rail, a game-refused model-valid move, a planning dead end,
--      a goal that does not open).
--      A greedy best-first search plans under the verified rules (atomic
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

-- float distance between two actors, trying the name variants
-- different UE4SS builds expose. Float returns never misdecode; the
-- call itself is the part that dies on some boots.
local function distTo(a, b)
    local ok, d = pcall(function()
        return a:GetDistanceTo(b)
    end)
    if ok and tonumber(d) then return d end
    ok, d = pcall(function()
        return a:GetSquaredDistanceTo(b)
    end)
    if ok and tonumber(d) and d >= 0 then
        return math.sqrt(d)
    end
    return nil
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
-- shown while the press direction is not yet MEASURED for this lock:
-- marks the piece to move without guessing the turn (a directional
-- coin flip sent players into walls, and refused moves cost
-- durability; never gamble on direction)
local HintColorNeutral = colorFrom(Config.hintColorNeutral,
    { R = 1.00, G = 0.95, B = 0.20, A = 1.0 })
local PartnerColorSame = colorFrom(Config.partnerColorSame,
    { R = 0.55, G = 0.10, B = 1.00, A = 1.0 })
local PartnerColorOpp  = colorFrom(Config.partnerColorOpposite,
    { R = 1.00, G = 0.15, B = 0.15, A = 1.0 })

-- GAME CONSTANT, measured in-game (a strict single-press calibration
-- in the same session and frame as the latch/bar column measurement,
-- 2026-06-07): pressing RIGHT moves the selected pin AWAY from the
-- latch side of the lock. The lock prefab, its fixed camera framing
-- and the key semantics are identical for every lock, so this one
-- constant makes the direction colors correct from the FIRST hint of
-- every session, no camera guess, no runtime learning. The runtime
-- calibration stays armed and logs the re-derived invariant so a game
-- patch flipping the controls is caught immediately.
local RightTowardLatch = -1

local Session = nil -- at most one live minigame session
local StartSnap = nil -- slot snapshot of the previous start attempt
local FreshPieces = {} -- piece actors by spawn time, see startSession

-- learned open positions: when a lock OPENS, every pin provably sits
-- on the center column, and the pins' 3D centroid at that moment is a
-- FIXED property of the chest (scramble-independent, the chest does
-- not move). Remembered per lock name, in memory and best-effort on
-- disk, it anchors every later session of that chest from the slot
-- reads alone: the one channel that has never failed on any boot,
-- while every actor-based read (locations, distances, the subsystem
-- array) proved flaky from one game launch to the next.
local LearnedAnchors = nil
local AnchorsPath = nil
local AnchorPathCandidates = {
    "ue4ss\\Mods\\LockpickSettings\\learned-anchors.txt",
    "Mods\\LockpickSettings\\learned-anchors.txt",
}
local function anchorsLoad()
    if LearnedAnchors then return end
    LearnedAnchors = {}
    for _, p in ipairs(AnchorPathCandidates) do
        local f = io.open(p, "r")
        if f then
            AnchorsPath = p
            for line in f:lines() do
                local nm, rest = string.match(line, "^(.-)|(.+)$")
                if nm then
                    local nums = {}
                    for v in string.gmatch(rest, "[-%d%.]+") do
                        nums[#nums + 1] = tonumber(v)
                    end
                    if #nums >= 3 then
                        -- one lock NAME can exist at several world
                        -- locations: keep a LIST of entries per name,
                        -- disambiguated by 3D distance at adoption
                        LearnedAnchors[nm] = LearnedAnchors[nm] or {}
                        table.insert(LearnedAnchors[nm], {
                            g = { nums[1], nums[2], nums[3] },
                            c = (#nums >= 6)
                                and { nums[4], nums[5], nums[6] } or nil,
                            ls = (#nums >= 7) and nums[7] or nil,
                        })
                    end
                end
            end
            f:close()
            return
        end
    end
    for _, p in ipairs(AnchorPathCandidates) do
        local f = io.open(p, "a")
        if f then
            f:close()
            AnchorsPath = p
            return
        end
    end
end
local function anchorsWrite()
    if not AnchorsPath then return end
    local f = io.open(AnchorsPath, "w")
    if not f then return end
    for nm, list in pairs(LearnedAnchors) do
        for _, a in ipairs(list) do
            if a.c then
                f:write(string.format("%s|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f%s\n",
                    nm, a.g[1], a.g[2], a.g[3], a.c[1], a.c[2], a.c[3],
                    a.ls and string.format("|%d", a.ls) or ""))
            else
                f:write(string.format("%s|%.3f|%.3f|%.3f\n",
                    nm, a.g[1], a.g[2], a.g[3]))
            end
        end
    end
    f:close()
end
local function anchorsSave(name, v)
    anchorsLoad()
    local list = LearnedAnchors[name] or {}
    LearnedAnchors[name] = list
    local replaced = false
    for i, e in ipairs(list) do
        local d2 = (e.g[1] - v.g[1]) ^ 2 + (e.g[2] - v.g[2]) ^ 2
            + (e.g[3] - v.g[3]) ^ 2
        -- 60 units: well over a lock's own footprint (~50), well under
        -- the distance between neighboring locks (a chest's memory once
        -- anchored the door of the same hut through a 300-unit gate)
        if d2 < 60 ^ 2 then
            list[i] = v
            replaced = true
            break
        end
    end
    if not replaced then list[#list + 1] = v end
    anchorsWrite()
end
local function anchorsDrop(name, entry)
    anchorsLoad()
    local list = LearnedAnchors[name]
    if not list then return end
    for i, e in ipairs(list) do
        if e == entry then
            table.remove(list, i)
            break
        end
    end
    anchorsWrite()
end

local FreshAbility = nil -- the most recently spawned open/door ability
local FreshTask = nil -- the CURRENT minigame task (notify-captured)

local function currentLockName()
    -- the TASK is the only object guaranteed to belong to the current
    -- minigame (we are notified of its creation); its owning Ability
    -- carries the active m_Lock. Ability objects are REUSED by the
    -- game across interactions, so both the fresh-spawn shortcut and
    -- the world scan handed a door the previous chest's lock name
    -- (wrong graph, wrong remembered anchor, impossible hints).
    if FreshTask and os.clock() - FreshTask.t < 30.0 then
        local name
        local ok = pcall(function()
            if FreshTask.obj:IsValid() then
                name = FreshTask.obj.Ability.m_Lock:ToString()
            end
        end)
        if ok and name and name ~= "" and name ~= "None" then return name end
    end
    if FreshAbility and os.clock() - FreshAbility.t < 30.0 then
        local name
        local ok = pcall(function()
            if FreshAbility.obj:IsValid() then
                name = FreshAbility.obj.m_Lock:ToString()
            end
        end)
        if ok and name and name ~= "" and name ~= "None" then return name end
    end
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

-- Pieces NEVER freeze, not even at the center (canon; an old lock-in
-- model claiming otherwise is in the graveyard). The bars visually
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
    if not s.nextMove then return HintColorNeutral end
    if s.nextMove.probe then
        -- an anchor probe: the move may click or may be refused, and
        -- either outcome teaches the solver. Neutral says so honestly
        -- instead of pretending directional certainty.
        return HintColorNeutral
    end
    local axisDir = (s.nextMove.dir or 1) * s.sign
    if s.inputToAxis then
        -- measured: input * inputToAxis = piece axis direction, from
        -- the latch geometry, the per-lock memory, or observed moves
        local pressRight = axisDir * s.inputToAxis > 0
        return pressRight and HintColorRight or HintColorLeft
    end
    -- universal game rule (player canon): the PRESS direction equals
    -- the PIECE's screen direction, so the camera right vector decides
    -- deterministically, no calibration needed. Confirmed against the
    -- measured mapping: sessions with inputToAxis -1 had screenRight
    -- -1 (press right = piece screen right). Neutral only while the
    -- minigame camera is still blending in (screenRight unreadable,
    -- under a second; every repaint refreshes it).
    if s.screenRight then
        local pressRight = axisDir * s.screenRight > 0
        return pressRight and HintColorRight or HintColorLeft
    end
    return HintColorNeutral
end

local cameraRightProj -- defined below, needed by retint

-- unified tinting, re-asserted every tick (the game's move FX rewrites
-- the channel). Layers: the hint (green/blue) outranks the partner
-- purple; the currently SELECTED piece is never written (its native
-- brightening must survive), except by the hint, which is the action
-- cue. Restores are deferred while a piece is selected.
local function retint(s)
    local desired = {}
    if ConnActive then
        for _, e in ipairs(s.edges[s.selectedRow] or {}) do
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
    -- protection keys on the OBSERVED GLOW, never on the tracked
    -- selection: deferring writes/restores for the piece we THOUGHT was
    -- selected once preserved stale hint tints (two blue pieces at
    -- once). Reading the truth per piece is cheap and self-correcting.
    -- The hint is exempt from the guard: it is the action cue and may
    -- sit on the selected piece.
    local newTinted = {}
    for id, e in pairs(s.pieces) do
        local want = desired[id]
        local isGlow = false
        if s.selectedSig and id ~= hintId and (want or s.tinted[id]) then
            local mid = e.mids[1]
            if mid then
                local okc, c = pcall(function()
                    return mid:K2_GetVectorParameterValue(FName("HighlightColor"))
                end)
                if okc and c then
                    local sg = s.selectedSig
                    local dr = c.R - sg.R
                    local dg = c.G - sg.G
                    local db = c.B - sg.B
                    if dr * dr + dg * dg + db * db < 0.05 then
                        isGlow = true
                        if id ~= s.selectedRow then
                            s.selectedRow = id -- adopt the observed truth
                        end
                    end
                end
            end
        end
        if isGlow then
            -- never paint over or "restore" the game's selected look;
            -- keep any buried tint marked so it is cleaned on deselect
            if s.tinted[id] then newTinted[id] = true end
        elseif want then
            writeColor(e, want)
            newTinted[id] = true
        elseif s.tinted[id] then
            if e.default then writeColor(e, e.default) end
        end
    end
    s.tinted = newTinted
end

-- Search over rail states. Kept deliberately small: expansion budget
-- low enough to never hitch or build GC pressure (suspected cause of
-- an earlier abort crash); locks are designed to be solvable in few
-- moves.
-- ------------------------------------------------------ search machine --
-- Integer-encoded persistent greedy best-first search. States are
-- base-7 numbers (one digit per piece, digit = rotation + 3), so
-- successor generation is pure arithmetic: no table copies, no string
-- keys. Searches are RESUMABLE: a budget slice runs per tick and
-- progress is never repeated (an earlier design re-ran the search
-- every tick and froze the game on hard locks). Moves are ATOMIC
-- (mover and all dragged partners must stay on their rails).

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
    -- the goal is ALWAYS the rail center (player canon, machine-
    -- confirmed by open captures of [0,0,...] arrangements). s.goalRot
    -- defaults to 0 and becomes nonzero only as a memory-derived
    -- per-lock safety; an earlier off-center theory came from sessions
    -- whose measurements were drift-poisoned and is dead.
    local gRot = s.goalRot or 0
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
    -- bucket priority queue on h = sum of distances to the goal column
    local buckets = {}
    for h = 0, 6 * n do buckets[h] = {} end
    buckets[h0][1] = startS
    return {
        out = out,
        gd = gd,
        goalS = goalS,
        originS = startS,
        seen = { [startS] = 0 }, -- entering move per state; 0 = origin
        parent = {}, -- predecessor state, for route reconstruction
        buckets = buckets,
        minH = h0,
        maxH = 6 * n,
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
    local gd = search.gd or 3
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
                    local h = abs(nx - gd) - abs(dx - gd)
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

-- ------------------------------------------------- anchor correction --
-- The geometric derivation in startSession recovers rotations only
-- RELATIVE to each other; the absolute anchor (which grid column is
-- the rail center) is unique only when the scramble spans the full
-- rail. Everywhere else the most-centered pick is a guess, and a wrong
-- guess routes every hint to a uniformly off-center "goal" (the
-- community reports: all pins one beside the center, lock shut, no
-- hint). Simulation over the mined graphs: ~43% of non-spanning
-- scrambles mis-anchor, error almost always exactly one column.
-- The anchor is therefore a HYPOTHESIS under evidence:
--   * a measured rotation outside -3..3 disproves it (pins physically
--     cannot leave the rail)
--   * the game refusing a model-valid move disproves it (leaving the
--     rail is the game's ONLY rejection cause, see solve_lock.py)
--   * sitting at the believed goal with the lock still shut disproves
--     it (the lock opens AT the true goal and the session dies with it)
--   * no route under any single-dead-edge hypothesis disproves it in
--     practice (a shifted frame encodes unreachable states)
-- Each disproof shifts to the nearest untried anchor that fits every
-- observation. The observed extremes only bound, never exclude, the
-- true anchor, so the loop converges while evidence keeps arriving.

local function reAnchor(s, k, why)
    for id = 0, s.pieceCount - 1 do
        s.rotStart[id] = s.rotStart[id] + k
    end
    s.obsMin, s.obsMax = s.obsMin + k, s.obsMax + k
    s.anchorShift = s.anchorShift + k
    if s.cpProj then
        -- the believed frame shifts by k: the grid center moves the
        -- other way so direct snapping lands on the new frame
        s.cpProj = s.cpProj - k * s.stepSize
    end
    s.plan, s.nextMove = nil, nil
    s.atGoalTicks = 0
    if NextMoveActive or DebugSolver then
        log(string.format("Solver: %s, start anchor shifted %+d", why, k))
    end
end

-- nearest untried shift that keeps every OBSERVED rotation on the
-- rail. Ordered by distance from the ORIGINAL anchor (the maximum
-- likelihood guess; ordering by distance from the CURRENT one walked
-- 0 -> +1 -> +2 in-game instead of trying -1 second), positive first
-- on ties (the centered guess is biased low: the spread loop in
-- startSession keeps the FIRST k on ties)
local function nextAnchorShift(s, acceptFn)
    local lo, hi = -3 - s.obsMin, 3 - s.obsMax
    for m = 0, 6 do
        for sgn = 1, -1, -2 do
            local k = m * sgn - s.anchorShift -- target cumulative m*sgn
            if k ~= 0 and k >= lo and k <= hi
                and not s.shiftTried[s.anchorShift + k]
                and (acceptFn == nil or acceptFn(k)) then
                return k
            end
        end
    end
    return nil
end

-- revivable: exhaustion caused by candidate depletion may be undone
-- when the edge model improves (a prune wipes the soft convictions);
-- broken measurement may not
local function anchorExhausted(s, revivable, why)
    -- a memory that led the session into exhaustion is disproven:
    -- drop it so the next entry of this lock starts clean
    if s.anchorFromMemory and s.memEntry and s.lockName then
        pcall(anchorsDrop, s.lockName, s.memEntry)
        s.anchorFromMemory, s.memEntry, s.goalRot = nil, nil, 0
        log("Solver: remembered open position was wrong, dropped")
    end
    s.stateUnknown = true
    s.anchorGaveUp = revivable or nil
    s.plan, s.nextMove = nil, nil
    log("Solver: open position not determinable (" .. tostring(why)
        .. "), next-move hint disabled (connection display unaffected)")
end

-- disprove the current anchor and move to the nearest viable one;
-- acceptFn optionally narrows candidates to those explaining the
-- evidence, falling back to all viable ones. Rail bounds, refused
-- moves and unopened goals convict an anchor for good ("hard"); a
-- no-route dead end only convicts it under the CURRENT edge model
-- ("soft"), because unlearned dead edges can make the model wrong
-- about reachability, and those convictions lift when a prune
-- improves the model
local function disproveAnchor(s, why, acceptFn, soft)
    s.shiftTried[s.anchorShift] = soft and "soft" or true
    local k = nextAnchorShift(s, acceptFn)
    if not k and acceptFn then k = nextAnchorShift(s, nil) end
    if not k and not s.evidenceReset then
        -- evidence can be FALSE (a flapping glow read once convicted
        -- the correct anchor in-game and killed the hint): restart the
        -- search once per lock with a clean slate instead of giving
        -- up. A wrongly cleared true conviction only costs a short
        -- re-walk; a wrongly kept one costs the whole lock.
        s.evidenceReset = true
        s.shiftTried = {}
        k = nextAnchorShift(s, nil)
        if DebugSolver then
            log("solver: anchor evidence inconsistent, search restarted")
        end
    end
    if k then
        reAnchor(s, k, why)
        return true
    end
    anchorExhausted(s, true, why)
    return false
end

-- would the game accept moving x by d under the believed state and the
-- live edge model? Mirrors stepSearch validity (atomic, rail -3..3).
-- The edge model only over-approximates (authored edges, pruned but
-- never added), so model-valid implies physically valid whenever the
-- anchor is right: a refusal of a model-valid move convicts the anchor.
local function moveValid(s, x, d)
    local rx = s.rotStart[x] + s.sign * (s.steps[x] or 0) + d
    if rx < -3 or rx > 3 then return false end
    for _, e in ipairs(s.edges[x] or {}) do
        local rb = s.rotStart[e.b] + s.sign * (s.steps[e.b] or 0) + d * e.dir
        if rb < -3 or rb > 3 then return false end
    end
    return true
end

-- does anchor shift k explain the game refusing to move x by d?
-- (in the shifted frame the mover or a dragged partner leaves the rail)
local function shiftExplainsRefusal(s, x, d, k)
    local rx = s.rotStart[x] + s.sign * (s.steps[x] or 0) + k + d
    if rx < -3 or rx > 3 then return true end
    for _, e in ipairs(s.edges[x] or {}) do
        local rb = s.rotStart[e.b] + s.sign * (s.steps[e.b] or 0) + k + d * e.dir
        if rb < -3 or rb > 3 then return true end
    end
    return false
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

-- ANCHOR-PROBE MARKING. While several anchor candidates survive, the
-- route's next move may be refusable under some of them. Substituting
-- a "safe" move instead is MATHEMATICALLY USELESS: provably-safe
-- means staying inside the already-observed pin span, which can never
-- produce information, so the ambiguity would survive forever (and a
-- greedy substitute oscillated one piece left-right in-game). The
-- route move IS the optimal play: it probes the most likely frame and
-- either outcome (click or shake) collapses the candidates. The only
-- honest improvement is to SAY so: probe hints paint neutral instead
-- of pretending certainty.
local function safeHint(s, mv)
    if not mv or s.anchorExact or not s.obsMin then return mv end
    local lo, hi = -3 - s.obsMin, 3 - s.obsMax
    if lo >= hi then return mv end -- unique window: certainty
    for k = lo, hi do
        if shiftExplainsRefusal(s, mv.piece, mv.dir, k) then
            mv.probe = true
            return mv
        end
    end
    return mv
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
            if i then return safeHint(s, decodeMove(plan.route[i])) end
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
                    if DebugSolver then
                        log("solver: no solution under any single-dead-edge "
                            .. "hypothesis")
                    end
                    -- on a derived anchor a total dead end usually means
                    -- the anchor itself is wrong (a shifted frame encodes
                    -- states the real lock cannot reach): move to the
                    -- next anchor candidate and keep planning
                    if s.obsMin and not s.stateUnknown
                        and disproveAnchor(s, "no route fits the believed state",
                            nil, true) then
                        curS = encodeCur(s)
                        ek = edgesKey(s)
                        plan = {
                            edgesKey = ek,
                            fromS = curS,
                            phase = s.deadHypo and "hypo0" or "base",
                            hypoIdx = 0,
                            -- covers both: deadHypo nil = the base search
                            search = buildSearch(s, s.deadHypo),
                            finished = false,
                        }
                        s.plan = plan
                    else
                        plan.finished = true
                        return nil
                    end
                end
                if plan.phase == "sweep" then
                    plan.search = buildSearch(s, s.hypoList[plan.hypoIdx])
                end
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
                return i and safeHint(s, decodeMove(plan.route[i])) or nil
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
    -- pressesSinceMove is consumed by the calibration below and only
    -- reset at the END of this function
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
    -- the selection read makes the mover KNOWN rather than inferred:
    -- use it to resolve the ambiguous cases, which previously taught
    -- the learner nothing. ONLY when the glow read is stable across
    -- ticks: it flaps between paired rows around move animations, and
    -- a flapped resolution once pruned a REAL connection (the planner
    -- then hinted a totally blocked piece, seen in-game)
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
        -- calibrate the input-to-axis mapping for the hint colors: the
        -- last Left/Right press plus the mover's observed displacement
        -- pin down which input direction moves pins toward +axis.
        -- ONLY from single-piece moves with exactly one press behind
        -- them: dragged pairs make the mover ambiguous and the glow
        -- read flaps between the pair, so calibrating off a partner
        -- (which travels OPPOSITE to the press) kept flipping the
        -- mapping in-game; stale presses from fast play did the same
        -- the ONLY color mechanism besides the deterministic camera
        -- rule: a MEASUREMENT from a clean single-press single-piece
        -- move. No audits, no flips, nothing mutates colors from
        -- gameplay heuristics (those once fought each other and lost
        -- the player's trust)
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
                        if DebugSolver then
                            log("solver: color mapping calibrated from input ("
                                .. newMap .. ")" .. (s.latchSide and
                                string.format(", key invariant "
                                    .. "RightTowardLatch=%+d",
                                    newMap * s.latchSide) or ""))
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
                    log(string.format("Edge %d->%d inactive this session, pruned",
                        x, es[i].b))
                    -- journal every prune: an unexplainable refused
                    -- move later means a prune was wrong and restores
                    -- them all
                    s.prunedLog = s.prunedLog or {}
                    table.insert(s.prunedLog,
                        { a = x, b = es[i].b, dir = es[i].dir })
                    table.remove(es, i)
                    pruned = true
                end
            end
            s.selectedRow = x -- mover = selection anchor
            if pruned then
                -- the sweep list mirrors the edge set; a stale entry
                -- could hypothesize a no-longer-existing edge dead
                s.hypoList = nil
                -- a better edge model lifts the soft (no-route) anchor
                -- convictions and reopens an exhausted anchor search:
                -- what had no route may have one now
                if s.shiftTried then
                    for sk, v in pairs(s.shiftTried) do
                        if v == "soft" then s.shiftTried[sk] = nil end
                    end
                end
                if s.anchorGaveUp then
                    s.anchorGaveUp, s.stateUnknown = nil, nil
                    if DebugSolver then
                        log("solver: edge model improved, anchor search reopened")
                    end
                end
            end
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
            if cur and s.cpProj then
                -- absolute grid snap around the anchored center:
                -- shakes, resets and missed settles cannot drift it
                local pr = cur[1] * s.axis[1] + cur[2] * s.axis[2]
                    + cur[3] * s.axis[3]
                s.steps[id] = math.floor((pr - s.cpProj) / s.stepSize + 0.5)
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
        if DebugSolver then log("solver: rail axis sign flipped") end
    end
    -- merge the settled state into the observed extremes (settled reads
    -- only; mid-motion slots record impossible transients). A rotation
    -- outside the rail disproves the anchor outright: shift to the
    -- nearest anchor that fits everything seen so far. Must run before
    -- the replan below, the base-7 encoding has no digit for rot 4.
    if s.obsMin and not s.stateUnknown then
        local minR, maxR = s.obsMin, s.obsMax
        for id = 0, s.pieceCount - 1 do
            local r = s.rotStart[id] + s.sign * (s.steps[id] or 0)
            if r < minR then minR = r end
            if r > maxR then maxR = r end
        end
        s.obsMin, s.obsMax = minR, maxR
        -- PURE GEOMETRY hardening: the true anchor always fits every
        -- observation, so when the candidate window narrows to exactly
        -- ONE shift, that shift IS the truth. As the route pushes pins
        -- toward the rail ends this happens within a few moves on any
        -- ambiguous lock, with no API reads and no refusal evidence.
        if not s.anchorExact then
            local lo, hi = -3 - minR, 3 - maxR
            if lo == hi then
                if lo ~= 0 then
                    reAnchor(s, lo, "pin span pinned the anchor")
                    minR, maxR = minR + lo, maxR + lo
                end
                s.anchorExact = true
                if DebugSolver then
                    log("solver: anchor now unique by pin span")
                end
            end
        end
        if minR < -3 or maxR > 3 then
            if maxR - minR > 6 then
                -- no anchor fits a spread wider than the rail: the
                -- measurement itself broke, stop hinting on it
                anchorExhausted(s, nil, "measured spread exceeds the rail")
            else
                disproveAnchor(s, "a pin left the believed rail")
            end
        end
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
    s.pressesSinceMove = 0 -- this move's presses are accounted for
end

-- selection ground truth: the piece currently wearing the game's
-- selected-look signature (excluding our own tints) IS the selected
-- one. Input counting desyncs when the game ignores presses
-- mid-animation; this read corrects it every tick, and it also hands
-- the edge learner the true mover instead of an inferred one.
local function selSync(s)
    if not s.selectedSig then return end
    local sig = s.selectedSig
    local best, bestD = nil, 0.05
    -- scan ALL pieces: a piece wearing our paint cannot match the glow
    -- signature anyway, and excluding tinted pieces once hid the truth
    -- when the tracker had painted over the actually-selected piece
    for id, e in pairs(s.pieces) do
        local mid = e.mids[1]
        if mid then
            local okc, c = pcall(function()
                return mid:K2_GetVectorParameterValue(FName("HighlightColor"))
            end)
            if okc and c then
                local dr, dg, db = c.R - sig.R, c.G - sig.G, c.B - sig.B
                local d = dr * dr + dg * dg + db * db
                if d < bestD then
                    best, bestD = id, d
                end
            end
        end
    end
    if best and best ~= s.selectedRow then
        if DebugSolver then
            log("solver: selection resynced " .. s.selectedRow .. " -> " .. best)
        end
        s.selectedRow = best
    end
end

-- snapshot and persist the OPEN arrangement: called the instant the
-- game broadcasts success (the actors die within a tick, so this
-- cannot wait for the session teardown)
local function learnOpenState(s)
    if not (s.axis and s.lockName and s.slotNow) then return end
    local n, sx, sy, sz = 0, 0, 0, 0
    local minP, maxP = nil, nil
    local rots = {}
    for id = 0, s.pieceCount - 1 do
        local v = s.slotNow[id]
        if v then
            n = n + 1
            sx, sy, sz = sx + v[1], sy + v[2], sz + v[3]
            local pr = v[1] * s.axis[1] + v[2] * s.axis[2] + v[3] * s.axis[3]
            if not minP or pr < minP then minP = pr end
            if not maxP or pr > maxP then maxP = pr end
            if s.cpProj then
                rots[#rots + 1] = tostring(math.floor(
                    (pr - s.cpProj) / s.stepSize + 0.5))
            end
        end
    end
    -- always document the winning arrangement: the open instant is
    -- ground truth and has repeatedly settled debates that drifting
    -- measurements started
    log("Solver: OPEN captured, rots [" .. table.concat(rots, ",")
        .. "] (believed frame, 0 = rail center)")
    if n == s.pieceCount and maxP - minP < s.stepSize * 0.35 then
        -- the centroid at the open INSTANT is the GOAL column (ground
        -- truth); the rail center derives from the session's goal
        -- rotation so a future session recovers both frame and goal
        local g = { sx / n, sy / n, sz / n }
        local gr = s.goalRot or 0
        local c = {
            g[1] - gr * s.stepSize * s.axis[1],
            g[2] - gr * s.stepSize * s.axis[2],
            g[3] - gr * s.stepSize * s.axis[3],
        }
        -- the latch side rides along when known so remembered locks
        -- get exact direction colors from the first paint; when it is
        -- unknown the session-measured input mapping substitutes (the
        -- player calibrated it by playing)
        local ls = s.latchSide
        if not ls and s.inputToAxis then
            ls = RightTowardLatch * s.inputToAxis
        end
        anchorsSave(s.lockName, { g = g, c = c, ls = ls })
        log("Solver: open position of '" .. s.lockName
            .. "' learned, this lock anchors exactly from now on")
    else
        log("Solver: open arrangement not a single clean column this "
            .. "session (a pin was likely still settling), nothing "
            .. "learned yet")
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
        -- backstop: if the success hooks missed (unknown ability
        -- variant), a death moments after an open signal still learns;
        -- and the FINAL settled state is always documented, it is the
        -- closest capture of the winning arrangement we get when the
        -- hooks are silent
        pcall(function()
            if DebugSolver then
                local rr = {}
                for id = 0, s.pieceCount - 1 do
                    rr[#rr + 1] = tostring(s.rotStart[id]
                        + s.sign * (s.steps[id] or 0))
                end
                log("solver: session ended, last rots ["
                    .. table.concat(rr, ",") .. "]")
            end
            if s.openSignalT and os.clock() - s.openSignalT < 3.0
                and not s.openLearned then
                s.openLearned = true
                -- refresh: the last cached read may be mid-glide
                for id = 0, s.pieceCount - 1 do
                    local v = readSlot(s, id)
                    if v then s.slotNow[id] = v end
                end
                learnOpenState(s)
            end
        end)
        s.stop = true
        if Session == s then Session = nil end
        return
    end
    -- OPENED epilogue: the win signal arrived but the actors LINGER
    -- (an opened chest's pieces stayed valid for minutes; the old
    -- die-within-a-tick doctrine is wrong for opened locks, which once
    -- left a stale session blocking the NEXT lock entirely). Close the
    -- session ourselves: wait out the final animation, learn the open
    -- arrangement from settled slots, restore tints, free the slot.
    if s.opened then
        if os.clock() - s.opened > 2.0 then
            for id = 0, s.pieceCount - 1 do
                local v = readSlot(s, id)
                if v then s.slotNow[id] = v end
            end
            if not s.openLearned then
                s.openLearned = true
                learnOpenState(s)
            end
            s.nextMove = nil
            pcall(retint, s)
            s.stop = true
            if Session == s then Session = nil end
            if DebugSolver then log("solver: session closed after open") end
        end
        return
    end
    -- fresh selection truth BEFORE move processing: the learner uses it
    selSync(s)
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
        elseif NextMoveActive and s.obsMin and not s.stateUnknown
            and (s.pressesSinceMove or 0) > 0 and s.lastInput
            and os.clock() - s.lastInput.t < 1.5 then
            -- motion that settled back where it started, WITH a fresh
            -- press behind it, is the game's SHAKE: a refused move,
            -- confirmed by the game itself. The press requirement
            -- keeps idle settle-wobble (sub-step jitter between the
            -- 0.2 motion and 1.0 move thresholds) from fabricating
            -- refusals out of thin air.
            s.shakeRefusal = true
        end
    end
    -- the learner's cross-tick selection stability gate: updated every
    -- settled tick AFTER move processing (processMove compares against
    -- the previous tick's value), and regardless of the hint toggle
    -- (gating it on the hint once silently weakened edge learning in
    -- hints-off sessions)
    s.lastTickSel = s.selectedRow
    -- diagnostics: does the per-boot-dead distance API come alive
    -- mid-session? One float call per tick, debug builds only; the
    -- answer decides whether mid-session re-measuring is worth having
    if DebugSolver and s.probePair and not s.probeAlive
        and not s.anchorExact then
        local dd = distTo(s.probePair[1], s.probePair[2])
        if dd then
            s.probeAlive = true
            log(string.format("solver: distance API ALIVE mid-session "
                .. "(d=%.2f, start expected %.2f)", dd,
                s.probePair.expected or -1))
        end
    end
    -- anchor evidence while settled, only while the hint is on (the
    -- connection display does not read rotations; with hints off the
    -- pin-left-rail check in processMove alone keeps the state warm).
    -- (1) The believed goal with the minigame still alive: the lock
    -- opens AT the true goal and this session dies with it within a
    -- tick, so persisting here a short grace disproves the anchor;
    -- this is the report "followed all hints, pins one beside the
    -- center, lock shut". (2) Repeated Left/Right presses that move
    -- NOTHING while the model allows the selected piece to move: the
    -- game's only refusal cause is a piece leaving the rail, so a
    -- refused model-valid move convicts the anchor too (a wrong frame
    -- otherwise deadlocks the hint: no move, no replan).
    if NextMoveActive and s.obsMin and not s.stateUnknown then
        local atGoal = true
        for id = 0, s.pieceCount - 1 do
            if s.rotStart[id] + s.sign * (s.steps[id] or 0)
                ~= (s.goalRot or 0) then
                atGoal = false
                break
            end
        end
        if atGoal then
            s.atGoalTicks = s.atGoalTicks + 1
            -- an EXACT (part-anchored) goal that does not open is
            -- almost certainly the open animation still playing (the
            -- session dies ~2s after the last move; a false disproof
            -- fired in exactly that window in-game), so exact anchors
            -- get a long grace; guessed anchors keep the short one
            local grace = s.anchorExact and 12 or 5
            -- an open signal in flight means the game is already
            -- opening: never disprove in that window
            if s.atGoalTicks >= grace and not s.openSignalT then
                -- the lock provably auto-opens on the last correct move
                -- (player-confirmed), so a shut lock at the believed
                -- goal is HARD evidence the frame is wrong. With direct
                -- grid snapping the only wrong part can be the anchor:
                -- drop a wrong remembered one for good, then walk.
                if s.anchorFromMemory and s.lockName and s.memEntry then
                    pcall(anchorsDrop, s.lockName, s.memEntry)
                    s.anchorFromMemory, s.memEntry = nil, nil
                    -- the goal came from the same dropped memory:
                    -- back to canon (center), or the solver would
                    -- chase a disproven goal column forever and even
                    -- persist a corrupted center on the next open
                    s.goalRot = 0
                    log("Solver: remembered open position was wrong, dropped")
                end
                disproveAnchor(s,
                    "the lock did not open at the believed goal")
                if not s.stateUnknown and NextMoveActive then
                    s.nextMove = solverPlan(s)
                end
            end
        else
            s.atGoalTicks = 0
            -- the glow read flaps between paired rows around move
            -- animations (seen in-game, once false-convicting the
            -- correct anchor): only a selection stable across two
            -- settled ticks may testify
            local shake = s.shakeRefusal
            s.shakeRefusal = nil
            -- the game-confirmed SHAKE is the ONLY refusal evidence:
            -- press counting is gone (the shake supersedes it) and
            -- nothing here may touch the colors (they are measured)
            if shake then
                local x, d = s.selectedRow, nil
                -- the PRESSED key mapped through the measured mapping,
                -- or through the canon camera rule (press = piece
                -- screen direction). NEVER assume the player pressed
                -- the hinted direction: a press into a physical wall
                -- is normal play, and that assumption once convicted
                -- a TRUE anchor and dropped a valid memory.
                local m = s.inputToAxis or s.screenRight
                if m and s.lastInput
                    and os.clock() - s.lastInput.t < 2.0 then
                    d = s.lastInput.dir * m * s.sign
                end
                local refusedValid
                if d then
                    refusedValid = moveValid(s, x, d)
                else
                    -- direction unknown on a non-hinted piece: only
                    -- both-ways-movable makes ANY press hard evidence
                    refusedValid = moveValid(s, x, 1) and moveValid(s, x, -1)
                end
                if refusedValid then
                    -- a refused model-valid move has TWO possible
                    -- causes, in evidence order: (1) a wrong anchor,
                    -- when some viable shift explains the refusal;
                    -- (2) a wrongly pruned connection (the physical
                    -- drag set is bigger than the model's, a totally
                    -- blocked piece hinted as movable): restore every
                    -- journaled prune and let the learner re-prove
                    -- them. Colors are NEVER touched here.
                    local explained = d and nextAnchorShift(s, function(k)
                        return shiftExplainsRefusal(s, x, d, k)
                    end) ~= nil
                    if not explained and s.prunedLog
                        and #s.prunedLog > 0 then
                        for _, e in ipairs(s.prunedLog) do
                            s.edges[e.a] = s.edges[e.a] or {}
                            table.insert(s.edges[e.a],
                                { b = e.b, dir = e.dir })
                        end
                        log(string.format("Solver: refused move has no "
                            .. "anchor explanation, restored %d pruned "
                            .. "connections", #s.prunedLog))
                        s.prunedLog = {}
                        s.hypoList = nil
                        s.plan, s.nextMove = nil, nil
                        if NextMoveActive then
                            s.nextMove = solverPlan(s)
                        end
                    else
                        disproveAnchor(s,
                            "the lock refused a move the model allows",
                            d and function(k)
                                return shiftExplainsRefusal(s, x, d, k)
                            end or nil)
                        if not s.stateUnknown and NextMoveActive then
                            s.nextMove = solverPlan(s)
                        end
                    end
                end
            end
        end
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
        else
            log("Lock name not readable, next-move hint off for this lock")
        end
        return
    end
    -- THE SCRAMBLE ANIMATION GATE: when the session starts, the pieces
    -- may still be GLIDING into their scrambled columns. A baseline
    -- captured mid-glide, or worse, still at a clean pre-scramble
    -- column, poisons that one piece's measured rotation for the whole
    -- session, and every anchor source then validates a believed state
    -- that is wrong for exactly that piece (seen in-game: a pin
    -- believed at -2 while visibly at the rail edge; the lock then
    -- refuses hints or stays shut at the believed goal). Proceed only
    -- once two snapshots ~450ms apart agree for every slot.
    do
        local lib0, mpc0, scene0 = mpcHandles()
        if lib0 then
            local n = #graph.pieces
            local s0 = { lib = lib0, mpc = mpc0, scene = scene0 }
            local snap = {}
            for id = 0, n - 1 do
                snap[id] = readSlot(s0, id)
            end
            local prev = StartSnap
            StartSnap = { t = os.clock(), lock = lockName, slots = snap }
            local stable = prev ~= nil and prev.lock == lockName
                and os.clock() - prev.t < 2.0
            if stable then
                for id = 0, n - 1 do
                    local a, b = prev.slots[id], snap[id]
                    if not a or not b
                        or math.abs(a[1] - b[1]) > 0.2
                        or math.abs(a[2] - b[2]) > 0.2
                        or math.abs(a[3] - b[3]) > 0.2 then
                        stable = false
                        break
                    end
                end
            end
            if not stable then
                if attempt < 12 then
                    ExecuteWithDelay(450, function()
                        ExecuteInGameThread(function()
                            pcall(startSession, attempt + 1)
                        end)
                    end)
                else
                    log("Lock pieces never settled, next-move hint off "
                        .. "for this lock")
                end
                return
            end
        end
    end
    local pieces, found = {}, 0
    local lifeActor = nil
    -- the piece actors come from the subsystem's own array for THIS
    -- minigame: FindAllOf also returns the actors of earlier minigames
    -- (an unsolved exit leaves them alive in the world), and on the
    -- SECOND lock of a run those contaminated the glow signature, the
    -- life actor and the part-column measurements with same-id stale
    -- actors (seen in-game repeatedly: first lock fine, second lock
    -- broken, fixed by a save load purging the world)
    -- runtime equivalent of what a save reload proved: only actors
    -- born for THIS minigame may be read. Fresh spawns (tracked via
    -- NotifyOnNewObject, see FreshPieces) are authoritative; the
    -- subsystem array would be too but is empty during play; the
    -- world-wide FindAllOf is the last resort and the one that mixed
    -- two locks' actors together on every second lock of a run.
    local actorList, actorSrc = {}, "fresh spawns"
    local nowT = os.clock()
    local keep = {}
    for _, e in ipairs(FreshPieces) do
        if nowT - e.t < 60.0 then
            keep[#keep + 1] = e
            if nowT - e.t < 12.0 then
                local okv, valid = pcall(function() return e.obj:IsValid() end)
                if okv and valid and not string.find(e.obj:GetFullName(),
                    "Default__", 1, true) then
                    actorList[#actorList + 1] = e.obj
                end
            end
        end
    end
    FreshPieces = keep
    if #actorList < 2 then
        actorList, actorSrc = {}, "subsystem"
        for _, sub in ipairs(liveInstances("LockPickSubsystem")) do
            pcall(function()
                local arr = sub.m_PendingLockPieces
                for i = 1, #arr do
                    local a = arr[i]
                    if a and a:IsValid() then
                        actorList[#actorList + 1] = a
                    end
                end
            end)
            if #actorList > 0 then break end
        end
    end
    if #actorList == 0 then
        actorList = liveInstances("GothicLockPieceActor")
        actorSrc = "FindAllOf (no fresh spawns, subsystem empty)"
    end
    if DebugSolver then
        log("solver: " .. #actorList .. " piece actors from " .. actorSrc)
    end
    for _, a in ipairs(actorList) do
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
            if ty then
                -- the part ACTOR is kept for the column anchor reads
                -- at session start; rr is OPTIONAL (latch actors carry
                -- no runtime root, requiring one silently dropped them
                -- and left the bar column without its orientation
                -- reference)
                table.insert(pieces[id].parts, { ty = ty, rr = rr, actor = a })
            end
        end
    end
    if found < 2 then
        if attempt < 6 then
            ExecuteWithDelay(500, function()
                ExecuteInGameThread(function() startSession(attempt + 1) end)
            end)
        else
            -- never fail wordlessly: a boost without a session banner
            -- once cost a debugging round
            log("Lock pieces not found, next-move hint off for this lock")
        end
        return
    end
    -- normalize the restore color: the game STARTS with the bottom row
    -- (piece 0) selected, so its captured color is the brightened
    -- selected look, and restoring it later would paint a phantom
    -- selection. The default is one shared material value, so take it
    -- from a piece that is NOT selected at start.
    -- That brightened capture is also a GIFT: it is the signature of
    -- the game's selected look, in a parameter we can READ, making the
    -- selection observable after all (input counting alone desynced
    -- when the game ignored presses mid-animation).
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
        local dr = selectedSig.R - commonDefault.R
        local dg = selectedSig.G - commonDefault.G
        local db = selectedSig.B - commonDefault.B
        if dr * dr + dg * dg + db * db < 0.02 then
            selectedSig = nil -- not distinctive, keep counting blind
        end
    else
        selectedSig = nil
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
        selectedSig = selectedSig,
        wasMoving = false, stop = false,
        atGoalTicks = 0,
        pressesSinceMove = 0, lastTickSel = 0,
        lockName = lockName, goalRot = 0,
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
    -- open position = the rail center, rotation 0 (player canon).
    -- Starts CAN equal the authored layout (observed repeatedly), but
    -- a mid-session break re-scrambles AND a save reload can swap the
    -- chest's entire lock config (RandomLockSubsystem assigns a random
    -- lock per save-state: three different names were learned at one
    -- physical chest). So mined rotations are never trusted for the
    -- current state: it is measured. NOTE the scene actor is an AInfo
    -- with NO transform; the live state comes from the MPC slots and
    -- the fixed bar/latch part columns, never from the scene location.
    -- Mined data contributes the connection graph (name-stable).
    local derived = false
    local okGeo, errGeo = pcall(function()
        -- SLOTS ONLY: every read through the scene actor's wrapper chain
        -- degrades under some UE4SS configurations (struct fields coming
        -- back as UObjects), while the MPC slot reads have never failed.
        -- The rail axis comes from the slot cloud (differencing
        -- adjacent-row differences cancels the row direction), and the
        -- absolute anchor is the integer offset that fits every piece
        -- on the rail, unique ONLY when the pieces span the whole rail.
        -- Non-spanning scrambles keep several valid offsets and the
        -- most-centered pick is a guess (wrong ~43% of those attempts,
        -- simulated over the mined graphs; the community's "all pins
        -- end one beside the center" reports). The guess is upgraded
        -- from the scene center when that read validates, and corrected
        -- at runtime from evidence either way (see anchor correction).
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
        if not best and #D > 0 then
            -- DEGENERATE SCRAMBLE fallback (all pieces in one column):
            -- the difference-of-differences cancels to nothing, but
            -- the ROW direction always exists, rails are horizontal,
            -- so the axis is the row direction's horizontal
            -- perpendicular (a same-column scramble once left a lock
            -- entirely hintless)
            local rx, ry, rz = 0, 0, 0
            for _, dv in ipairs(D) do
                rx, ry, rz = rx + dv[1], ry + dv[2], rz + dv[3]
            end
            local rl = math.sqrt(rx * rx + ry * ry + rz * rz)
            if rl > 1.0 then
                rx, ry = rx / rl, ry / rl
                local ax, ay = ry, -rx -- cross(rowDir, worldUp)
                local al = math.sqrt(ax * ax + ay * ay)
                if al > 0.5 then
                    candidates[#candidates + 1] = { name = "row-cross",
                        v = { ax / al, ay / al, 0 } }
                end
            end
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
                    -- anchor-correction bookkeeping: observed rotation
                    -- extremes bound the viable anchors, shiftTried
                    -- holds the disproven ones (keyed by total shift)
                    s.obsMin, s.obsMax = bestMin + bestK, bestMax + bestK
                    s.anchorShift, s.shiftTried = 0, {}
                    derived = true
                    if DebugSolver then
                        log(string.format("solver: rail axis from slot cloud "
                            .. "(step %.2f, residual %.2f, shift %+d)",
                            bestStep, bestWorst, bestK))
                    end
                    -- ABSOLUTE anchor from the piece part actors. Each
                    -- piece is several GothicLockPieceActor instances
                    -- (plate/bar/latch); bar and latch are FIXED columns
                    -- shared by all pieces, and the BAR COLUMN IS THE
                    -- OPEN COLUMN (eye-verified against settle-gated
                    -- baselines: pin positions match believed rotations
                    -- exactly when the center sits on the bar column).
                    -- The scene actor is an AInfo with NO transform, so
                    -- the old read-the-scene idea could never work.
                    -- Nothing is hardcoded by part-type enum: every
                    -- fixed column is offered as a center candidate and
                    -- must snap every plate onto the grid as a pure
                    -- shift in range; the latch lies far off the rail
                    -- and dies at the range gate. Every failure falls
                    -- back to the centered guess + runtime corrections.
                    -- part actors from EARLIER minigames at other locks
                    -- can still be alive (seen in-game), so each
                    -- (piece, type) keeps all candidates and the one
                    -- nearest the minigame camera wins; GetDistanceTo
                    -- is a float UFunction and works on every setup
                    local camAct = nil
                    pcall(function()
                        local pc = FindFirstOf("PlayerController")
                        camAct = pc.PlayerCameraManager
                    end)
                    -- distTo is file-scope (also used by the
                    -- mid-session API revival probe)
                    local cand, tySet = {}, {}
                    for id = 0, s.pieceCount - 1 do
                        cand[id] = {}
                        for _, part in ipairs((pieces[id] or {}).parts or {}) do
                            cand[id][part.ty] = cand[id][part.ty] or {}
                            table.insert(cand[id][part.ty], part.actor)
                            tySet[part.ty] = true
                        end
                    end
                    local resolved = {}
                    for id = 0, s.pieceCount - 1 do
                        resolved[id] = {}
                        for ty, list in pairs(cand[id]) do
                            local best, bestD = list[#list], nil
                            if camAct and #list > 1 then
                                for _, a in ipairs(list) do
                                    local dd = distTo(a, camAct)
                                    if dd and (bestD == nil or dd < bestD) then
                                        best, bestD = a, dd
                                    end
                                end
                            end
                            resolved[id][ty] = best
                        end
                    end
                    -- grid validation shared by every absolute-anchor
                    -- source: a center candidate must snap every plate
                    -- onto the grid, in range, as a pure shift of the
                    -- relative shape. Adopts the anchor on success;
                    -- only TRUSTED sources mark it exact (a long
                    -- goal-miss grace), doubtful ones keep the
                    -- corrections fully armed
                    local function adoptCenter(cp, src, exact)
                        local rotsAbs, shift, reject = {}, nil, nil
                        for id = 0, s.pieceCount - 1 do
                            local q = (ps[id] - cp) / s.stepSize
                            local r = math.floor(q + 0.5)
                            if math.abs(q - r) > 0.30 then
                                reject = "residual"
                                break
                            end
                            if r < -3 or r > 3 then
                                reject = "range"
                                break
                            end
                            local dk = r - s.rotStart[id]
                            if shift == nil then
                                shift = dk
                            elseif dk ~= shift then
                                reject = "shape"
                                break
                            end
                            rotsAbs[id] = r
                        end
                        if not reject and shift then
                            for id = 0, s.pieceCount - 1 do
                                s.rotStart[id] = rotsAbs[id]
                            end
                            s.obsMin = s.obsMin + shift
                            s.obsMax = s.obsMax + shift
                            s.anchorExact = exact or nil
                            if DebugSolver then
                                log(string.format("solver: anchor from %s "
                                    .. "(%+d vs centered guess)", src, shift))
                            end
                            return true
                        end
                        if DebugSolver then
                            log(string.format("solver: %s rejected (%s)",
                                src, tostring(reject)))
                        end
                        return false
                    end
                    local tys = {}
                    for ty in pairs(tySet) do tys[#tys + 1] = ty end
                    table.sort(tys)
                    local anchored = false
                    -- FIRST: a remembered open position for this chest,
                    -- the slot-only source that survives every boot
                    pcall(anchorsLoad)
                    local la = nil
                    do
                        -- a memory may only anchor a lock whose slot
                        -- cloud it physically sits at: the same name
                        -- exists at several world locations, and a
                        -- chest's memory once anchored a door across
                        -- the room (garbage that validated by luck)
                        local list = LearnedAnchors
                            and LearnedAnchors[lockName]
                        if list then
                            local mx, my, mz, mn = 0, 0, 0, 0
                            for id = 0, s.pieceCount - 1 do
                                local v = s.slotStart[id]
                                if v then
                                    mx, my, mz = mx + v[1], my + v[2],
                                        mz + v[3]
                                    mn = mn + 1
                                end
                            end
                            if mn > 0 then
                                mx, my, mz = mx / mn, my / mn, mz / mn
                                local bestD
                                for _, e in ipairs(list) do
                                    local d2 = (e.g[1] - mx) ^ 2
                                        + (e.g[2] - my) ^ 2
                                        + (e.g[3] - mz) ^ 2
                                    -- 60 units, see anchorsSave: a
                                    -- neighboring lock's memory must
                                    -- never validate here
                                    if d2 < 60 ^ 2
                                        and (not bestD or d2 < bestD) then
                                        la, bestD = e, d2
                                    end
                                end
                            end
                        end
                    end
                    if la then
                        local gp = la.g[1] * axis[1] + la.g[2] * axis[2]
                            + la.g[3] * axis[3]
                        if la.c then
                            -- remembered rail center anchors the frame;
                            -- the remembered goal column is a per-lock
                            -- safety (by canon it equals the center,
                            -- goalRot 0)
                            local cp = la.c[1] * axis[1] + la.c[2] * axis[2]
                                + la.c[3] * axis[3]
                            anchored = adoptCenter(cp,
                                "remembered open position", true)
                            if anchored then
                                s.goalRot = math.floor(
                                    (gp - cp) / s.stepSize + 0.5)
                            end
                        else
                            -- old single-column memory: frame on the
                            -- goal itself
                            anchored = adoptCenter(gp,
                                "remembered open position", true)
                        end
                        s.anchorFromMemory = anchored or nil
                        s.memEntry = anchored and la or nil
                        if anchored and la.ls then
                            s.latchSide = la.ls
                        end
                    end
                    -- SECOND: distance trilateration, floats only.
                    -- GetDistanceTo is a float UFunction (immune to the
                    -- LWC double marshalling that breaks location reads
                    -- on stock UE4SS) and the plates' true positions
                    -- are already known (the slots), so the center
                    -- column falls out of same-row part-to-plate
                    -- DISTANCES alone: with d_r = dist(column part,
                    -- own plate) and p_r the plate projections, rows r,s
                    -- in different columns give
                    --   c = (p_r+p_s)/2 + (d_s^2-d_r^2)/(2(p_r-p_s)).
                    -- The plate part type is identified by checking one
                    -- cross-row part distance against the known slot
                    -- distance; column candidates pass the same grid
                    -- validation (the latch column cannot).
                    if not anchored then
                        local partOf = resolved
                        -- two reference rows in different columns
                        local r1, r2 = nil, nil
                        for a = 0, s.pieceCount - 1 do
                            for b = a + 1, s.pieceCount - 1 do
                                if math.abs(ps[a] - ps[b]) > s.stepSize * 0.5 then
                                    r1, r2 = a, b
                                    break
                                end
                            end
                            if r1 then break end
                        end
                        local plateTy = nil
                        if r1 then
                            local va, vb = s.slotStart[r1], s.slotStart[r2]
                            local expected = math.sqrt(
                                (va[1] - vb[1]) ^ 2 + (va[2] - vb[2]) ^ 2
                                + (va[3] - vb[3]) ^ 2)
                            for _, ty in ipairs(tys) do
                                local pa, pb = partOf[r1][ty], partOf[r2][ty]
                                if pa and pb then
                                    local d = distTo(pa, pb)
                                    if DebugSolver then
                                        -- the decisive diagnosis line:
                                        -- nil d = the distance calls do
                                        -- not work at all, a wrong d =
                                        -- stale or mismatched actors
                                        log(string.format("solver: plate probe "
                                            .. "ty=%s d=%s expected=%.2f",
                                            tostring(ty),
                                            d and string.format("%.2f", d)
                                            or "nil", expected))
                                    end
                                    if d and math.abs(d - expected) < 1.0 then
                                        plateTy = ty
                                        break
                                    end
                                end
                            end
                            -- keep one pair for the mid-session API
                            -- revival probe (diagnostics: does a
                            -- dead-boot distance API ever come back?)
                            local ty1 = tys[1]
                            if ty1 and partOf[r1][ty1] and partOf[r2][ty1] then
                                s.probePair = { partOf[r1][ty1],
                                    partOf[r2][ty1], expected = expected }
                            end
                        end
                        if plateTy then
                            -- column projection per non-plate part type
                            local colC = {}
                            for _, ty in ipairs(tys) do
                                if ty ~= plateTy then
                                    local dist = {}
                                    for id = 0, s.pieceCount - 1 do
                                        local pa = partOf[id][ty]
                                        local pl = partOf[id][plateTy]
                                        if pa and pl then
                                            dist[id] = distTo(pa, pl)
                                        end
                                    end
                                    local cs = {}
                                    for a = 0, s.pieceCount - 1 do
                                        for b = a + 1, s.pieceCount - 1 do
                                            if dist[a] and dist[b] and
                                                math.abs(ps[a] - ps[b])
                                                > s.stepSize * 0.5 then
                                                cs[#cs + 1] = (ps[a] + ps[b]) / 2
                                                    + (dist[b] ^ 2 - dist[a] ^ 2)
                                                    / (2 * (ps[a] - ps[b]))
                                            end
                                        end
                                    end
                                    if #cs > 0 then
                                        table.sort(cs)
                                        colC[ty] = cs[math.floor((#cs + 1) / 2)]
                                    end
                                end
                            end
                            if DebugSolver then
                                local cls = {}
                                for ty2, c2 in pairs(colC) do
                                    cls[#cls + 1] = string.format("ty=%s@%.2f",
                                        tostring(ty2), c2)
                                end
                                table.sort(cls)
                                log("solver: fixed columns: " .. (#cls > 0
                                    and table.concat(cls, " ") or "none"))
                            end
                            -- the bar column IS the open column (eye-
                            -- verified against a settle-gated baseline:
                            -- believed rots uniformly one off until the
                            -- center was moved onto the bar column; an
                            -- earlier one-step-offset theory came from
                            -- sessions whose baselines were poisoned by
                            -- the scramble animation). Adopt each fixed
                            -- column directly; the latch candidate lies
                            -- far off the rail and dies at the range
                            -- gate, the bar's snaps exactly.
                            for _, ty in ipairs(tys) do
                                if colC[ty] and adoptCenter(colC[ty],
                                    "part distances ty=" .. tostring(ty),
                                    true) then
                                    anchored = true
                                    -- the OTHER fixed column is the
                                    -- latch: its side orients the keys.
                                    -- The goal stays the center (player
                                    -- canon: pins at 4, ALWAYS; the
                                    -- shut-at-center sessions that once
                                    -- suggested otherwise predate the
                                    -- drift-proof measurement)
                                    for ty2, c2 in pairs(colC) do
                                        if ty2 ~= ty then
                                            s.latchSide = (c2 > colC[ty])
                                                and 1 or -1
                                        end
                                    end
                                    break
                                end
                            end
                        elseif DebugSolver then
                            log("solver: plate part type not identifiable "
                                .. "(uniform scramble?), distances skipped")
                        end
                    end
                    -- SECONDARY: direct location read of the part
                    -- column. Needs healthy LWC double marshalling: on
                    -- stock UE4SS it can decode CONSISTENTLY WRONG and
                    -- still pass validation (seen in-game: exactly one
                    -- grid step off, the lock then refused to open), so
                    -- it never counts as exact and the goal-miss
                    -- correction keeps its short grace
                    if not anchored then
                        local colC = {}
                        for _, ty in ipairs(tys) do
                            local list = {}
                            for id = 0, s.pieceCount - 1 do
                                local a = resolved[id][ty]
                                if a then
                                    local okp, px, py, pz = pcall(function()
                                        local v = a:K2_GetActorLocation()
                                        return v.X, v.Y, v.Z
                                    end)
                                    if okp and tonumber(px) and tonumber(py)
                                        and tonumber(pz) then
                                        list[#list + 1] = px * axis[1]
                                            + py * axis[2] + pz * axis[3]
                                    end
                                end
                            end
                            -- the fixed columns are the same for every
                            -- piece: varying projections are the plates
                            if #list >= s.pieceCount then
                                table.sort(list)
                                if list[#list] - list[1] < s.stepSize * 0.5 then
                                    colC[ty] = list[math.floor((#list + 1) / 2)]
                                end
                            end
                        end
                        -- direct adoption, same as the distance path:
                        -- the bar column is the open column
                        for _, ty in ipairs(tys) do
                            if colC[ty] and adoptCenter(colC[ty],
                                "part column ty=" .. tostring(ty),
                                false) then
                                anchored = true
                                for ty2, c2 in pairs(colC) do
                                    if ty2 ~= ty then
                                        s.latchSide = (c2 > colC[ty])
                                            and 1 or -1
                                    end
                                end
                                break
                            end
                        end
                    end
                    if not anchored and DebugSolver then
                        log("solver: no absolute anchor, centered guess "
                            .. "stands (corrections will cover it)")
                    end
                    -- the key mapping is a game constant relative to
                    -- the lock geometry: with the latch side known the
                    -- colors are correct from the FIRST hint, nothing
                    -- to learn at runtime
                    if s.latchSide then
                        s.inputToAxis = RightTowardLatch * s.latchSide
                        if DebugSolver then
                            log(string.format("solver: colors pre-calibrated "
                                .. "(latch side %+d)", s.latchSide))
                        end
                    end
                    -- the anchor as an absolute projection: from here
                    -- on every settle snaps every pin DIRECTLY onto
                    -- the grid around this center. The lock provably
                    -- auto-opens on the last correct move (player-
                    -- confirmed), yet believed goals sat shut: the
                    -- displacement-from-start tracking accumulated
                    -- error. Direct snapping has nothing to accumulate
                    do
                        local offs = {}
                        for id = 0, s.pieceCount - 1 do
                            offs[#offs + 1] = ps[id]
                                - s.rotStart[id] * s.stepSize
                        end
                        table.sort(offs)
                        s.cpProj = offs[math.floor((#offs + 1) / 2)]
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
                .. "] (geometric), goal rot " .. tostring(s.goalRot or 0)
                .. ", screenRight=" .. tostring(s.screenRight))
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
    -- the same input dispatch (sub-millisecond). Keep the window TINY:
    -- holding a key repeats at ~30ms and a wider window swallowed every
    -- other step, desyncing the selection tracker.
    local now = os.clock()
    if now - lastSelStep < 0.005 then return end
    lastSelStep = now
    local s = Session
    if not s or s.stop then return end
    s.selectedRow = math.max(0, math.min(s.pieceCount - 1, s.selectedRow + delta))
    -- instant truth check: the game has already moved its glow within
    -- this very input dispatch, so read it now instead of waiting for
    -- the next tick (fast clicking outran the tick-based resync)
    pcall(selSync, s)
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
    -- Left/Right presses feed the color-mapping MEASUREMENT only (a
    -- single clean press + the observed displacement pin the mapping
    -- down exactly). Refusals are detected from the game's own shake,
    -- never from press counting. Dedup keyed per SESSION, not per
    -- chunk: old-chunk closures see their own Session and cannot
    -- double count ours after a hot reload
    local function onMovePress(dir)
        local s = Session
        if not s or s.stop then return end
        local now = os.clock()
        if now - (s.lastPressT or 0) > 0.005 then
            s.lastPressT = now
            s.pressesSinceMove = (s.pressesSinceMove or 0) + 1
        end
        s.lastInput = { dir = dir, t = now }
    end
    pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:LeftPressed", function()
        pcall(onMovePress, -1)
    end)
    pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:RightPressed", function()
        pcall(onMovePress, 1)
    end)
    -- the open signal: combined with aligned pins at session death it
    -- marks a TRUE open position worth remembering for the chest
    pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:TryOpenLock", function()
        pcall(function()
            local s = Session
            if s and not s.stop then
                s.openSignalT = os.clock()
                if DebugSolver then log("solver: TryOpenLock fired") end
            end
        end)
    end)
    -- the AUTHORITATIVE verdict signals: the C++ minigame broadcasts
    -- success/failure through these ability UFunctions (located by
    -- mining the native bind table). Proven in-game: they fired on
    -- every solve and drive the open learning. MemorizeLockpick rides
    -- along as a redundant non-replicated source; all are idempotent
    -- on the same flags. (A key-locked door was once misattributed to
    -- these hooks; keys are vanilla behavior, the hooks were clean.)
    local function onOpenSignal(src)
        local s = Session
        if s and not s.stop then
            s.openSignalT = os.clock()
            -- do NOT learn here: the final pin's animation is still
            -- mid-glide at signal time; the epilogue in solverTick
            -- learns from settled slots and closes the session
            s.opened = s.opened or os.clock()
            if DebugSolver then
                log("solver: OPEN signal: " .. src)
            end
        end
    end
    for _, fn in ipairs({
        "/Script/G1R.GameplayAbilityDoor:Server_SuccessLockEvent",
        "/Script/G1R.GameplayAbilityOpen:Server_SuccessLockEvent",
        "/Script/G1R.GameplayAbilityDoor:NetMulticast_OnSetLockUnlocked",
        "/Script/G1R.GameplayAbilityOpen:NetMulticast_OnSetLockUnlocked",
        "/Script/G1R.AbilityTask_LockPick:MemorizeLockpick",
    }) do
        pcall(RegisterHook, fn, function()
            pcall(onOpenSignal, fn)
        end)
    end
    for _, fn in ipairs({
        "/Script/G1R.GameplayAbilityDoor:Server_FailedLockEvent",
        "/Script/G1R.GameplayAbilityOpen:Server_FailedLockEvent",
    }) do
        pcall(RegisterHook, fn, function()
            pcall(function()
                local s = Session
                if s and not s.stop then
                    -- a fail = pick break, a re-scramble follows: the
                    -- pins will fly, evidence counters must not read
                    -- the flight as anything
                    s.atGoalTicks = 0
                    if DebugSolver then
                        log("solver: FAIL signal (pick broke): " .. fn)
                    end
                end
            end)
        end)
    end
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
-- every piece actor spawn is recorded with its time: startSession then
-- reads only actors born for the current minigame (the save-reload
-- insight made permanent: stale actors of earlier minigames poisoned
-- every read that touched them)
pcall(NotifyOnNewObject, "/Script/G1R.GothicLockPieceActor", function(obj)
    FreshPieces[#FreshPieces + 1] = { obj = obj, t = os.clock() }
end)
-- the active lock identity comes from the freshest ability spawn
pcall(NotifyOnNewObject, "/Script/G1R.GameplayAbilityOpen", function(obj)
    FreshAbility = { obj = obj, t = os.clock() }
end)
pcall(NotifyOnNewObject, "/Script/G1R.GameplayAbilityDoor", function(obj)
    FreshAbility = { obj = obj, t = os.clock() }
end)

local okNotify, errNotify = pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick",
    function(task)
        pcall(function()
            FreshTask = { obj = task, t = os.clock() }
        end)
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
