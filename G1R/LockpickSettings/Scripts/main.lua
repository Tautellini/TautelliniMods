-- LockpickSettings for Gothic 1 Remake  --  thin orchestrator
--
-- This file carries NO algorithm and NO measurement logic: it wires the
-- concern modules to the engine's events and owns ALL registration. The work
-- lives in: solver.lua (pure search), geometry.lua (pure anchor math),
-- session.lua (the live minigame), tinter.lua (HighlightColor writes),
-- engine.lua (the pcall-wrapped UE4SS boundary), boost.lua (the Extra-Tries
-- feature), num.lua/colors.lua (pure helpers), config.lua + lockgraphs.lua
-- (data). See CONTRIBUTING.md for the conventions.
--
-- MINIGAME CANON (player-verified 2026-06-07, see README; when an observation
-- contradicts these rules, the MEASUREMENT is wrong):
--   * 7 pin positions per piece; THE GOAL IS ALWAYS ALL PINS ON POSITION 4
--     (center); the lock opens BY ITSELF on the last correct move
--   * controls inverted: pressing LEFT moves a pin RIGHT
--   * moves are atomic: refused entirely (shake) if the pin or any dragged
--     partner would leave the rail, and a refusal COSTS DURABILITY
--   * starts can equal the authored layout; breaks re-scramble
--
-- Three features, configured in config.lua: (1) Extra tries (boost.lua);
-- (2) Next-move hint (solver + geometry + tinter); (3) Connection display
-- (tinter). Tracking always runs while a minigame is open; the hotkeys only
-- toggle the paint, so mid-lock activation is exact.

-- UE4SS mods share one Lua state: another mod overwriting a standard global
-- (seen in the wild: ipairs replaced by a table) must not break us. Capture
-- everything we rely on as locals, including the OOP primitives the class
-- files need.
local ipairs, pairs, tostring, tonumber = ipairs, pairs, tostring, tonumber
local type, pcall, print, require, next = type, pcall, print, require, next
local setmetatable, getmetatable, rawget = setmetatable, getmetatable, rawget
local math, table, string, os = math, table, string, os

local function log(msg)
    print("[LockpickSettings] " .. tostring(msg) .. "\n")
end

-- logged at load so support can spot stale installs instantly
local ModVersion = "2.7-alpha6"

-- --------------------------------------------------------- hot reload reset --
-- CTRL+R re-runs this chunk. nil EVERY shipped module in BOTH caches BEFORE the
-- first require: nil-ing a parent does NOT nil its children, so a partial reset
-- would silently load stale children and ignore your edits. The
-- ue4ss_loaded_modules table is the custom-searcher cache on newer UE4SS builds.
local MODULES = {
    "config", "lockgraphs", "num", "colors", "engine", "boost",
    "solver", "geometry", "tinter", "session",
}
for _, m in ipairs(MODULES) do
    package.loaded[m] = nil
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then reg[m] = nil end
end

-- ----------------------------------------------------------------- modules --
-- each require pcall-wrapped; a broken child disables only the features that
-- depend on it (the mod never goes down over one file).
local function tryRequire(name)
    local ok, mod = pcall(require, name)
    if not ok or type(mod) ~= "table" then
        log("ERROR in " .. name .. ".lua (" .. tostring(mod) .. ")")
        return nil
    end
    return mod
end

local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end

local okGraphs, LockGraphs = pcall(require, "lockgraphs")
if not okGraphs or type(LockGraphs) ~= "table" then
    log("ERROR in lockgraphs.lua, next-move hint unavailable ("
        .. tostring(LockGraphs) .. ")")
    LockGraphs, okGraphs = {}, false
end

local Num = tryRequire("num")
local Colors = tryRequire("colors")
local Engine = tryRequire("engine")
local Boost = tryRequire("boost")
local Solver = tryRequire("solver")
local Geometry = tryRequire("geometry") -- required transitively by session too
local Tinter = tryRequire("tinter")
local Session = tryRequire("session")

-- ----------------------------------------------------------------- config --
local BaseTries      = Config.baseTries or { untrained = 2, trained = 4, master = 6 }
local ExtraTries     = tonumber(Config.extraTries) or 10
local HotkeyName     = Config.nextMoveHotkey
local ConnHotkeyName = Config.connectionsHotkey
local DebugSolver    = Config.debugSolver == true

-- the only mutable feature flags, shared BY REFERENCE into the Session and
-- Tinter so a hotkey toggle propagates live
local flags = {
    nextMove = Config.showNextMove == true,
    connections = Config.showConnections == true,
}

-- the hint/connection features need the whole pure+engine chain plus the
-- graphs; boost only needs engine + num. A missing module disables exactly the
-- dependent feature.
local NextMoveBroken = not (Num and Colors and Engine and Solver and Geometry
    and Tinter and Session and okGraphs)
