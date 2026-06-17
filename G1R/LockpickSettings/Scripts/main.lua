-- LockpickSettings for Gothic 1 Remake -- thin orchestrator: requires the modules,
-- wires them to the engine events, owns ALL registration. See CONTRIBUTING.md.
-- Features: extra durability (tries/), next-move hint + connection display
-- (nextmove/ connections/ core/), auto-solve (autosolve/, shipped policy lookup).

-- UE4SS shares one Lua state across mods; capture stdlib as locals so a clobbered
-- global can't break us.
local ipairs, pairs, tostring, tonumber = ipairs, pairs, tostring, tonumber
local type, pcall, print, require, next = type, pcall, print, require, next
local rawget, rawset, debug = rawget, rawset, debug
local math, table, string, os = math, table, string, os

local ModVersion = "3.2.1"

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
    "core.settings", "util.palette", "util.inflate", "util.base64",
    "data.lockgraphs", "data.lockpolicies", "data.lockpolicies_index",
    "tries.boost", "nextmove.policy", "nextmove.geometry", "nextmove.hint",
    "connections.connections", "autosolve.driver",
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
}
if Settings and SavedPath then
    local saved = Settings.load(SavedPath)
    for _, key in ipairs(SAVED_KEYS) do
        if saved[key] ~= nil then Config[key] = saved[key] end
    end
end

-- the mod SHIPS the lock graphs (data/lockgraphs.lua) as the state of truth;
-- regenerate on a game update with tools/livegraphs.lua. No data = no hint/connections.
local LockGraphs, okGraphs, graphSource = {}, false, "none"
local okData, Data = pcall(require, "data.lockgraphs")
if okData and type(Data) == "table" and next(Data) then
    LockGraphs, okGraphs, graphSource = Data, true, "bundled"
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

