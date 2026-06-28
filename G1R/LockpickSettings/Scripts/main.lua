-- LockpickSettings for Gothic 1 Remake -- thin orchestrator: requires the modules,
-- wires them to the engine events, owns ALL registration. See CONTRIBUTING.md.
-- Features: extra durability (tries/), next-move hint + connection display
-- (nextmove/ connections/ core/), auto-solve (autosolve/, shipped policy lookup).

-- UE4SS shares one Lua state across mods; capture stdlib as locals so a clobbered
-- global can't break us.
local ipairs, pairs, tostring, tonumber = ipairs, pairs, tostring, tonumber
local type, pcall, print, require, next = type, pcall, print, require, next
local rawget, rawset, debug = rawget, rawset, debug
local setmetatable = setmetatable
local math, table, string, os = math, table, string, os

local ModVersion = "4.1.2"

-- vendored kit lives at <Mod>/shared/, not on UE4SS's search path; add it from this
-- file's own location. ModDir = the mod folder (parent of Scripts/).
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;"
        .. ModDir .. "/shared/?.lua;" .. package.path
end

-- hot reload: CTRL+R re-runs this chunk. nil every module before the first require,
-- and full-sweep ue4ss_loaded_modules (keyed by absolute path, so a bare-name nil is
-- a no-op there).
local MODULES = {
    "kit", "config", "core.engine_lock", "core.session", "core.tinter",
    "core.settings", "util.palette", "util.inflate", "util.bytes",
    "data.lockgraphs", "data.lockpolicies", "data.lockpolicies_index",
    "tries.boost", "nextmove.policy", "nextmove.geometry", "nextmove.hint",
    "connections.connections", "autosolve.driver", "autosolve.edgemap",
}
for _, m in ipairs(MODULES) do package.loaded[m] = nil end
do
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then
        for k in pairs(reg) do reg[k] = nil end
    end
end

local okKit, kit = pcall(require, "kit")
if not okKit or type(kit) ~= "table" then
    print("[LockpickSettings] FATAL: shared kit not found (" .. tostring(kit)
        .. "). Re-deploy; the kit vendors under <Mod>/shared/.\n")
    return
end
local log = kit.log.make("[LockpickSettings]")
local Num = kit.num

