-- LockpickSettings for Gothic 1 Remake  --  thin orchestrator
--
-- Carries NO algorithm and NO measurement logic: it self-adds the vendored
-- shared kit, requires the mod modules, wires them to the engine's events, and
-- owns ALL registration. The work lives in the shared kit (engine primitives,
-- num, color, log) and the mod's modules: core/ (engine_lock, session, tinter),
-- util/palette, data/livegraphs, and the feature folders tries/, nextmove/
-- (solver, geometry, hint), connections/. See CONTRIBUTING.md.
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
-- Three features in config.lua: (1) Extra tries (tries/); (2) Next-move hint
-- (nextmove/ + core); (3) Connection display (connections/ + core). Tracking
-- always runs while a minigame is open; the hotkeys only toggle the paint.

-- UE4SS mods share one Lua state: another mod overwriting a standard global
-- (seen: ipairs replaced by a table) must not break us. Capture as locals.
local ipairs, pairs, tostring, tonumber = ipairs, pairs, tostring, tonumber
local type, pcall, print, require, next = type, pcall, print, require, next
local rawget, debug = rawget, debug
local math, table, string, os = math, table, string, os

local ModVersion = "3.0.5"

-- Poll cadence. The poll worker wakes every POLL_MS; in normal play it does
-- game-thread work (the tick) only every POLL_NORMAL_EVERY wakes (~400ms, load
-- unchanged), while FAST auto-solve ticks EVERY wake so the route runs as fast as
-- moves are honoured. POLL_MS is the one tuning knob, and the re-entrancy guard in
-- the poll self-throttles to the tick's real cost, so a low value is safe ("as
-- fast as the tick allows"). Shipped at 25ms: a buffer over the ~16ms (one 60fps
-- frame) that play-tested clean, for headroom on varied hardware. Lower it for
-- snappier, raise it if play hitches.
local POLL_MS = 25
local POLL_NORMAL_EVERY = math.max(1, math.floor(400 / POLL_MS + 0.5)) -- ~400ms normal

-- ---------------------------------------------------- vendored shared kit --
-- This mod ships its OWN copy of the kit under <Mod>/shared/kit/ (deploy.ps1
-- vendors it from the one repo source), so each build is self-contained with no
-- global Mods/shared dependency. That folder is not on UE4SS's default search
-- path, so add it from this file's own location (the BPModLoaderMod pattern).
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
-- the mod folder (parent of Scripts/). Also used below to locate the game's own
-- PrecompiledScript_Shipping.Cache for the live graph decode.
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;"
        .. ModDir .. "/shared/?.lua;" .. package.path
end

-- --------------------------------------------------------- hot reload reset --
-- CTRL+R re-runs this chunk. nil EVERY module (the kit AND the mod's, by their
-- exact require names) in package.loaded, and FULL-SWEEP ue4ss_loaded_modules
-- (it is keyed by absolute path, so a bare-name nil there is a silent no-op).
-- Do it BEFORE the first require so edits to any file take effect.
local MODULES = {
    "kit", "config", "core.engine_lock", "core.session", "core.tinter",
    "util.palette", "data.livegraphs", "tries.boost",
    "nextmove.solver", "nextmove.geometry", "nextmove.hint",
    "connections.connections", "autosolve.driver",
}
for _, m in ipairs(MODULES) do package.loaded[m] = nil end
do
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then
        for k in pairs(reg) do reg[k] = nil end
    end
end

-- the shared kit is the foundation: without it the mod cannot run
local okKit, kit = pcall(require, "kit")
if not okKit or type(kit) ~= "table" then
    print("[LockpickSettings] FATAL: shared kit not found (" .. tostring(kit)
        .. "). Re-deploy; the kit vendors under <Mod>/shared/.\n")
    return
end
local log = kit.log.make("[LockpickSettings]")
local Num = kit.num

-- ----------------------------------------------------------------- modules --
-- each require pcall-wrapped; a broken child disables only its feature.
local function tryRequire(name) return kit.boot.tryRequire(name, log) end

local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end