-- shipped solution policies: data/lockpolicies.lua (base64 of DEFLATE next-move tables
-- per lock x precision variant, built by tools/build_policies.py) + lockpolicies_index.
-- base64'd so scanners read it as source, not an opaque binary. Decoded once at boot;
-- one lock's variant is inflated on open and looked up.
local Policy = nil
do
    local okIdx, Index = pcall(require, "data.lockpolicies_index")
    local blob = nil
    pcall(function()
        local b64 = require("data.lockpolicies")
        if type(b64) == "string" then blob = require("util.base64").decode(b64) end
    end)
    if PolicyMod and okIdx and type(Index) == "table" and blob and #blob > 0 then
        Policy = PolicyMod.new({
            index = Index, log = log,
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
local AutoEveryMod   = Config.autoSolveEveryModifier
local AutoEveryDefault = Config.autoSolveEvery == true

-- animation speed = visual move glide (clamped 10..500); purely cosmetic.
local AutoAnimSpeed = Config.autoSolveAnimationSpeed
if type(AutoAnimSpeed) ~= "number" then AutoAnimSpeed = 250 end
if AutoAnimSpeed < 10 then AutoAnimSpeed = 10 elseif AutoAnimSpeed > 500 then AutoAnimSpeed = 500 end

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
local FreshPieces = {}  -- piece actors by spawn time (notify below)
local FreshAbility = nil
local FreshTask = nil   -- the CURRENT minigame task
local StartSnap = nil   -- previous start attempt's slot snapshot (scramble gate)
local OpenedLocks = {}  -- locks opened this session; cleared on world change

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

-- run fn on the game thread after ms (documented one-shot delay; the inner
-- ExecuteInGameThread marshals onto the game thread).
local function schedule(ms, fn)
    ExecuteWithDelay(ms, function()
        ExecuteInGameThread(function() pcall(fn) end)
    end)
end

-- --------------------------------------------------------------- start flow --
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
    -- resolve the MPC/scene handles ONCE per open (mpcHandles does a ~30ms FindAllOf):
    -- reused by the scramble gate and handed to Session.start, so the scan runs once.
    local lib, mpc, scene = Engine.mpcHandles()
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
    -- collect only actors born for THIS minigame: fresh spawns first, then the
    -- subsystem array, then the world-wide FindAllOf last resort (which also returns
    -- earlier minigames' actors).
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
    -- stale-actor crash guard: re-opening an already-opened lock spawns a task but no
    -- fresh pieces, so discovery falls to FindAllOf and returns the DEAD actors of the
    -- finished minigame; reading those is a native AV. Refuse before any read.
    if actorSrc:find("FindAllOf", 1, true) and OpenedLocks[lockName] then
        log("Skipping '" .. lockName .. "': already opened this session and only "
            .. "stale actors remain (not reading half-dead objects)")
        return
    end
    -- LockpickPrecision = how many connections the game pruned (the first k); open
    -- that precomputed variant.
    local attrs = Engine.lockpickAttributes()
    local k = math.floor((attrs and attrs.precision or 0) + 0.5)
    if k < 0 then k = 0 elseif k > 2 then k = 2 end
    local lockPolicy = Policy and Policy:open(lockName, k) or nil
    if DebugSolver then
        log(string.format("lock '%s': precision=%s durability=%s -> variant %d, "
            .. "policy %s", lockName, tostring(attrs and attrs.precision),
            tostring(attrs and attrs.durability), k,
            lockPolicy and "loaded" or "MISSING"))
    end
    local session, reason = Session.start({
        lockName = lockName, graph = graph, actorList = actorList,
        engine = Engine, num = Num, lockPolicy = lockPolicy, precisionK = k,
        handles = lib and { lib = lib, mpc = mpc, scene = scene } or nil,
        tinter = tinterInstance,
        flags = flags, log = log, debug = DebugSolver, schedule = schedule,
        unreliableActors = actorSrc:find("FindAllOf", 1, true) and true or false,
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
    -- stale re-entry guard: pieces only from FindAllOf AND no readable geometry = the
    -- contaminated actor cloud of a finished minigame; polling it per tick is a native
    -- AV surface. Don't track it.
    if s.stateUnknown and actorSrc:find("FindAllOf", 1, true) then
        log("Skipping tracking for '" .. lockName .. "': no fresh pieces and no "
            .. "readable geometry (stale actors from an earlier minigame); "
            .. "avoids polling half-dead objects")
        return
    end
    -- bind THIS minigame's task: its death is the authoritative "minigame over" signal
    -- (an opened lock's piece/scene actors linger for minutes).
    s.task = FreshTask
    s.onStop = function() if liveSession == s then liveSession = nil end end
    liveSession = s
    s.tinter:retint(s)
    log(string.format("Next-move hint: %s, %d pieces, %d connections, first hint: %s",
        lockName, s.pieceCount, #graph.connections,
        s.nextMove and ("piece " .. s.nextMove.piece) or "none"))
    -- full-auto: drive this lock the instant it's tracked, when usable
    if autoEvery and driver and not s.stateUnknown and s.hintGeometry then
        pcall(function() driver:toggleFast(s) end)
    end
end

-- ------------------------------------------------------------------ toggles --
-- The toggle ACTIONS, run on the game thread (keybind marshals via ExecuteInGameThread;
-- the menu set() callbacks call these too, so keys and menu stay in lockstep).
-- Mode exclusivity: a display toggle stops any auto-solve first (one active execution).
-- toggleGap caps the rate of ANY two toggles so mashing can't burst-restart auto-solve
-- and hammer the #1180 queue.
local lastAnyToggle = 0
local function toggleGap()
    local now = os.clock()
    if now - lastAnyToggle < 0.15 then return false end
    lastAnyToggle = now
    return true
end
local lastToggle = 0
local function cancelDriverFor(s)
    if driver and s and not s.stop and driver:running() then
        driver:finish(s, "stopped: a display was toggled", false)
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

-- F6: solve the current lock now (or cancel an in-progress solve)
local function doAutoToggle()
    if not driver then return end
    pcall(function() driver:toggleFast(liveSession) end)
end

-- Shift+F6: flip full-auto-every-lock, arming/cancelling the current lock to match
local function doEveryToggle()
    if not driver then return end
    pcall(function()
        autoEvery = not autoEvery
        log("Full-auto (every lock) " .. (autoEvery and "ON" or "OFF"))
        local s = liveSession
        if autoEvery then
            if s and not s.stop and not s.opened and not s.stateUnknown
                and s.hintGeometry and not driver:running() then
                driver:toggleFast(s)
            end
        elseif driver:running() then
            driver:toggleFast(s)
        end
        saveSettings()
    end)
end

-- keybinds debounce per-key (0.3s, kills held-key repeat), then the global toggleGap,
-- then marshal the action to the game thread.
if type(HotkeyName) == "string" and HotkeyName ~= "" and not NextMoveBroken then
    if Key[HotkeyName] then
        pcall(RegisterKeyBind, Key[HotkeyName], function()
            local now = os.clock()
            if now - lastToggle < 0.3 then return end
            if not toggleGap() then return end
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
            if not toggleGap() then return end
            lastConnToggle = now
            ExecuteInGameThread(function() pcall(doConnToggle) end)
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
        if not toggleGap() then return end
        lastAutoSolve = now
        ExecuteInGameThread(function() pcall(doAutoToggle) end)
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
                if not toggleGap() then return end
                lastAutoEvery = now
                ExecuteInGameThread(function() pcall(doEveryToggle) end)
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

-- ------------------------------------------------------------------- input --
-- selection tracking off the task's Up/Down handlers (keyboard AND controller). Tiny
-- debounce: a held key repeats at ~30ms.
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
    tryHook("/Script/G1R.AbilityTask_LockPick:UpPressed", function()
        pcall(onSelectionStep, 1)
    end)
    tryHook("/Script/G1R.AbilityTask_LockPick:DownPressed", function()
        pcall(onSelectionStep, -1)
    end)
    tryHook("/Script/G1R.AbilityTask_LockPick:LeftPressed", function()
        pcall(onMovePress, -1)
    end)
    tryHook("/Script/G1R.AbilityTask_LockPick:RightPressed", function()
        pcall(onMovePress, 1)
    end)
    -- BackPressed = player exited: stop the session and any solve NOW, before the task
    -- tears down, so nothing presses a dying task.
    tryHook("/Script/G1R.AbilityTask_LockPick:BackPressed", function()
        pcall(function()
            local s = liveSession
            if not s or s.stop then return end
            if driver and driver:running() then
                driver:finish(s, "minigame exited by player", false)
            end
            s.stop = true
            liveSession = nil
            if DebugSolver then log("solver: BackPressed exit, session stopped") end
        end)
    end)
    tryHook("/Script/G1R.AbilityTask_LockPick:TryOpenLock", function()
        pcall(function()
            local s = liveSession
            if s and not s.stop then
                s.openSignalT = os.clock()
                if DebugSolver then log("solver: TryOpenLock fired") end
            end
        end)
    end)
    -- authoritative open signals (idempotent). GameplayAbilityOpen:Server_SuccessLockEvent
    -- was removed in the 2026-06-12 update; the Open success still arrives via its
    -- NetMulticast_OnSetLockUnlocked.
    local function onOpenSignal(src)
        local s = liveSession
        if s and not s.stop then
            s.openSignalT = os.clock()
            s.opened = s.opened or os.clock()
            if DebugSolver then log("solver: OPEN signal: " .. src) end
        end
    end
    for _, fn in ipairs({
        "/Script/G1R.GameplayAbilityDoor:Server_SuccessLockEvent",
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
                    s.atGoalTicks = 0 -- a break re-scrambles; don't read the flight
                    if DebugSolver then
                        log("solver: FAIL signal (pick broke): " .. fn)
                    end
                end
            end)
        end)
    end
end

-- world change: kill any session without touching stored object wrappers
pcall(RegisterInitGameStatePostHook, function()
    local s = liveSession
    liveSession = nil
    if s then s.stop = true end
    OpenedLocks = {}
end)

-- --------------------------------------------------------------- triggers --
pcall(NotifyOnNewObject, "/Script/G1R.GothicLockPieceActor", function(obj)
    FreshPieces[#FreshPieces + 1] = { obj = obj, t = os.clock() }
end)
pcall(NotifyOnNewObject, "/Script/G1R.GameplayAbilityOpen", function(obj)
    FreshAbility = { obj = obj, t = os.clock() }
end)
pcall(NotifyOnNewObject, "/Script/G1R.GameplayAbilityDoor", function(obj)
    FreshAbility = { obj = obj, t = os.clock() }
end)

-- the minigame task spawn is the trigger: boost tries, evict any stale session, retry
-- hooks, then start tracking after a settle delay (the scramble gate self-corrects, so
-- a low delay just shows the tint sooner).
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
        if not BoostBroken then
            local ok, err = pcall(function()
                Boost.apply(ExtraTries, Engine, Num, log)
            end)
            if not ok then log("Boost error: " .. tostring(err)) end
        end
        if not NextMoveBroken then
            schedule(450, function()
                local ok2, err2 = pcall(tryStart, 1)
                if not ok2 then log("Next-move hint error: " .. tostring(err2)) end
            end)
        end
    end)
if not okNotify then
    log("ERROR: could not register minigame notification: " .. tostring(errNotify))
end

-- ------------------------------------------------------- the session loop --
-- The mod's ONE async loop. It wakes every POLL_MS, cheaply decides if a tick is due,
-- and marshals a single game-thread pass that ticks the live session. Registered ONCE
-- per load via a generation token in _G (a hot reload bumps it; the old loop self-stops).
if not NextMoveBroken then
    local seenSession = nil -- for one-shot end-of-session bookkeeping

    local function tickStep()
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
            end
        end
    end

    local gen = (tonumber(rawget(_G, "LockpickSettings_loopGen")) or 0) + 1
    rawset(_G, "LockpickSettings_loopGen", gen)
    local wakes = 0
    local ticking = false -- a game-thread pass is in flight; never dispatch two
    LoopAsync(POLL_MS, function()
        if rawget(_G, "LockpickSettings_loopGen") ~= gen then return true end -- newer reload won
        if ticking then return false end
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
        if not due then return false end
        ticking = true
        ExecuteInGameThread(function()
            local ok, err = pcall(tickStep)
            ticking = false
            if not ok then log("session loop error: " .. tostring(err)) end
        end)
        return false
    end)
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
        local s = liveSession
        if v then
            if s and not s.stop and not s.opened and not s.stateUnknown
                and s.hintGeometry and not driver:running() then
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
    if not NextMoveBroken then
        sections[#sections + 1] = { title = "Hints", items = {
            { name = "Next-Move Hint", kind = "bool",
                get = function() return flags.nextMove end, set = setHint },
            { name = "Connections", kind = "bool",
                get = function() return flags.connections end, set = setConn },
        } }
    end
    if not AutoSolveBroken then
        sections[#sections + 1] = { title = "Auto-Solve", items = {
            { name = "Full Auto", kind = "bool",
                get = function() return autoEvery end, set = setEvery },
            { name = "Animation Speed", kind = "num", min = 10, max = 500, step = 10,
                get = function() return AutoAnimSpeed end, set = setSpeed },
            { name = "Tick (DANGER)", kind = "num", min = 25, max = 500, step = 25,
                get = function() return TickRateMs end, set = setTickRate },
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
    pcall(kit.menu.register, "LockpickSettings", sections)
    log("SharedModMenu: registered " .. #sections .. " section(s) (a tab appears if "
        .. "the SharedModMenu mod is installed)")
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
