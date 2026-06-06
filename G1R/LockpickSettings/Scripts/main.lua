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
--      tinted green, recomputed after every move. Entirely state-driven:
--      no hooks, no input tracking, no knowledge of the user's selection.
--      The lock layouts (pieces + directed connections) ship in
--      lockgraphs.lua, extracted offline from the game's compiled
--      AngelScript blob (tools/extract_locks.py). Live piece positions
--      come from the game's MPC_Lockpicking material collection
--      (Slot_i = world position of piece i), the goal rotation from the
--      scene's m_RotationToBarOffset map, and a small BFS finds the
--      shortest move sequence. Connections the game removed at runtime
--      (suspected skill/precision mechanic) are pruned when a move shows
--      they are inactive. One lean poll tick (2.5x/s, cached references
--      only, no object scans) watches for moves and re-asserts the tint.

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
local HotkeyName     = Config.nextMoveHotkey
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
local NextMoveColor = { R = 0.10, G = 1.00, B = 0.15, A = 1.0 } -- green

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
local function retint(s)
    local want = s.nextMove and s.nextMove.piece or nil
    if s.greenId and s.greenId ~= want then
        local e = s.pieces[s.greenId]
        if e and e.default then writeColor(e, e.default) end
    end
    s.greenId = want
    if want then
        local e = s.pieces[want]
        if e then writeColor(e, NextMoveColor) end
    end
end

-- BFS over rail states. Kept deliberately small: expansion budget low
-- enough to never hitch or build GC pressure (suspected cause of an
-- earlier abort crash); locks are designed to be solvable in few moves.
local function solverReplan(s)
    if s.openRot == nil then return nil end
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
    local queue, qi = { { st = start } }, 1
    local visited = { [key(start)] = true }
    local expansions = 0
    while qi <= #queue do
        local node = queue[qi]
        queue[qi] = false -- release processed nodes to the GC
        qi = qi + 1
        expansions = expansions + 1
        if expansions > 12000 then
            if DebugSolver then log("solver: search budget exhausted") end
            return nil
        end
        for x = 0, n - 1 do
            for d = -1, 1, 2 do
                local st = node.st
                -- lock-in: a piece at the open rotation is frozen, both
                -- as a mover and as a dragged partner
                if st[x] ~= target[x]
                    and math.abs(rotStart[x] + sign * (st[x] + d)) <= 3 then
                    local nst = {}
                    for id = 0, n - 1 do nst[id] = st[id] end
                    nst[x] = st[x] + d
                    for _, e in ipairs(s.edges[x] or {}) do
                        if nst[e.b] ~= target[e.b] then
                            local np = nst[e.b] + d * e.dir
                            if math.abs(rotStart[e.b] + sign * np) <= 3 then
                                nst[e.b] = np
                            end
                        end
                    end
                    local k = key(nst)
                    if not visited[k] then
                        visited[k] = true
                        local first = node.first or { piece = x, dir = d }
                        local done = true
                        for id = 0, n - 1 do
                            if nst[id] ~= target[id] then done = false break end
                        end
                        if done then return first end
                        queue[#queue + 1] = { st = nst, first = first }
                    end
                end
            end
        end
    end
    if DebugSolver then log("solver: no solution under current model") end
    return nil
end

-- update steps from observed slots; calibrate the rail axis and its
-- sign; prune edges the game evidently removed (mover identified by
-- matching the moved set against {X} + live out-edges of X)
local function processMove(s, moved, count, prev, now)
    local match = nil
    for x in pairs(moved) do
        local n, same = 1, true
        for _, e in ipairs(s.edges[x] or {}) do
            n = n + 1
            if not moved[e.b] then same = false break end
        end
        if same and n == count then
            if match ~= nil then match = nil break end -- ambiguous
            match = x
        end
    end
    if match ~= nil and s.edges[match] then
        local es = s.edges[match]
        for i = #es, 1, -1 do
            if not moved[es[i].b] then
                log(string.format("Edge %d->%d inactive this session, pruned",
                    match, es[i].b))
                table.remove(es, i)
            end
        end
    end
    -- per-event step integration: each settled move contributes a small
    -- count (1-3 steps), safely roundable despite the slot grid's slight
    -- nonuniformity (~6.1-6.3 units); the step estimate is refined from
    -- every event. Cumulative division drifted and is gone.
    for id in pairs(moved) do
        local a, b = prev[id], now[id]
        if a and b then
            local dx = { b[1] - a[1], b[2] - a[2], b[3] - a[3] }
            local len = math.sqrt(dx[1] * dx[1] + dx[2] * dx[2] + dx[3] * dx[3])
            if not s.axis and len > 3.0 then
                s.axis = { dx[1] / len, dx[2] / len, dx[3] / len }
            end
            if s.axis then
                local proj = dx[1] * s.axis[1] + dx[2] * s.axis[2] + dx[3] * s.axis[3]
                local n = math.max(1, math.floor(math.abs(proj) / s.stepSize + 0.5))
                local stepEmp = math.abs(proj) / n
                if stepEmp > 5.0 and stepEmp < 7.5 then
                    s.stepSize = 0.7 * s.stepSize + 0.3 * stepEmp
                end
                s.steps[id] = (s.steps[id] or 0) + (proj >= 0 and n or -n)
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
    if not plausible(s.sign) and plausible(-s.sign) then
        s.sign = -s.sign
        if DebugSolver then log("solver: rail axis sign flipped") end
    end
    s.nextMove = solverReplan(s)
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
    retint(s)
end

local function startSession(attempt)
    if not NextMoveActive or Session ~= nil then return end
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
        sign = 1, axis = nil, nextMove = nil, greenId = nil,
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
    s.nextMove = solverReplan(s)
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
local function setNextMove(active)
    if NextMoveBroken then return end
    NextMoveActive = active
    log("Next-move hint " .. (active and "ON" or "OFF"))
    if not active then
        local s = Session
        Session = nil
        if s then
            s.stop = true
            -- restore the current green piece to its snapshot
            if s.greenId then
                local e = s.pieces[s.greenId]
                if e and e.default then writeColor(e, e.default) end
            end
        end
    else
        -- if a minigame is already open, start right away
        local ok, err = pcall(startSession, 1)
        if not ok then log("Next-move hint error: " .. tostring(err)) end
    end
end

if type(HotkeyName) == "string" and HotkeyName ~= "" and not NextMoveBroken then
    if Key[HotkeyName] then
        pcall(RegisterKeyBind, Key[HotkeyName], function()
            ExecuteInGameThread(function()
                pcall(setNextMove, not NextMoveActive)
            end)
        end)
    else
        log("ERROR: unknown nextMoveHotkey '" .. HotkeyName .. "', hotkey disabled")
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
        if NextMoveActive then
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
end
log("Loaded: " .. table.concat(loaded, ", ") .. hintInfo)