-- Lock graphs: decode the game's OWN PrecompiledScript_Shipping.Cache at runtime
-- (TECH-DEBT Approach A). The mod ships NO lock data; it reads the game's file,
-- which adapts to any mod that changes layouts via AngelScript source and to game
-- patches. data.livegraphs prefers a live decode and falls back to its own
-- self-written cache; if both are unreadable there is nothing to plan against, so
-- the hint and connection display disable for the session (the durability boost
-- is unaffected).
local LockGraphs, okGraphs, graphSource = {}, false, "none"
local okLive, Live = pcall(require, "data.livegraphs")
if okLive and type(Live) == "table" and ModDir then
    local ok2, g, src = pcall(function()
        return Live.load({
            cachePath = ModDir
                .. "/../../../../../Script/PrecompiledScript_Shipping.Cache",
            cacheFile = ModDir .. "/livegraphs.cache.lua",
        })
    end)
    if ok2 and type(g) == "table" and next(g) then
        LockGraphs, okGraphs, graphSource = g, true, src or "live"
    end
end
if not okGraphs then
    log("ERROR: could not read the lock graphs from the game cache "
        .. "(PrecompiledScript_Shipping.Cache) or a local cache; next-move hint "
        .. "and connection display off")
end

local Engine = tryRequire("core.engine_lock")
local Palette = tryRequire("util.palette")
local Boost = tryRequire("tries.boost")
local Solver = tryRequire("nextmove.solver")
local Geometry = tryRequire("nextmove.geometry") -- required transitively by session too
local Hint = tryRequire("nextmove.hint")
local Connections = tryRequire("connections.connections")
local Tinter = tryRequire("core.tinter")
local Session = tryRequire("core.session")
local Driver = tryRequire("autosolve.driver")

-- ----------------------------------------------------------------- config --
local ExtraTries     = tonumber(Config.extraTries) or 10
local HotkeyName     = Config.nextMoveHotkey
local ConnHotkeyName = Config.connectionsHotkey
local DebugSolver    = Config.debugSolver == true
local AutoStepKey    = Config.autoSolveStepHotkey
local AutoFullKey    = Config.autoSolveFullHotkey
local AutoFullMod    = Config.autoSolveFullModifier
local AutoFastMod    = Config.autoSolveFastModifier

-- the only mutable feature flags, shared BY REFERENCE into the Session and
-- Tinter so a hotkey toggle propagates live
local flags = {
    nextMove = Config.showNextMove == true,
    connections = Config.showConnections == true,
}

-- the hint/connection features need the whole engine+feature chain plus the
-- graphs; boost only needs the engine (kit.num is always present).
local NextMoveBroken = not (Engine and Palette and Solver and Geometry and Hint
    and Connections and Tinter and Session and okGraphs)
local BoostBroken = not (Boost and Engine)
if NextMoveBroken then
    log("next-move hint and connection display unavailable (a required module "
        .. "failed to load)")
end
-- auto-solve rides the whole hint chain (solver, geometry, session, engine) plus
-- the driver module; it is unavailable whenever the hint is.
local AutoSolveBroken = NextMoveBroken or not Driver
if not NextMoveBroken and not Driver then
    log("auto-solve unavailable (autosolve/driver.lua failed to load)")
end

-- the resolved palette (built once) and the shared collaborators. The Tinter is
-- injected with the two PURE feature policies (the hint color and the partner
-- tint map), so it stays a mechanism that knows no feature.
local palette = Palette and Palette.build(Config) or nil
local solverInstance = Solver and Solver.new({ log = log, debug = DebugSolver }) or nil
local tinterInstance = (Tinter and palette and Engine and Hint and Connections)
    and Tinter.new(palette, Engine, Num, Hint.color, Connections.partnerTints) or nil

-- ----------------------------------------------------- live-session state --
-- main owns the single live-session slot and the spawn caches the start flow
-- reads; nothing here touches a stored object wrapper after eviction.
local liveSession = nil
local FreshPieces = {} -- piece actors by spawn time, see the notify below
local FreshAbility = nil -- the most recently spawned open/door ability
local FreshTask = nil -- the CURRENT minigame task (notify-captured)
local StartSnap = nil -- slot snapshot of the previous start attempt