local BoostBroken = not (Boost and Engine and Num)
if NextMoveBroken then
    log("next-move hint and connection display unavailable (a required module "
        .. "failed to load)")
end

-- value -> tier lookup tables, built once
local Tiers = {} -- vanilla base -> { name, target }
local Targets = {} -- boosted target -> tier name
for name, base in pairs(BaseTries) do
    local target = base + ExtraTries
    Tiers[base] = { name = name, target = target }
    Targets[target] = name
end

-- the resolved palette (built once) and the shared collaborators
local palette = Colors and Colors.build(Config) or nil
local solverInstance = Solver and Solver.new({ log = log, debug = DebugSolver }) or nil
local tinterInstance = (Tinter and palette and Engine and Num)
    and Tinter.new(palette, Engine, Num) or nil

-- ----------------------------------------------------- live-session state --
-- main owns the single live-session slot and the spawn caches the start flow
-- reads; nothing here touches a stored object wrapper after eviction.
local liveSession = nil
local FreshPieces = {} -- piece actors by spawn time, see the notify below
local FreshAbility = nil -- the most recently spawned open/door ability
local FreshTask = nil -- the CURRENT minigame task (notify-captured)
local StartSnap = nil -- slot snapshot of the previous start attempt

-- off the input-dispatch path, on the game thread
local function schedule(ms, fn)
    ExecuteWithDelay(ms, function()
        ExecuteInGameThread(fn)
    end)
end

-- --------------------------------------------------------------- start flow --
-- The session ALWAYS runs while a minigame is open (state tracking is cheap);
-- the hotkey only toggles whether the green is painted.
local function tryStart(attempt)
    if NextMoveBroken or liveSession ~= nil then return end
    local lockName = Engine.currentLockName(FreshTask, FreshAbility)
    local graph = lockName and LockGraphs[lockName]
    if not graph then
        if lockName then
            log("No graph data for lock '" .. lockName .. "', next-move hint off")
        else
            log("Lock name not readable, next-move hint off for this lock")
        end
        return
    end
    -- THE SCRAMBLE ANIMATION GATE: at start the pieces may still be GLIDING
    -- into their scrambled columns. A baseline captured mid-glide poisons that
    -- piece's measured rotation for the whole session. Proceed only once two
    -- snapshots ~450ms apart agree for every slot.
    do
        local lib0, mpc0, scene0 = Engine.mpcHandles()
        if lib0 then
            local n = #graph.pieces
            local s0 = { lib = lib0, mpc = mpc0, scene = scene0 }
            local snap = {}
            for id = 0, n - 1 do
                snap[id] = Engine.readSlot(s0, id)
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
                    schedule(450, function() pcall(tryStart, attempt + 1) end)
                else
                    log("Lock pieces never settled, next-move hint off "
                        .. "for this lock")
                end
                return
            end
        end
    end
    -- only actors born for THIS minigame may be read: FindAllOf also returns the
    -- actors of earlier minigames, which contaminated the second lock of a run.
    -- Fresh spawns (NotifyOnNewObject) are authoritative; the subsystem array is
    -- next; the world-wide FindAllOf is the last resort.
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
        for _, sub in ipairs(Engine.liveInstances("LockPickSubsystem")) do
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
        actorList = Engine.liveInstances("GothicLockPieceActor")
        actorSrc = "FindAllOf (no fresh spawns, subsystem empty)"
    end
    if DebugSolver then
        log("solver: " .. #actorList .. " piece actors from " .. actorSrc)
    end
    -- build the session from the collected actors
    local session, reason = Session.start({
        lockName = lockName, graph = graph, actorList = actorList,
        engine = Engine, num = Num, solver = solverInstance, tinter = tinterInstance,
        flags = flags, log = log, debug = DebugSolver, schedule = schedule,
    })
    if session == nil then
        if reason == "retry" then
            -- too few pieces yet (still spawning): re-run the whole collection
            if attempt < 6 then
                schedule(500, function() tryStart(attempt + 1) end)
            else
                -- never fail wordlessly: a boost without a session banner once
                -- cost a debugging round
                log("Lock pieces not found, next-move hint off for this lock")
            end
        end
        return -- reason == "fail": already logged
    end
    local s = session
    -- main owns the live slot; the onStop closure frees it when this session
    -- ends, only if it is still the live one
    s.onStop = function() if liveSession == s then liveSession = nil end end
    liveSession = s
    s.tinter:retint(s)
    log(string.format("Next-move hint: %s, %d pieces, %d connections, first hint: %s",
        lockName, s.pieceCount, #graph.connections,
        s.nextMove and ("piece " .. s.nextMove.piece) or "none"))
    -- one lean poll tick (2.5x/s, cached references only): a session that is no
    -- longer the live one, or stopped, returns true and the loop ends
    LoopAsync(400, function()
        if liveSession ~= s or s.stop then return true end
        ExecuteInGameThread(function()
            local ok, err = pcall(function() s:tick() end)
            if not ok then
                s.stop = true
                if liveSession == s then liveSession = nil end
                log("Next-move hint error, stopping: " .. tostring(err))
            end
        end)
        return false
    end)
end

-- ------------------------------------------------------------------ toggles --
local lastToggle = 0
local function toggleHint()
    if NextMoveBroken then return end
    flags.nextMove = not flags.nextMove
    log("Next-move hint " .. (flags.nextMove and "ON" or "OFF"))
    local s = liveSession
    if s and not s.stop then s:onHintToggled() end
end

if type(HotkeyName) == "string" and HotkeyName ~= "" and not NextMoveBroken then
    if Key[HotkeyName] then
        pcall(RegisterKeyBind, Key[HotkeyName], function()
            -- debounce: rapid repeats and duplicate registrations after a hot
            -- reload once piled up planning tasks until UE4SS aborted
            local now = os.clock()
            if now - lastToggle < 0.3 then return end
            lastToggle = now
            ExecuteInGameThread(function() pcall(toggleHint) end)
        end)
    else
        log("ERROR: unknown nextMoveHotkey '" .. HotkeyName .. "', hotkey disabled")
    end
end

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
                    flags.connections = not flags.connections
                    log("Connection display " .. (flags.connections and "ON" or "OFF"))
                    local s = liveSession
                    if s and not s.stop then s:onConnectionsToggled() end
                end)
                if not ok then log("Connection toggle error: " .. tostring(err)) end
            end)
        end)
    else
        log("ERROR: unknown connectionsHotkey '" .. ConnHotkeyName
            .. "', hotkey disabled")
    end