-- Game-thread scheduling: prefer kit.async (Delayed Action System fast path, RE-UE4SS
-- #1180-safe). An older vendored kit may lack it, so fall back to the legacy nested
-- pattern inline (carries the #1180 risk on pre-988 builds, but never hard-breaks).
local Async = kit.async
if not (Async and Async.gameLoop and Async.gameDelay) then
    Async = {
        gameDelay = function(ms, fn)
            ExecuteWithDelay(ms, function() ExecuteInGameThread(function() pcall(fn) end) end)
        end,
        gameLoop = function(ms, decide)
            local stopped, ticking = false, false
            LoopAsync(ms, function()
                if stopped then return true end
                local ok, work = pcall(decide)
                if not ok or work == true then stopped = true; return true end
                if type(work) == "function" then
                    if ticking then return false end
                    ticking = true
                    ExecuteInGameThread(function() pcall(work); ticking = false end)
                end
                return false
            end)
            return function() stopped = true end
        end,
    }
end
log("Scheduling via " .. ((kit.async and kit.async.hasGameThreadTimers)
    and "game-thread timers (Delayed Action System, #1180-safe)"
    or "legacy LoopAsync fallback"))

-- each require pcall-wrapped; a broken child disables only its feature.
local function tryRequire(name) return kit.boot.tryRequire(name, log) end

local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end

-- saved_settings.lua (menu/hotkey adjustments) overrides config defaults; merge it
-- over Config before the values are read. saveSettings (below) writes it back.
local Settings = tryRequire("core.settings")
local SavedPath = ModDir and (ModDir .. "/saved_settings.lua") or nil
local SAVED_KEYS = {
    "showNextMove", "showConnections", "autoSolveEvery",
    "autoSolveAnimationSpeed", "autoSolveTickMs", "extraTries",
    "immersiveMode", "lockpicksPerConnection", "lockpickCostMin", "lockpickCostMax",
    "skilledAtConnections", "masterAtConnections",
    "autoSolveLockpickCost",
    "oreReward", "orePerConnection", "oreRewardMin", "oreRewardMax",
    "showTooltip", "showNotifications",
}
if Settings and SavedPath then
    local saved = Settings.load(SavedPath)
    for _, key in ipairs(SAVED_KEYS) do
        if saved[key] ~= nil then Config[key] = saved[key] end
    end
end

-- A few locks differ in case between the decoded descriptor name we key the data by and
-- the instance name the live game reports (descriptor OC_Chest_CUTTER_Lock vs live
-- OC_Chest_Cutter_Lock). Give a name->data table a case-insensitive fallback: exact-case
-- keys still hit directly (the __index runs only on a miss), then the name is folded to
-- lower case and retried once against a pre-built fold map.
local function withCaseFallback(t)
    if type(t) ~= "table" then return t end
    local folded = {}
    for k, v in pairs(t) do
        if type(k) == "string" then folded[k:lower()] = v end
    end
    return setmetatable(t, { __index = function(_, k)
        return type(k) == "string" and folded[k:lower()] or nil
    end })
end

-- the mod SHIPS the lock graphs (data/lockgraphs.lua) as the state of truth;
-- regenerate on a game update with tools/livegraphs.lua. No data = no hint/connections.
local LockGraphs, okGraphs, graphSource = {}, false, "none"
local okData, Data = pcall(require, "data.lockgraphs")
if okData and type(Data) == "table" and next(Data) then
    LockGraphs, okGraphs, graphSource = withCaseFallback(Data), true, "bundled"
else
    log("ERROR: bundled lock graphs (data/lockgraphs.lua) failed to load; next-move "
        .. "hint and connection display off (" .. tostring(Data) .. ")")
end

local Engine = tryRequire("core.engine_lock")
local Palette = tryRequire("util.palette")
local Boost = tryRequire("tries.boost")
local PolicyMod = tryRequire("nextmove.policy")
local Geometry = tryRequire("nextmove.geometry")
local Hint = tryRequire("nextmove.hint")
local Connections = tryRequire("connections.connections")
local Tinter = tryRequire("core.tinter")
local Session = tryRequire("core.session")
local Driver = tryRequire("autosolve.driver")
local EdgeMap = tryRequire("autosolve.edgemap")
local Cost = tryRequire("immersive.cost")

-- shipped solution policies: data/lockpolicies.lua (DEFLATE next-move tables per lock
-- x precision variant, built by tools/build_policies.py) + lockpolicies_index. Shipped
-- as a Lua integer array so scanners read it as data, not an opaque binary or obfuscated
-- string. Reconstructed once at boot; one lock's variant is inflated on open and looked up.
local Policy = nil
do
    local okIdx, Index = pcall(require, "data.lockpolicies_index")
    local blob = nil
    pcall(function()
        local ints = require("data.lockpolicies")
        if type(ints) == "table" then blob = require("util.bytes").fromInts(ints) end
    end)
    -- ROOT-CAUSE FIX for the intermittent chest-open crash: require() CACHES its return value,
    -- so the ~1.29M-element integer table from data/lockpolicies would stay resident in
    -- package.loaded and Lua's GC would re-scan all 1.29M entries every cycle. That heavy GC
    -- raced UE4SS's object marshaling and caused the crash. Drop the cache and reclaim it now;
    -- only the compact ~1.3MB blob STRING (a single cheap GC object) stays resident.
    package.loaded["data.lockpolicies"] = nil
    collectgarbage("collect")
    -- Switch this mod's Lua state to GENERATIONAL GC for the play session. This is a pure Lua
    -- 5.4 collector mode (collectgarbage is stdlib, NOT a UE4SS setting; the call goes straight
    -- to the embedded Lua VM, which UE4SS neither honors-as-config nor reverts). Generational
    -- does cheap MINOR collections that scan only young objects, so short-lived garbage -- the
    -- per-open inflate's multi-MB table, per-tick scratch -- is reclaimed WITHOUT rescanning the
    -- resident policy blob / lock graphs / index every cycle. That per-cycle full rescan (the
    -- incremental-mode default) is the GC cost that raced UE4SS's object marshaling and drove the
    -- chest-open AVs. Each mod runs in its OWN isolated Lua state, so this only affects
    -- LockpickSettings. pcall-guarded so a Lua build without the mode degrades to the default;
    -- revert by deleting this line (or collectgarbage("incremental")).
    if pcall(collectgarbage, "generational") then
        log("GC: generational mode (cheap minor collections; resident policy data not rescanned)")
    else
        log("Note: generational GC unavailable, using the default collector")
    end
    if PolicyMod and okIdx and type(Index) == "table" and blob and #blob > 0 then
        Policy = PolicyMod.new({
            index = withCaseFallback(Index), log = log,
            readBlob = function(off, len) return blob:sub(off + 1, off + len) end,
        })
    else
        log("ERROR: shipped policies (data/lockpolicies + _index) not loaded; "
            .. "next-move hint and auto-solve off for this session")
    end
end

local ExtraTries = Config.extraTries
if type(ExtraTries) ~= "table" then
    ExtraTries = { untrained = 5, trained = 10, master = 20 }
end
local HotkeyName     = Config.nextMoveHotkey
local ConnHotkeyName = Config.connectionsHotkey
local DebugSolver    = Config.debugSolver == true
local AutoKey        = Config.autoSolveHotkey
local EdgeMapKey     = Config.debugEdgeMapHotkey
local AutoEveryMod   = Config.autoSolveEveryModifier
local AutoEveryDefault = Config.autoSolveEvery == true

-- animation speed = visual move glide (clamped 10..500); purely cosmetic.
local AutoAnimSpeed = Config.autoSolveAnimationSpeed
if type(AutoAnimSpeed) ~= "number" then AutoAnimSpeed = 250 end
if AutoAnimSpeed < 10 then AutoAnimSpeed = 10 elseif AutoAnimSpeed > 500 then AutoAnimSpeed = 500 end

-- after this many auto-solve give-ups on the SAME live lock, main stops re-arming the driver on
-- it. A lock whose live wiring disagrees with our precision variant can never be auto-solved, and
-- re-driving it just breaks lockpicks and can wedge the minigame. Reopen the chest (a fresh
-- session resets the count) or pick it manually.
local AUTO_FAIL_CAP = 1

-- POLL_MS = the loop's fixed base wake. TickRateMs = auto-solve move rate: fast
-- solve marshals a tick every round(TickRateMs/POLL_MS) wakes. Each tick is one
-- ExecuteInGameThread onto UE4SS's buggy deferred queue (#1180), so a LOWER value is
-- faster but more crash-prone. Mutable (live from the menu); keeping POLL_MS fixed
-- lets the menu re-time solving without re-registering the loop.
local POLL_MS = 25
local POLL_NORMAL_EVERY = math.max(1, math.floor(400 / POLL_MS + 0.5)) -- ~400ms normal
local TickRateMs = Config.autoSolveTickMs
if type(TickRateMs) ~= "number" then TickRateMs = 100 end
if TickRateMs < 25 then TickRateMs = 25 elseif TickRateMs > 500 then TickRateMs = 500 end

-- mutable feature flags, shared BY REFERENCE into Session/Tinter so a toggle propagates
local flags = {
    nextMove = Config.showNextMove == true,
    connections = Config.showConnections == true,
}
local autoEvery = AutoEveryDefault -- full-auto-every-lock; main owns this runtime flag

-- persist the current settings (snapshots all values, so a change via any path sticks)
local function saveSettings()
    if not (Settings and SavedPath) then return end
    Settings.save(SavedPath, {
        showNextMove = flags.nextMove,
        showConnections = flags.connections,
        autoSolveEvery = autoEvery,
        autoSolveAnimationSpeed = AutoAnimSpeed,
        autoSolveTickMs = TickRateMs,
        extraTries = {
            untrained = ExtraTries.untrained or 0,
            trained = ExtraTries.trained or 0,
            master = ExtraTries.master or 0,
        },
        immersiveMode = Config.immersiveMode,
        lockpicksPerConnection = Config.lockpicksPerConnection,
        lockpickCostMin = Config.lockpickCostMin,
        lockpickCostMax = Config.lockpickCostMax,
        skilledAtConnections = Config.skilledAtConnections,
        masterAtConnections = Config.masterAtConnections,
        autoSolveLockpickCost = Config.autoSolveLockpickCost,
        oreReward = Config.oreReward,
        orePerConnection = Config.orePerConnection,
        oreRewardMin = Config.oreRewardMin,
        oreRewardMax = Config.oreRewardMax,
        showTooltip = Config.showTooltip,
        showNotifications = Config.showNotifications,
    })
end

local NextMoveBroken = not (Engine and Palette and Policy and Geometry and Hint
    and Connections and Tinter and Session and okGraphs)
local BoostBroken = not (Boost and Engine)
if NextMoveBroken then
    log("next-move hint and connection display unavailable (a required module "
        .. "failed to load)")
end
local AutoSolveBroken = NextMoveBroken or not Driver
if not NextMoveBroken and not Driver then
    log("auto-solve unavailable (autosolve/driver.lua failed to load)")
end

local palette = Palette and Palette.build(Config) or nil
local tinterInstance = (Tinter and palette and Engine and Hint and Connections)
    and Tinter.new(palette, Engine, Num, Hint.color, Connections.partnerTints) or nil

-- main owns the single live-session slot and the notify spawn caches.
local liveSession = nil
local FreshTask = nil   -- the CURRENT minigame task
local StartSnap = nil   -- previous start attempt's slot snapshot (scramble gate)
local OpenedLocks = {}  -- locks opened this session; cleared on world change
-- consecutive geometry-read failures per lock. An already-unlocked or stale chest fails
-- every open, so after GEOM_FAIL_CACHE_AT we cache it into OpenedLocks to skip the scan; a
-- one-off bad read on a still-locked chest stays uncached and retries next open. Cleared on
-- world change.
local GeometryFails = {}
local GEOM_FAIL_CACHE_AT = 3
-- live GothicLockPieceActor handles, filled by the construction notify (below) and reused
-- on every open so the hot path does NO world-wide FindAllOf. The ~21 pieces are pre-pooled
-- in PersistentLevel and stable for the world; cleared on a world change.
local PiecePool = {}

-- the auto-solver. getTask returns nil once the lock is opening, so a press never
-- dereferences a tearing-down task (native AV pcall can't catch).
local driver = (not AutoSolveBroken) and Driver.new({
    engine = Engine,
    getTask = function()
        local s = liveSession
        if not s or s.stop or s.opened then return nil end
        return s.task
    end,
    log = log,
    debug = DebugSolver,
    speed = AutoAnimSpeed,
}) or nil

-- DEV diagnostic (debug-gated key): maps the live lock's active edges and compares them to the
-- shipped variants, to explain a "disagrees with the precision variant" lock. Inert until armed.
local edgemap = (EdgeMap and not NextMoveBroken) and EdgeMap.new({
    engine = Engine,
    getTask = function()
        local s = liveSession
        if not s or s.stop or s.opened then return nil end
        return s.task
    end,
    getGraph = function(name) return name and LockGraphs[name] or nil end,
    log = log,
}) or nil

-- run fn on the game thread after ms (one-shot delay). Routes through kit.async so it
-- takes the no-nesting Delayed Action System path when the build has it.
local function schedule(ms, fn)
    Async.gameDelay(ms, fn)
end

-- a lock is "auto-capped" once the driver has given up on it AUTO_FAIL_CAP times this session;
-- main then refuses to re-arm the driver on it (see AUTO_FAIL_CAP).
local function autoCapped(s)
    return s ~= nil and (s.autoFails or 0) >= AUTO_FAIL_CAP
end

-- --------------------------------------------------------------- start flow --
-- Cost gate for STARTING an auto-solve. Forward-declared because tryStart's full-auto drive below
-- uses it; the body is assigned just above doAutoToggle. Returns true to proceed (cost already spent),
-- false to refuse (s.autoStop carries the reason for the readout).
local chargeForSolve

-- transient on-screen feedback via the kit's snackbar (no-op if the kit lacks it or it is unbound)
local function toast(text, kind)
    if Config.showNotifications ~= false and kit.snackbar then
        pcall(kit.snackbar.show, text, { kind = kind })
    end
end

local function tryStart(attempt)
    if NextMoveBroken or liveSession ~= nil then return end
    -- A truly-ended task (an already-open chest whose task the game tore down) bails here with
    -- no scan. The task can also LINGER as valid on a re-open; the OpenedLocks gate below catches
    -- that case before any scan too.
    if not (FreshTask and FreshTask.obj) then return end
    do local ok = false; pcall(function() ok = FreshTask.obj:IsValid() end); if not ok then return end end
    local lockName = Engine.currentLockName(FreshTask, nil)
    local graph = lockName and LockGraphs[lockName]
    if not graph then
        if lockName then
            log("No graph data for lock '" .. lockName .. "', next-move hint off")
        else
            log("Lock name not readable, next-move hint off for this lock")
        end
        return
    end
    -- Already opened this session = a re-open, not a minigame. Bail BEFORE any scan (mpcHandles,
    -- FindAllOf) and before Boost. This is the gate that actually stops the work on a re-open.
    if OpenedLocks[lockName] then
        if DebugSolver then
            log("solver: '" .. lockName .. "' already opened this session, skipping (no scans)")
        end
        return
    end
    -- Boost the tries for THIS minigame. Moved here from the spawn notify so a re-open (caught
    -- above) never pays for Boost's FindAllOf. Idempotent.
    if not BoostBroken then
        local okB, errB = pcall(function() Boost.apply(ExtraTries, Engine, Num, log) end)
        if not okB then log("Boost error: " .. tostring(errB)) end
    end
    -- resolve the MPC/scene handles ONCE per open (mpcHandles does a ~30ms FindAllOf):
    -- reused by the scramble gate and handed to Session.start, so the scan runs once.
    local lib, mpc, scene = Engine.mpcHandles()
    -- Are we actually in a minigame? mpcHandles resolves only when a live lock SCENE
    -- exists, which happens only during the minigame. An already-unlocked chest still
    -- spawns the lockpick task (so we reach here) but has no scene and allows no pick.
    -- No scene means no minigame: bail before the piece scans, so we never run the
    -- world-wide FindAllOf (the major lag) or read the chest's dead lock objects (a
    -- native crash). Retry a couple of times in case the scene is just slow to spawn.
    if not lib then
        if attempt < 3 then
            schedule(450, function() pcall(tryStart, attempt + 1) end)
        elseif DebugSolver then
            log("No lock scene, not a minigame (already-open chest?), skipping '"
                .. tostring(lockName) .. "'")
        end
        return
    end
    -- SCRAMBLE GATE: pieces may still be gliding into their scrambled columns; a
    -- baseline read mid-glide poisons that piece for the session. Proceed only once
    -- two snapshots ~450ms apart agree.
    do
        if lib then
            local n = #graph.pieces
            local s0 = { lib = lib, mpc = mpc, scene = scene }
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
    -- Piece actors come from PiecePool, filled event-driven by the GothicLockPieceActor
    -- construction notify (re-measured 2026-06-18: that notify DOES fire for all ~21 pre-pooled
    -- pieces, a few seconds after world load; the old "never fires" note was a load-time/hot-
    -- reload timing artifact). So the hot path does NO world-wide FindAllOf. Use the live pool
    -- entries; only if the pool cannot satisfy this lock (opened before the pieces constructed,
    -- or a missed notify) fall back to one scan for this open. Session.start IsValid-gates each.
    local actorList, source = {}, "pool"
    for _, a in ipairs(PiecePool) do
        if Engine.isValid(a) then actorList[#actorList + 1] = a end
    end
    if #actorList < #graph.pieces then
        -- The pool fills from the GothicLockPieceActor construction notify, which LAGS world
        -- load (worse on slow machines, or a beeline to the first lock after an area change).
        -- Falling straight to a world-wide FindAllOf here walks a possibly-still-constructing
        -- object array, the native-AV surface behind cold first-open crashes. Wait for the pool
        -- a few times first; FindAllOf stays ONLY as the last resort once it clearly never fills.
        if attempt < 10 then
            if DebugSolver then
                log("solver: piece pool not ready (" .. #actorList .. "/" .. #graph.pieces
                    .. "), waiting before any world scan (attempt " .. attempt .. ")")
            end
            schedule(450, function() pcall(tryStart, attempt + 1) end)
            return
        end
        actorList = Engine.liveInstances("GothicLockPieceActor")
        source = "FindAllOf fallback (pool never filled)"
    end
    if DebugSolver then
        log("solver: " .. #actorList .. " piece actors (" .. source .. ")")
    end
    -- LockpickPrecision = how many connections the game pruned (the first k); the session
    -- inflates that precomputed variant lazily on its first tick, NOT here in the open
    -- dispatch (the inflate's multi-MB GC spike must stay clear of UE4SS's open-time
    -- object marshaling; see session.ensurePolicy).
    -- The game removes the first round(LockpickPrecision.CurrentValue) connections at minigame
    -- setup (confirmed by reversing UAbilityTask_LockPick: skip = round(max(precision, 0)), NO cap
    -- in code). In practice LockpickPrecision is the 0/1/2 skill value and is NOT raised mid-game
    -- or on a broken pick, so k is 0, 1, or 2 -- the three shipped variants.
    local attrs = Engine.lockpickAttributes()
    local k = math.floor((attrs and attrs.precision or 0) + 0.5)
    if k < 0 then k = 0 elseif k > 2 then k = 2 end
    if DebugSolver then
        log(string.format("lock '%s': precision=%s durability=%s -> variant %d "
            .. "(policy inflates on first move, off the open dispatch)", lockName,
            tostring(attrs and attrs.precision),
            tostring(attrs and attrs.durability), k))
    end
    local session, reason = Session.start({
        lockName = lockName, graph = graph, actorList = actorList,
        engine = Engine, num = Num, policySource = Policy, precisionK = k,
        handles = lib and { lib = lib, mpc = mpc, scene = scene } or nil,
        tinter = tinterInstance,
        flags = flags, log = log, debug = DebugSolver, schedule = schedule,
        unreliableActors = true,  -- always world-wide FindAllOf now (may include stale actors)
    })
    if session == nil then
        if reason == "retry" then
            if attempt < 6 then
                schedule(500, function() tryStart(attempt + 1) end)
            else
                log("Lock pieces not found, next-move hint off for this lock")
            end
        end
        return -- reason == "fail": already logged
    end
    local s = session
    -- stale re-entry guard: actors from FindAllOf with no readable geometry = EITHER an
    -- already-unlocked/stale chest (fails every open) OR a transient bad read on a still-locked
    -- chest. We must not cache the latter, or one bad read disables this lock for the whole
    -- world. Count failures per lock and only cache after a few, so a real lock retries; an
    -- already-unlocked chest still stops scanning after GEOM_FAIL_CACHE_AT opens.
    if s.stateUnknown then
        local fails = (GeometryFails[lockName] or 0) + 1
        GeometryFails[lockName] = fails
        if fails >= GEOM_FAIL_CACHE_AT then
            OpenedLocks[lockName] = true
            log("Skipping tracking for '" .. lockName .. "': no readable geometry after "
                .. fails .. " opens (already-unlocked or stale actors); caching so re-opens skip the scan")
        elseif DebugSolver then
            log("solver: '" .. lockName .. "' geometry not readable (open " .. fails .. "/"
                .. GEOM_FAIL_CACHE_AT .. "), will retry on the next open")
        end
        return
    end
    GeometryFails[lockName] = nil  -- geometry read fine this open; clear any prior transient failures
    -- bind THIS minigame's task: its death is the authoritative "minigame over" signal
    -- (an opened lock's piece/scene actors linger for minutes).
    s.task = FreshTask
    s.onStop = function() if liveSession == s then liveSession = nil end end
    liveSession = s
    s.connectionCount = #graph.connections -- lock difficulty: Immersive Mode's cost + skill scale off it
    s.tinter:retint(s)
    log(string.format("Next-move hint: %s, %d pieces, %d connections, first hint: %s",
        lockName, s.pieceCount, #graph.connections,
        s.nextMove and ("piece " .. s.nextMove.piece) or "none"))
    -- full-auto: drive this lock the instant it's tracked, when usable (and not already given up on).
    -- Suppressed in Immersive Mode -- there a solve must be a deliberate F6. Outside it, each driven
    -- lock pays the flat auto-solve cost via chargeForSolve (which refuses if you are short on picks).
    if autoEvery and Config.immersiveMode ~= true and driver and not s.stateUnknown and s.hintGeometry
        and not autoCapped(s) and chargeForSolve(s) then
        pcall(function() driver:toggleFast(s) end)
    end
end

-- ------------------------------------------------------------------ toggles --
-- The toggle ACTIONS, run on the game thread (keybind marshals via ExecuteInGameThread;
-- the menu set() callbacks call these too, so keys and menu stay in lockstep).
-- Mode exclusivity: a display toggle stops any auto-solve first (one active execution).
-- Keybinds do NOT run their action inline. Each sets a flag here; the ONE session-loop
-- game-thread pass drains them (see the loop). This is the #1180 fix: every keybind used to do
-- its own ExecuteInGameThread, and mashing F6/F7/F8 collided those on UE4SS's deferred queue (and
-- with the loop's own pass) -> "Abort signal received". One dispatcher = no collision. Flags are
-- set on the keybind thread and drained on the game thread; booleans, so the cross-thread write
-- is safe. The per-key 0.3s debounce below still kills held-key repeat.
local Pending = { hint = false, conn = false, auto = false, every = false, diag = false }
local lastToggle = 0
local function cancelDriverFor(s)
    if driver and s and not s.stop and driver:running() then
        driver:finish(s, "stopped: a display was toggled", false, false) -- UI cancel, not a give-up
    end
end

local function toggleHint()
    if NextMoveBroken then return end
    cancelDriverFor(liveSession)
    flags.nextMove = not flags.nextMove
    log("Next-move hint " .. (flags.nextMove and "ON" or "OFF"))
    local s = liveSession
    if s and not s.stop then s:onHintToggled() end
    saveSettings()
end

local function doConnToggle()
    local ok, err = pcall(function()
        cancelDriverFor(liveSession)
        flags.connections = not flags.connections
        log("Connection display " .. (flags.connections and "ON" or "OFF"))
        local s = liveSession
        if s and not s.stop then s:onConnectionsToggled() end
        saveSettings()
    end)
    if not ok then log("Connection toggle error: " .. tostring(err)) end
end

-- Charge for STARTING an auto-solve. Immersive Mode: a difficulty-scaled lockpick cost plus a skill
-- gate. Otherwise: a flat per-solve lockpick cost (autoSolveLockpickCost) if configured. Spends the
-- cost and returns true to proceed, or returns false to refuse. s.autoStop records why ("skill",
-- "picks" for the immersive gate, "flat" for the plain auto-solver) so the readout can show it.
chargeForSolve = function(s)
    if not s then return false end
    s.autoStop = nil
    if Config.immersiveMode == true and Cost and s.connectionCount then
        local attrs = Engine.lockpickAttributes()
        local precision = attrs and attrs.precision
        local picks = Engine.itemCount(Config.lockpickItem)
        local ok, hasSkill, _, req, cost = Cost.evaluate(s.connectionCount, precision, picks, Config)
        if not ok then
            s.autoStop = hasSkill and "picks" or "skill"
            s.autoStopReq, s.autoStopCost, s.autoStopHave = req, cost, picks
            if not hasSkill then
                log("Immersive: this lock needs " .. Cost.skillName(req) .. " picklock skill to auto-solve")
            else
                log(string.format("Immersive: not enough lockpicks (need %d, have %s)", cost, tostring(picks)))
            end
            return false
        end
        if cost > 0 and picks ~= nil then
            Engine.spendItem(Config.lockpickItem, cost)
            s.readoutPicks = nil -- re-read the reduced count so the readout updates during the solve
            s.spentPicks = (s.spentPicks or 0) + cost -- shown on a successful open, not on the F6 press
        end
        return true
    end
    local need = Config.autoSolveLockpickCost or 0
    if need > 0 then
        local picks = Engine.itemCount(Config.lockpickItem)
        if picks ~= nil and picks < need then
            s.autoStop = "flat"
            s.autoStopCost, s.autoStopHave = need, picks
            log(string.format("Auto Solver stopped: not enough lockpicks (need %d, have %d)", need, picks))
            return false
        end
        if picks ~= nil then
            Engine.spendItem(Config.lockpickItem, need)
            s.spentPicks = (s.spentPicks or 0) + need
        end
    end
    return true
end

-- F6: solve the current lock now (or cancel an in-progress solve). A manual press is a deliberate
-- retry, so unlike the unattended full-auto re-arm it IGNORES the give-up cap: it clears autoFails
-- and re-engages from the current live state (the lock has usually advanced since the solver
-- stopped, so the next pass gets further). The cap still governs full-auto re-arm, so unattended
-- solving never churns picks on an unsolvable lock. Only this explicit press overrides it.
local function doAutoToggle()
    if not driver then return end
    local s = liveSession
    if s and not driver:running() then
        if not chargeForSolve(s) then return end -- refused (cost/skill); s.autoStop set for the readout
        s.autoFails = 0
    end
    pcall(function() driver:toggleFast(s) end)
end

-- F10 (debug only): map the live lock's edges to explain a "disagrees" lock (see edgemap.lua)
local function doEdgeMap()
    if not edgemap then return end
    local s = liveSession
    if not s or s.stop then log("EdgeMap: no active lock"); return end
    if driver and driver:running() then log("EdgeMap: stop auto-solve (F6) first"); return end
    edgemap:start(s)
end

-- Shift+F6: flip full-auto-every-lock, arming/cancelling the current lock to match
local function doEveryToggle()
    if not driver then return end
    pcall(function()
        if Config.immersiveMode == true then
            -- Shift+F6 switches OUT of Immersive Mode into the auto solver (they are mutually exclusive).
            Config.immersiveMode = false
            autoEvery = true
            log("Immersive Mode off, Full-auto (every lock) ON (Shift+F6)")
        else
            autoEvery = not autoEvery
            log("Full-auto (every lock) " .. (autoEvery and "ON" or "OFF"))
        end
        local s = liveSession
        if autoEvery then
            if s and not s.stop and not s.opened and not s.stateUnknown
                and s.hintGeometry and not driver:running() and not autoCapped(s) and chargeForSolve(s) then
                driver:toggleFast(s)
            end
        elseif driver:running() then
            driver:toggleFast(s)
        end
        saveSettings()
    end)
end

-- keybinds debounce per-key (0.3s, kills held-key repeat), then set a Pending flag the session
-- loop drains on its one game-thread pass (no per-keybind ExecuteInGameThread; see Pending above).
if type(HotkeyName) == "string" and HotkeyName ~= "" and not NextMoveBroken then
    if Key[HotkeyName] then
        pcall(RegisterKeyBind, Key[HotkeyName], function()
            local now = os.clock()
            if now - lastToggle < 0.3 then return end
            lastToggle = now
            Pending.hint = true
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
            Pending.conn = true
        end)
    else
        log("ERROR: unknown connectionsHotkey '" .. ConnHotkeyName
            .. "', hotkey disabled")
    end
end

local ModifierKey = rawget(_G, "ModifierKey")
local lastAutoSolve, lastAutoEvery = 0, 0
if driver and type(AutoKey) == "string" and AutoKey ~= "" and Key[AutoKey] then
    pcall(RegisterKeyBind, Key[AutoKey], function()
        local now = os.clock()
        if now - lastAutoSolve < 0.3 then return end
        lastAutoSolve = now
        Pending.auto = true
    end)
    if type(AutoEveryMod) == "string" and AutoEveryMod ~= "" then
        local mod = ModifierKey and ModifierKey[AutoEveryMod]
        if not mod then
            log("ERROR: unknown autoSolveEveryModifier '" .. AutoEveryMod
                .. "', full-auto-every-lock toggle disabled")
        else
            local ok = pcall(RegisterKeyBind, Key[AutoKey], { mod }, function()
                local now = os.clock()
                if now - lastAutoEvery < 0.3 then return end
                lastAutoEvery = now
                Pending.every = true
            end)
            if not ok then
                log("ERROR: could not register full-auto-every-lock toggle")
            end
        end
    end
elseif driver and type(AutoKey) == "string" and AutoKey ~= "" then
    log("ERROR: unknown autoSolveHotkey '" .. tostring(AutoKey)
        .. "', auto-solve disabled")
end

-- DEV diagnostic key, only when debugSolver is on: maps the live lock's edges. Flag-only like the
-- others; the session loop drains Pending.diag on its one game-thread pass.
local lastEdgeMap = 0
if DebugSolver and edgemap and type(EdgeMapKey) == "string" and EdgeMapKey ~= "" then
    if Key[EdgeMapKey] then
        pcall(RegisterKeyBind, Key[EdgeMapKey], function()
            local now = os.clock()
            if now - lastEdgeMap < 0.3 then return end
            lastEdgeMap = now
            Pending.diag = true
        end)
        log("Debug: edge-map diagnostic armed on " .. EdgeMapKey)
    else
        log("ERROR: unknown debugEdgeMapHotkey '" .. EdgeMapKey .. "', edge-map diagnostic disabled")
    end
end


-- ------------------------------------------------------------------- input --
-- selection tracking off the task's Up/Down handlers (keyboard AND controller). Tiny
-- RegisterHook can fail when a UFunction isn't reachable yet; remember failures and
-- retry at minigame start, then log once what still fails.
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
        PendingHooks = {}
        table.sort(missing)
        log("Hooks unavailable on this game version (mod degrades "
            .. "gracefully): " .. table.concat(missing, ", "))
    end
end

if not NextMoveBroken then
    -- We register NO hook on any UFunction the auto-solver triggers. The driver presses
    -- Up/Down/Left/Right, and those presses run the game's turn/open logic synchronously, so a
    -- hook on a driven function fires REENTRANTLY: the game calls back into the SAME Lua state
    -- to run our hook while UE4SS is still mid-flight executing our queued async tick
    -- (process_simple_actions). That corrupts the shared Lua stack and aborts on the next
    -- queued action ("Abort signal received", #1180), nearly instantly after a lock opens. This
    -- already cost us the four directional hooks. The open hooks (TryOpenLock, MemorizeLockpick)
    -- had the SAME flaw, since the driver's winning press is what fires them, so they are gone
    -- too. Open detection is now the session's own settled measurement (every pin at the bar
    -- column = open; see session.lua), which re-enters nothing.
    --
    -- BackPressed is the ONE safe hook: we never press Back, so it fires only on a real player
    -- exit from the game's own input frame, never nested inside our callback. It stops the
    -- session and any solve at once, before the task tears down, so nothing presses a dying task.
    tryHook("/Script/G1R.AbilityTask_LockPick:BackPressed", function()
        pcall(function()
            local s = liveSession
            if not s or s.stop then return end
            if driver and driver:running() then
                driver:finish(s, "minigame exited by player", false, false) -- player exit, not a give-up
            end
            s.stop = true
            liveSession = nil
            if DebugSolver then log("solver: BackPressed exit, session stopped") end
        end)
    end)
end

-- world change: kill any session without touching stored object wrappers, and drop the
-- cached engine handles (the subsystem / attribute set are recreated on a new world).
pcall(RegisterInitGameStatePostHook, function()
    local s = liveSession
    liveSession = nil
    if s then s.stop = true end
    OpenedLocks = {}
    GeometryFails = {}
    for i = #PiecePool, 1, -1 do PiecePool[i] = nil end -- pieces reconstruct on the new world
    if Engine and Engine.dropHandles then Engine.dropHandles() end
end)

-- --------------------------------------------------------------- triggers --
-- Build the piece pool event-driven: the GothicLockPieceActor construction notify fires once
-- per pre-pooled piece a few seconds after world load (re-measured 2026-06-18), so we hold the
-- handles and never scan the object array on a lock open. Cleared above on a world change.
if not NextMoveBroken then
    local okPieces = pcall(NotifyOnNewObject, "/Script/G1R.GothicLockPieceActor", function(piece)
        pcall(function()
            if piece and piece:IsValid() then PiecePool[#PiecePool + 1] = piece end
        end)
    end)
    if not okPieces then
        log("Note: piece-construction notify not registered; lock-open falls back to a scan")
    end
end
-- NOTE: NotifyOnNewObject for GameplayAbilityOpen/Door was removed. Those fire on every
-- container/door interaction (not just lockpicking), and UE4SS crashes marshaling the
-- new-object notify into Lua on an already-unlocked chest open. The lock name comes from
-- the AbilityTask_LockPick (FreshTask) and the live-instance scan, not from FreshAbility.

-- The minigame task spawn is the trigger. Record the task cheaply, evict any stale session,
-- then hand off to tryStart after a short settle delay. tryStart bails with NO scan if the task
-- is dead or the lock was already opened this session, otherwise it Boosts and starts tracking.
local okNotify, errNotify = pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick",
    function(task)
        pcall(function()
            FreshTask = { obj = task, t = os.clock() }
            local stale = liveSession
            if stale then
                stale.stop = true
                liveSession = nil
                if DebugSolver then
                    log("solver: stale session evicted at minigame start")
                end
            end
            retryPendingHooks()
        end)
        if not NextMoveBroken then
            schedule(200, function()
                local ok2, err2 = pcall(tryStart, 1)
                if not ok2 then log("Next-move hint error: " .. tostring(err2)) end
            end)
        end
    end)
if not okNotify then
    log("ERROR: could not register minigame notification: " .. tostring(errNotify))
end

-- ------------------------------------------------------- the session loop --
-- The mod's ONE loop. It wakes every POLL_MS, cheaply decides if a tick is due, and runs a
-- single game-thread pass that ticks the live session. Driven through kit.async.gameLoop: on
-- 988+ the pass runs ON the game thread with no nested deferral (the #1180-safe path); on older
-- builds it falls back to LoopAsync + ExecuteInGameThread. The decide callback returns tickStep
-- when due, or true to retire the loop. Registered ONCE per load via a _G generation token (a
-- hot reload bumps it; the old loop sees the newer value and stops).
-- Rewards: ore on a successful pick, scaled by the lock's difficulty. Fired ONCE per session (guarded
-- by s.rewarded in the loop) the moment the lock opens. Adds to the player's own inventory, which is
-- stable while the chest opens, so it is safe to do here (never touches the opening chest).
local function payReward(s)
    if Config.oreReward ~= true or not Cost or not s or not s.connectionCount then return end
    local ore = Cost.oreReward(s.connectionCount, Config)
    if ore and ore > 0 and Engine.giveItem(Config.oreRewardItem, ore) then
        log(string.format("Reward: +%d %s (%d-connection lock)", ore, tostring(Config.oreRewardItem), s.connectionCount))
        toast("+" .. ore .. " ore", "reward")
    end
end

if not NextMoveBroken then
    local seenSession = nil -- for one-shot end-of-session bookkeeping

    local function tickStep()
        -- drain pending keybind actions on this ONE game-thread pass (the #1180 fix: no
        -- per-keybind ExecuteInGameThread to collide on the deferred queue)
        if Pending.hint then Pending.hint = false; pcall(toggleHint) end
        if Pending.conn then Pending.conn = false; pcall(doConnToggle) end
        if Pending.auto then Pending.auto = false; pcall(doAutoToggle) end
        if Pending.every then Pending.every = false; pcall(doEveryToggle) end
        if Pending.diag then Pending.diag = false; pcall(doEdgeMap) end
        local s = liveSession
        if seenSession and (s ~= seenSession or seenSession.stop) then
            local ended = seenSession
            seenSession = nil
            if ended.opened and ended.lockName then OpenedLocks[ended.lockName] = true end
            log("Lockpick session ended for '" .. tostring(ended.lockName)
                .. "': tracking, hint and auto-solve off")
        end
        if s and not s.stop then
            seenSession = s
            local ok, err = pcall(function() s:tick() end)
            if not ok then
                s.stop = true
                if liveSession == s then liveSession = nil end
                log("Next-move hint error, stopping: " .. tostring(err))
            elseif s.opened and not s.rewarded then
                s.rewarded = true -- feedback + reward, once per pick, the moment the lock opens
                if s.spentPicks and s.spentPicks > 0 then
                    toast("Spent " .. s.spentPicks .. " lockpick" .. (s.spentPicks == 1 and "" or "s"), "cost")
                end
                pcall(payReward, s)
            end
        end
    end

    -- the game-thread pass kit.async runs when due: tickStep already guards its own internals,
    -- this top-level pcall is the backstop that keeps a surprise error out of UE4SS and logs it.
    local function runTick()
        local ok, err = pcall(tickStep)
        if not ok then log("session loop error: " .. tostring(err)) end
    end

    local gen = (tonumber(rawget(_G, "LockpickSettings_loopGen")) or 0) + 1
    rawset(_G, "LockpickSettings_loopGen", gen)
    local wakes = 0
    -- cheap per-wake decision: returns runTick when a pass is due, true to retire the loop,
    -- or nil. kit.async runs the returned work on the game thread (no nesting on 988+).
    local function decide()
        if rawget(_G, "LockpickSettings_loopGen") ~= gen then return true end -- newer reload won
        wakes = wakes + 1
        local s = liveSession
        local due = false
        if s and not s.stop then
            local ap = s.autopilot
            if ap and ap.mode == "fast" then
                -- fast solve: one move per TickRateMs (read live for menu re-timing)
                local every = math.max(1, math.floor(TickRateMs / POLL_MS + 0.5))
                due = (wakes % every) == 0
            else
                due = (wakes % POLL_NORMAL_EVERY) == 0 -- normal play ~400ms
            end
        end
        if seenSession and (s ~= seenSession or seenSession.stop) then due = true end
        if Pending.hint or Pending.conn or Pending.auto or Pending.every or Pending.diag then due = true end
        if due then return runTick end
    end

    Async.gameLoop(POLL_MS, decide)
end

-- ------------------------------------------- shared mod menu (optional) --
-- Publish live-tunable settings to the optional SharedModMenu (via kit.menu / UE4SS
-- shared variables; a no-op if SMM isn't installed). Each set(v) applies the same
-- side-effects the hotkeys do, and persists. Guarded on kit.menu for older vendored kits.
if kit.menu and kit.menu.register then
    local function setHint(v)
        v = v and true or false
        if not NextMoveBroken and flags.nextMove ~= v then toggleHint() end
    end
    local function setConn(v)
        v = v and true or false
        if NextMoveBroken or flags.connections == v then return end
        flags.connections = v
        log("Connection display " .. (v and "ON" or "OFF"))
        local s = liveSession
        if s and not s.stop then pcall(function() s:onConnectionsToggled() end) end
        saveSettings()
    end
    local function setEvery(v)
        v = v and true or false
        if AutoSolveBroken or not driver or autoEvery == v then return end
        autoEvery = v
        log("Full-auto (every lock) " .. (v and "ON" or "OFF"))
        if v and Config.immersiveMode then -- Full-auto and Immersive Mode are mutually exclusive
            Config.immersiveMode = false
            log("Immersive Mode turned off (Full-auto is on)")
        end
        local s = liveSession
        if v then
            if s and not s.stop and not s.opened and not s.stateUnknown
                and s.hintGeometry and not driver:running() and not autoCapped(s) and chargeForSolve(s) then
                pcall(function() driver:toggleFast(s) end)
            end
        elseif driver:running() then
            pcall(function() driver:toggleFast(s) end)
        end
        saveSettings()
    end
    local function setSpeed(v)
        v = tonumber(v) or AutoAnimSpeed
        if v < 10 then v = 10 elseif v > 500 then v = 500 end
        AutoAnimSpeed = v
        if driver then driver.speed = v end
        log("Auto-solve animation speed " .. AutoAnimSpeed)
        saveSettings()
    end
    -- tick rate: read live by the loop, so it re-times solving immediately
    local function setTickRate(v)
        v = tonumber(v) or TickRateMs
        if v < 25 then v = 25 elseif v > 500 then v = 500 end
        TickRateMs = math.floor(v + 0.5)
        log("Auto-solve tick rate " .. TickRateMs .. "ms")
        saveSettings()
    end
    local function tierGet(t) return function() return ExtraTries[t] or 0 end end
    local function tierSet(t)
        return function(v)
            v = tonumber(v) or 0
            if v < 0 then v = 0 elseif v > 30 then v = 30 end
            ExtraTries[t] = math.floor(v + 0.5)
            saveSettings()
        end
    end

    local sections = {}
    if not AutoSolveBroken then
        sections[#sections + 1] = { title = "Full-Auto-Picker", items = {
            { name = "Full Auto", kind = "bool", desc = "Auto-solve every lock you open",
                get = function() return autoEvery end, set = setEvery },
            { name = "Animation Speed", kind = "num", min = 10, max = 500, step = 10, desc = "Pause between auto-solve moves",
                get = function() return AutoAnimSpeed end, set = setSpeed },
            { name = "Tick (DANGER)", kind = "num", min = 25, max = 500, step = 25, desc = "Adjust when the solver is unstable. Lower is faster.",
                get = function() return TickRateMs end, set = setTickRate },
            { name = "Lockpicks / Solve", kind = "num", min = 0, max = 50, step = 1,
                desc = "Lockpicks an auto-solve costs while Immersive is off (0 = free)",
                get = function() return Config.autoSolveLockpickCost or 0 end,
                set = function(v) Config.autoSolveLockpickCost = math.floor((tonumber(v) or 0) + 0.5); saveSettings() end },
        } }
        sections[#sections + 1] = { title = "Immersive Mode", items = {
            { name = "Immersive Mode", kind = "bool", desc = "F6 auto-solve costs lockpicks and needs skill",
                get = function() return Config.immersiveMode == true end,
                set = function(v)
                    Config.immersiveMode = v and true or false
                    log("Immersive Mode " .. (Config.immersiveMode and "ON (F6 costs lockpicks + skill)" or "OFF"))
                    if Config.immersiveMode and autoEvery then -- mutually exclusive with full-auto-every-lock
                        autoEvery = false
                        if driver and driver:running() then pcall(function() driver:toggleFast(liveSession) end) end
                        log("Full-auto turned off (Immersive Mode is on)")
                    end
                    saveSettings()
                end },
            { name = "Lockpicks / Connection", kind = "num", min = 0, max = 5, step = 0.1,
                desc = "Picks an F6 solve costs per lock connection",
                get = function() return Config.lockpicksPerConnection or 0 end,
                set = function(v) Config.lockpicksPerConnection = math.floor((tonumber(v) or 0) * 10 + 0.5) / 10; saveSettings() end },
            { name = "Min Lockpick Cost", kind = "num", min = 0, max = 50, step = 1,
                get = function() return Config.lockpickCostMin or 0 end,
                set = function(v) Config.lockpickCostMin = math.floor((tonumber(v) or 0) + 0.5); saveSettings() end },
            { name = "Max Lockpick Cost", kind = "num", min = 0, max = 99, step = 1,
                get = function() return Config.lockpickCostMax or 0 end,
                set = function(v) Config.lockpickCostMax = math.floor((tonumber(v) or 0) + 0.5); saveSettings() end },
            { name = "Skilled at (connections)", kind = "num", min = 1, max = 12, step = 1,
                get = function() return Config.skilledAtConnections or 0 end,
                set = function(v) Config.skilledAtConnections = math.floor((tonumber(v) or 0) + 0.5); saveSettings() end },
            { name = "Master at (connections)", kind = "num", min = 1, max = 12, step = 1,
                get = function() return Config.masterAtConnections or 0 end,
                set = function(v) Config.masterAtConnections = math.floor((tonumber(v) or 0) + 0.5); saveSettings() end },
        } }
    end
    if not NextMoveBroken then
        sections[#sections + 1] = { title = "Rewards", items = {
            { name = "Ore Reward", kind = "bool", desc = "Add ore on a successful pick, scaled by difficulty",
                get = function() return Config.oreReward == true end,
                set = function(v)
                    Config.oreReward = v and true or false
                    log("Ore Reward " .. (Config.oreReward and "ON" or "OFF"))
                    saveSettings()
                end },
            { name = "Ore / Connection", kind = "num", min = 0, max = 20, step = 0.5,
                desc = "Ore added per lock connection",
                get = function() return Config.orePerConnection or 0 end,
                set = function(v) Config.orePerConnection = math.floor((tonumber(v) or 0) * 10 + 0.5) / 10; saveSettings() end },
            { name = "Min Ore", kind = "num", min = 0, max = 99, step = 1,
                get = function() return Config.oreRewardMin or 0 end,
                set = function(v) Config.oreRewardMin = math.floor((tonumber(v) or 0) + 0.5); saveSettings() end },
            { name = "Max Ore", kind = "num", min = 0, max = 999, step = 1,
                get = function() return Config.oreRewardMax or 0 end,
                set = function(v) Config.oreRewardMax = math.floor((tonumber(v) or 0) + 0.5); saveSettings() end },
        } }
        sections[#sections + 1] = { title = "Hints", items = {
            { name = "Next-Move Hint", kind = "bool", desc = "Highlight the next move to make",
                get = function() return flags.nextMove end, set = setHint },
            { name = "Connections", kind = "bool", desc = "Show connected tumblers while picking",
                get = function() return flags.connections end, set = setConn },
        } }
    end
    sections[#sections + 1] = { title = "Durability", items = {
        { name = "Untrained", kind = "num", min = 0, max = 30, step = 1,
            get = tierGet("untrained"), set = tierSet("untrained") },
        { name = "Trained", kind = "num", min = 0, max = 30, step = 1,
            get = tierGet("trained"), set = tierSet("trained") },
        { name = "Master", kind = "num", min = 0, max = 30, step = 1,
            get = tierGet("master"), set = tierSet("master") },
    } }
    sections[#sections + 1] = { title = "Configuration", items = {
        { name = "Tooltips", kind = "bool", desc = "Show the on-minigame panel (cost, skill, status)",
            get = function() return Config.showTooltip ~= false end,
            set = function(v)
                Config.showTooltip = v and true or false
                log("Tooltips " .. (Config.showTooltip and "ON" or "OFF"))
                saveSettings()
            end },
        { name = "Notifications", kind = "bool", desc = "Show the snackbar messages (lockpicks spent, ore found)",
            get = function() return Config.showNotifications ~= false end,
            set = function(v)
                Config.showNotifications = v and true or false
                log("Notifications " .. (Config.showNotifications and "ON" or "OFF"))
                saveSettings()
            end },
    } }
    pcall(kit.menu.register, "LockpickSettings", sections)
    log("SharedModMenu: registered " .. #sections .. " section(s) (a tab appears if "
        .. "the SharedModMenu mod is installed)")