-- the auto-solver instance (main owns it, like the live session). It presses the
-- CURRENT task through the main-owned FreshTask cache, liveness checked per call
-- in the adapter. The hotkeys below arm it by setting liveSession.autopilot; the
-- session tick then advances it one step per settle.
-- the press target: the CURRENT task, but ONLY while a live session is running
-- and the lock has NOT begun opening. After the open signal the task is being
-- torn down while the scene/pieces still linger, and pressing its input UFunction
-- then dereferences freed sub-objects (a native AV pcall cannot catch). Returning
-- nil here makes engine.pressInput a safe no-op the instant the lock solves.
local driver = (not AutoSolveBroken) and Driver.new({
    engine = Engine,
    getTask = function()
        local s = liveSession
        if not s or s.stop or s.opened then return nil end
        return s.task
    end,
    log = log,
    debug = DebugSolver,
}) or nil

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
    -- bind THIS minigame's task to the session. The task dies when the minigame
    -- ends, even though an opened lock's piece/scene actors LINGER for minutes;
    -- session.tick uses this as the authoritative "still in the minigame" signal,
    -- so the session (and liveSession) is torn down promptly instead of lingering
    -- and letting auto-solve be re-armed at an already-finished lock.
    s.task = FreshTask
    -- main owns the live slot; the onStop closure frees it when this session
    -- ends, only if it is still the live one
    s.onStop = function() if liveSession == s then liveSession = nil end end
    liveSession = s
    s.tinter:retint(s)
    log(string.format("Next-move hint: %s, %d pieces, %d connections, first hint: %s",
        lockName, s.pieceCount, #graph.connections,
        s.nextMove and ("piece " .. s.nextMove.piece) or "none"))
    -- the session poll. The worker wakes every POLL_MS but only does game-thread
    -- work (the tick, cached references only) every POLL_NORMAL_EVERY wakes in
    -- normal play (~400ms, as before); while FAST auto-solve is engaged it ticks
    -- EVERY wake so the route executes as fast as moves are honoured. A session
    -- that is no longer the live one, or stopped, returns true and the loop ends.
    local pollWakes = 0
    LoopAsync(POLL_MS, function()
        if liveSession ~= s or s.stop then
            -- one reliable end-of-session line on EVERY teardown path (solved and
            -- looted, exited, evicted, world change). The driver's own "lock
            -- solved" line is not guaranteed on a fast solve (the session can halt
            -- before the driver's next step), so this is the authoritative "it is
            -- off now" confirmation. Pairs with the start banner. Fires once: the
            -- loop stops the moment it returns true.
            log("Lockpick session ended for '" .. tostring(s.lockName)
                .. "': tracking, hint and auto-solve off")
            return true
        end
        pollWakes = pollWakes + 1
        local ap = s.autopilot
        local fast = ap and ap.mode == "fast"
        if not fast and (pollWakes % POLL_NORMAL_EVERY) ~= 0 then
            return false -- normal cadence: no game-thread work this wake
        end
        -- re-entrancy guard: at the aggressive fast cadence a wake can arrive
        -- before the previous tick finished on the game thread. Skip it so ticks
        -- never queue or backlog; the effective rate self-throttles to the tick's
        -- real cost (so POLL_MS can be set very low safely).
        if s.ticking then return false end
        s.ticking = true
        ExecuteInGameThread(function()
            local ok, err = pcall(function() s:tick() end)
            s.ticking = false
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

-- ----------------------------------------------------------- auto-solve --
-- F6 steps one solver move; Shift+F6 toggles full-auto (both configurable in
-- config.lua). Same debounce-and-defer shape as the toggles: the handler only
-- arms the driver on the game thread; the session tick does the work and only
-- ever touches the live session.
local ModifierKey = rawget(_G, "ModifierKey")
local lastAutoStep, lastAutoFull = 0, 0
if driver and type(AutoStepKey) == "string" and AutoStepKey ~= "" then
    if Key[AutoStepKey] then
        pcall(RegisterKeyBind, Key[AutoStepKey], function()
            local now = os.clock()
            if now - lastAutoStep < 0.3 then return end
            lastAutoStep = now
            ExecuteInGameThread(function()
                pcall(function() driver:armSingle(liveSession) end)
            end)
        end)
    else
        log("ERROR: unknown autoSolveStepHotkey '" .. AutoStepKey
            .. "', auto-solve step disabled")
    end
end
if driver and type(AutoFullKey) == "string" and AutoFullKey ~= "" then
    local mod = nil
    if type(AutoFullMod) == "string" and AutoFullMod ~= "" then
        mod = ModifierKey and ModifierKey[AutoFullMod]
        if not mod then
            log("ERROR: unknown autoSolveFullModifier '" .. AutoFullMod
                .. "', full-auto registered without a modifier")
        end
    end
    local handler = function()
        local now = os.clock()
        if now - lastAutoFull < 0.3 then return end
        lastAutoFull = now
        ExecuteInGameThread(function()
            pcall(function() driver:toggleFull(liveSession) end)
        end)
    end
    if Key[AutoFullKey] then
        local ok
        if mod then
            ok = pcall(RegisterKeyBind, Key[AutoFullKey], { mod }, handler)
        else
            ok = pcall(RegisterKeyBind, Key[AutoFullKey], handler)
        end
        if not ok then log("ERROR: could not register full-auto hotkey") end
    else
        log("ERROR: unknown autoSolveFullHotkey '" .. AutoFullKey
            .. "', full-auto disabled")
    end
end
-- Ctrl+F6 (configurable modifier): FAST full-auto. Same key as full-auto, with
-- autoSolveFastModifier; arms the driver's fast mode (the session then ticks every
-- poll wake while it runs).
local lastAutoFast = 0
if driver and type(AutoFullKey) == "string" and AutoFullKey ~= ""
    and type(AutoFastMod) == "string" and AutoFastMod ~= "" and Key[AutoFullKey] then
    local fmod = ModifierKey and ModifierKey[AutoFastMod]
    if not fmod then
        log("ERROR: unknown autoSolveFastModifier '" .. AutoFastMod
            .. "', fast-auto disabled")
    else
        local ok = pcall(RegisterKeyBind, Key[AutoFullKey], { fmod }, function()
            local now = os.clock()
            if now - lastAutoFast < 0.3 then return end
            lastAutoFast = now
            ExecuteInGameThread(function()
                pcall(function() driver:toggleFast(liveSession) end)
            end)
        end)
        if not ok then log("ERROR: could not register fast-auto hotkey") end
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
    -- BackPressed CANCELS the minigame (the player exiting). Stop the session and
    -- any auto-solve run NOW, before the task tears down, so nothing presses a
    -- dying task. The task-liveness gate in session.tick is the backstop for exit
    -- paths that do not route through BackPressed; this is the immediate one.
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
                Boost.apply(ExtraTries, Engine, Num, log)
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
if Boost then
    for name, base in pairs(Boost.BASE_TRIES) do
        loaded[#loaded + 1] = string.format("%s %d->%d", name, base, base + ExtraTries)
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
    if not AutoSolveBroken then
        local autoKeys = {}
        if type(AutoStepKey) == "string" and AutoStepKey ~= ""
            and Key[AutoStepKey] then
            autoKeys[#autoKeys + 1] = AutoStepKey .. " step"
        end
        if type(AutoFullKey) == "string" and AutoFullKey ~= ""
            and Key[AutoFullKey] then
            local pfx = (type(AutoFullMod) == "string" and AutoFullMod ~= "")
                and (AutoFullMod .. "+") or ""
            autoKeys[#autoKeys + 1] = pfx .. AutoFullKey .. " full-auto"
            if type(AutoFastMod) == "string" and AutoFastMod ~= "" then
                autoKeys[#autoKeys + 1] = AutoFastMod .. "+" .. AutoFullKey .. " fast"
            end
        end
        if #autoKeys > 0 then
            hintInfo = hintInfo .. ", auto-solve: " .. table.concat(autoKeys, ", ")
        end
    end
end
log("Loaded " .. ModVersion .. " (kit " .. tostring(kit.version) .. "): "
    .. table.concat(loaded, ", ") .. hintInfo)