end

-- ------------------------------------------------------------------- input --
-- selection tracking: the minigame task's Up/Down handlers fire via engine
-- dispatch (keyboard AND controller). Debounce duplicate registrations from hot
-- reloads with a TINY window (holding a key repeats at ~30ms; a wider window
-- swallowed every other step).
local lastSelStep = 0
local function onSelectionStep(delta)
    local now = os.clock()
    if now - lastSelStep < 0.005 then return end
    lastSelStep = now
    local s = liveSession
    if not s or s.stop then return end
    pcall(function() s:onSelectionStep(delta) end)
end

local function onMovePress(dir)
    local s = liveSession
    if not s or s.stop then return end
    pcall(function() s:onMovePress(dir) end)
end

-- resilient hook registration: RegisterHook fails when the UFunction is not
-- findable at registration time (an older game patch may lack a function, and
-- some UE4SS builds load mods before every class is reachable). Failures are
-- remembered and retried at minigame start, when the lock classes provably
-- exist; what still fails then gets ONE concise log line.
local PendingHooks = {}
local function tryHook(path, handler)
    if pcall(RegisterHook, path, handler) then return true end
    PendingHooks[path] = handler
    return false
end
local function retryPendingHooks()
    if not next(PendingHooks) then return end
    local missing = {}
    for path, handler in pairs(PendingHooks) do
        if pcall(RegisterHook, path, handler) then
            PendingHooks[path] = nil
        else
            missing[#missing + 1] = path
        end
    end
    if #missing > 0 then
        PendingHooks = {} -- give up for this boot, say so once
        table.sort(missing)
        log("Hooks unavailable on this game version (mod degrades "
            .. "gracefully): " .. table.concat(missing, ", "))
    end
end

if not NextMoveBroken then
    tryHook("/Script/G1R.AbilityTask_LockPick:UpPressed", function()
        pcall(onSelectionStep, 1)
    end)
    tryHook("/Script/G1R.AbilityTask_LockPick:DownPressed", function()
        pcall(onSelectionStep, -1)
    end)
    -- Left/Right presses feed the color-mapping MEASUREMENT only; refusals are
    -- detected from the game's own shake, never from press counting.
    tryHook("/Script/G1R.AbilityTask_LockPick:LeftPressed", function()
        pcall(onMovePress, -1)
    end)
    tryHook("/Script/G1R.AbilityTask_LockPick:RightPressed", function()
        pcall(onMovePress, 1)
    end)
    -- the open signal: combined with aligned pins at session death it marks a
    -- TRUE open position
    tryHook("/Script/G1R.AbilityTask_LockPick:TryOpenLock", function()
        pcall(function()
            local s = liveSession
            if s and not s.stop then
                s.openSignalT = os.clock()
                if DebugSolver then log("solver: TryOpenLock fired") end
            end
        end)
    end)
    -- the AUTHORITATIVE verdict signals: the C++ minigame broadcasts
    -- success/failure through these ability UFunctions. MemorizeLockpick rides
    -- along as a redundant non-replicated source; all are idempotent.
    local function onOpenSignal(src)
        local s = liveSession
        if s and not s.stop then
            s.openSignalT = os.clock()
            -- do NOT learn here: the final pin's animation is still mid-glide at
            -- signal time; the tick epilogue learns from settled slots
            s.opened = s.opened or os.clock()
            if DebugSolver then log("solver: OPEN signal: " .. src) end
        end
    end
    for _, fn in ipairs({
        "/Script/G1R.GameplayAbilityDoor:Server_SuccessLockEvent",
        "/Script/G1R.GameplayAbilityOpen:Server_SuccessLockEvent",
        "/Script/G1R.GameplayAbilityDoor:NetMulticast_OnSetLockUnlocked",
        "/Script/G1R.GameplayAbilityOpen:NetMulticast_OnSetLockUnlocked",
        "/Script/G1R.AbilityTask_LockPick:MemorizeLockpick",
    }) do
        tryHook(fn, function() pcall(onOpenSignal, fn) end)
    end
    for _, fn in ipairs({
        "/Script/G1R.GameplayAbilityDoor:Server_FailedLockEvent",
        "/Script/G1R.GameplayAbilityOpen:Server_FailedLockEvent",
    }) do
        tryHook(fn, function()
            pcall(function()
                local s = liveSession
                if s and not s.stop then
                    -- a fail = pick break, a re-scramble follows: the pins will
                    -- fly, evidence counters must not read the flight
                    s.atGoalTicks = 0
                    if DebugSolver then
                        log("solver: FAIL signal (pick broke): " .. fn)
                    end
                end
            end)
        end)
    end
end

-- world-change backstop: if a save is loaded, kill any session WITHOUT touching
-- stored object wrappers (they may dangle after the GC purge)
pcall(RegisterInitGameStatePostHook, function()
    local s = liveSession
    liveSession = nil
    if s then s.stop = true end
end)

-- --------------------------------------------------------------- triggers --
-- every piece actor spawn is recorded with its time: tryStart reads only actors
-- born for the current minigame
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

-- the minigame task spawn is our trigger: boost the tries, evict any stale
-- session, retry pending hooks, then start tracking after a short settle delay
local okNotify, errNotify = pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick",
    function(task)
        pcall(function()
            FreshTask = { obj = task, t = os.clock() }
            -- one minigame exists at a time: a NEW task is hard proof any
            -- tracked session is stale (its close signal was missed, or an
            -- opened lock's actors linger). Free the slot WITHOUT touching the
            -- old session's object wrappers.
            local stale = liveSession
            if stale then
                stale.stop = true
                liveSession = nil
                if DebugSolver then
                    log("solver: stale session evicted at minigame start")
                end
            end
            -- the lock classes provably exist now: re-register any hooks that
            -- failed at boot
            retryPendingHooks()
        end)
        if not BoostBroken then
            local ok, err = pcall(function()
                Boost.apply(Tiers, Targets, Engine, Num, log)
            end)
            if not ok then log("Boost error: " .. tostring(err)) end
        end
        if not NextMoveBroken then
            schedule(900, function()
                local ok2, err2 = pcall(tryStart, 1)
                if not ok2 then log("Next-move hint error: " .. tostring(err2)) end
            end)
        end
    end)
if not okNotify then
    log("ERROR: could not register minigame notification: " .. tostring(errNotify))
end

-- ----------------------------------------------------------------- banner --
local loaded = {}
for name, base in pairs(BaseTries) do
    loaded[#loaded + 1] = string.format("%s %d->%d", name, base, base + ExtraTries)
end
local graphCount = 0
for _ in pairs(LockGraphs) do graphCount = graphCount + 1 end
local hintInfo = ", next-move hint unavailable"
if not NextMoveBroken then
    hintInfo = string.format(", next-move hint %s (%d lock graphs%s)",
        flags.nextMove and "on" or "off", graphCount,
        (type(HotkeyName) == "string" and HotkeyName ~= "" and Key[HotkeyName])
        and (", toggle: " .. HotkeyName) or "")
    hintInfo = hintInfo .. string.format(", connection display %s%s",
        flags.connections and "on" or "off",
        (type(ConnHotkeyName) == "string" and ConnHotkeyName ~= ""
            and Key[ConnHotkeyName])
        and (", toggle: " .. ConnHotkeyName) or "")
end
log("Loaded " .. ModVersion .. ": " .. table.concat(loaded, ", ") .. hintInfo)