end

-- ------------------------------------------------- immersive readout (tail) --
-- While Immersive Mode is on and a lock is being picked, a fixed-position panel shows the lock's
-- difficulty, your lockpicks, the F6 cost and the skill it needs (red when you cannot meet it). Driven
-- by a game-thread timer. It acts ONLY once the solver session is live (the scramble gate has passed):
-- reading the inventory (a FindAllOf object-array walk) or drawing during the chest-open, while the
-- lock objects and UI are still constructing, is the native-AV crash surface (the same one FTA hit and
-- the solver's own piece-pool wait avoids). The panel is pre-built off-minigame so opening a lock never
-- constructs it mid-transition, and the picks/skill are read ONCE per lock (cached on the session,
-- re-read after a solve) so there is no per-tick inventory scan.
-- Anchor in DESIGN space (the resolution-independent UMG space the panel's slots live in, = physical
-- pixels / DPI scale). The minigame is anchored RIGHT-CENTER: it hugs the right edge and stays
-- vertically centered, so the panel matches that. X is measured in from the right edge, Y from the
-- vertical CENTER (not the bottom). The design canvas is 1920x1080 only at 16:9 and wider, where the
-- height is the constraint. At a TALLER aspect like 4:3 it grows (e.g. 1920x1440), so a bottom-anchored
-- Y would sink below the centered minigame. Center-anchoring the Y keeps it aligned at every aspect.
local READOUT_FROM_RIGHT = 750    -- design units LEFT of the right edge
local READOUT_BELOW_CENTER = 202  -- design units BELOW the vertical center
-- the panel's top-left in design space, read ONCE per session (the viewport is constant per lock).
-- See the anchor note above for why X is right-anchored and Y center-anchored.
local function readoutAnchor(s)
    if s.readoutX == nil then
        local vw, vh, sc = Engine.viewportSize()
        if vw and vh then
            sc = (sc and sc > 0) and sc or 1
            local designW, designH = vw / sc, vh / sc -- the slots live in design space (pixels / DPI scale)
            s.readoutX = designW - READOUT_FROM_RIGHT       -- right-anchored: track the right edge
            s.readoutY = designH / 2 + READOUT_BELOW_CENTER -- center-anchored: track the centered minigame
            if DebugSolver then
                log(string.format("readout anchor: viewport %.0fx%.0f scale %.3f -> design %.0fx%.0f, panel at %.0f,%.0f",
                    vw, vh, sc, designW, designH, s.readoutX, s.readoutY))
            end
        end
    end
    return s.readoutX or 40, s.readoutY or 110
end

local function readoutTick()
    if not (Cost and Engine.readoutUpdate) then return end
    if Config.showTooltip == false then Engine.readoutHide() return end
    local s = liveSession
    local active = s and not s.stop and s.connectionCount
    -- Immersive Mode readout: difficulty, the F6 cost and the skill needed (red when you cannot meet it).
    if active and Config.immersiveMode == true then
        if s.readoutPicks == nil then
            s.readoutPicks = Engine.itemCount(Config.lockpickItem)
            local attrs = Engine.lockpickAttributes()
            s.readoutPrecision = attrs and attrs.precision
        end
        local picks, precision = s.readoutPicks, s.readoutPrecision
        local ok, hasSkill, _, req, costPicks = Cost.evaluate(s.connectionCount, precision, picks, Config)
        local myTier = math.floor((precision or 0) + 0.5)
        if myTier < 0 then myTier = 0 elseif myTier > 2 then myTier = 2 end
        local pickKey = (type(AutoKey) == "string" and AutoKey ~= "") and AutoKey or "F6"
        local header = "[" .. pickKey .. "] auto-pick"
        local line1 = "Lock difficulty: " .. s.connectionCount .. " connections"
        local haveStr = (picks == nil) and "?" or tostring(picks)
        local line2, line3
        if not hasSkill then
            line2 = "Needs " .. Cost.skillName(req) .. " picklock skill"
            line3 = "You have " .. Cost.skillName(myTier) .. " (cost " .. costPicks .. " lockpicks)"
        else
            line2 = "Costs " .. costPicks .. " lockpicks (have " .. haveStr .. ")"
            line3 = "Picklock skill " .. Cost.skillName(myTier) .. " (ready)"
        end
        local x, y = readoutAnchor(s)
        Engine.readoutUpdate(header, line1, line2, line3, not ok, x, y)
        return
    end
    -- Plain auto solver: only surfaces when a solve was just refused for too few lockpicks.
    if active and s.autoStop == "flat" then
        local x, y = readoutAnchor(s)
        Engine.readoutUpdate("Auto Solver stopped", "Not enough lockpicks",
            string.format("Need %d, have %s", s.autoStopCost or 0, tostring(s.autoStopHave)), nil, true, x, y)
        return
    end
    Engine.readoutHide()
    Engine.readoutBuild() -- pre-build during stable gameplay; no-op once built
end

-- Bind the kit's snackbar to this mod's engine + the game's player controller so toast() can show
-- feedback. The readout loop pre-builds the snackbar widget off-minigame (below).
pcall(function()
    kit.snackbar.bind({ engine = kit.engine, controller = Engine.playerController })
end)

do
    local rawget, rawset = rawget, rawset
    rawset(_G, "__lps_readoutWork", function()
        pcall(readoutTick)
        -- pre-build the snackbar off-tooltip + prune expired rows, both on the game thread
        if kit.snackbar then pcall(kit.snackbar.prebuild); pcall(kit.snackbar.tick) end
    end) -- refreshed on every (re)load
    if kit.async and kit.async.gameLoop and not rawget(_G, "__lps_readoutLoop") then
        rawset(_G, "__lps_readoutLoop", true) -- register the persistent loop ONCE (survives CTRL+R)
        pcall(kit.async.gameLoop, 200, function() return rawget(_G, "__lps_readoutWork") end)
    end
end

-- ----------------------------------------------------------------- banner --
local loaded = {}
if Boost then
    local effective = Boost.plan(ExtraTries).effective
    for name, base in pairs(Boost.BASE_TRIES) do
        loaded[#loaded + 1] = string.format("%s %d->%d", name, base, effective[name])
    end
end
local graphCount = 0
for _ in pairs(LockGraphs) do graphCount = graphCount + 1 end
local hintInfo = ", next-move hint unavailable"
if not NextMoveBroken then
    hintInfo = string.format(", next-move hint %s (%d lock graphs from %s%s)",
        flags.nextMove and "on" or "off", graphCount, graphSource,
        (type(HotkeyName) == "string" and HotkeyName ~= "" and Key[HotkeyName])
        and (", toggle: " .. HotkeyName) or "")
    hintInfo = hintInfo .. string.format(", connection display %s%s",
        flags.connections and "on" or "off",
        (type(ConnHotkeyName) == "string" and ConnHotkeyName ~= ""
            and Key[ConnHotkeyName])
        and (", toggle: " .. ConnHotkeyName) or "")
    if not AutoSolveBroken and type(AutoKey) == "string" and AutoKey ~= ""
        and Key[AutoKey] then
        local autoKeys = { AutoKey .. " solve lock" }
        if type(AutoEveryMod) == "string" and AutoEveryMod ~= ""
            and ModifierKey and ModifierKey[AutoEveryMod] then
            autoKeys[#autoKeys + 1] = AutoEveryMod .. "+" .. AutoKey
                .. " full-auto every lock " .. (autoEvery and "(on)" or "(off)")
        end
        hintInfo = hintInfo .. ", auto-solve: " .. table.concat(autoKeys, ", ")
    end
end
log("Loaded " .. ModVersion .. " (kit " .. tostring(kit.version) .. "): "
    .. table.concat(loaded, ", ") .. hintInfo)
