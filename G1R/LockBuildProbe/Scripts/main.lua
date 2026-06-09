-- LockBuildProbe: dev-only investigation mod, NOT for shipping.
--
-- TECH-DEBT investigation item 2 (LockpickSettings/TECH-DEBT.md): can the lock
-- CONNECTION GRAPH be CAPTURED from the running game at build time, even though
-- item 1 proved it is reflected nowhere (no property, return value or parameter
-- has the LockConnections/LockOneConnection type)?
--
-- The graph is built by GothicLockConfig:AddPiece and :AddConnection, two
-- write-only natives. The game's AngelScript calls them through its own native
-- binding table (a CALLSYS to a raw C++ pointer, per the blob format notes),
-- which bypasses UE UFunction dispatch, so the standard RegisterHook is EXPECTED
-- to never fire (see LuaModdingSurface.md, "AS bypass"). This probe fact-checks
-- that against every Lua-level capture seam at once:
--   A. RegisterHook on /Script/G1R.GothicLockConfig:AddPiece and :AddConnection.
--      With HookProcessInternal, HookProcessLocalScriptFunction and
--      HookCallFunctionByNameWithArguments all enabled in UE4SS-settings.ini
--      (verified 2026-06-09), this one test also covers whether those alternate
--      dispatch points catch the AS-native calls.
--   B. RegisterCustomEvent by short name ("AddPiece" / "AddConnection"): the
--      name-based seam the investigation plan calls out specifically.
--
-- The locks are pre-instanced at WORLD load (LockPickSubsystem.m_InstancedLocks),
-- so the build calls fire there, not during the minigame. The hooks are armed at
-- mod load, before any world loads, so a fresh launch then a save load is the
-- observable window. The world-load backstop logs a marker so captures can be
-- placed relative to each instancing pass.
--
-- READ-ONLY. It never calls AddPiece/AddConnection itself (they are write-only
-- and would corrupt a lock config). No polling loop and no FindAllOf sweep: it
-- only reacts to hook fires, so it is far lighter than the geometry LockProbe and
-- cannot cause the per-tick FindAllOf hitches that mod warned about.
--
-- VERDICT to read off the log: if ANY AddConnection/AddPiece capture is logged,
-- the build calls are observable and the capture approach is viable (timing just
-- needs refining). If the counters stay 0 across a fresh launch, a save load and
-- opening a lock, capture via these seams is dead, and items 1 and 2 are both a
-- definitive no (the realistic path is then the live-learning + audit items).
--
-- Usage: deploy, FULLY RESTART the game (hooks load at boot), load a save (this
-- instances the locks), open any lock, press F9 for the running summary, then
-- send the UE4SS.log ([LockBuildProbe] lines).

local pcall, tostring, type, tonumber, string =
    pcall, tostring, type, tonumber, string

local function log(msg)
    print("[LockBuildProbe] " .. tostring(msg) .. "\n")
end

local function firstLine(e)
    local sx = tostring(e)
    sx = string.match(sx, "[^\r\n]+") or sx
    return (string.gsub(sx, ".*[/\\]main%.lua:%d+: ", ""))
end

-- counters per seam, plus a small detailed sample (instancing can fire thousands
-- of calls in one pass: log the first few in full, then just count)
local stat = { hookPiece = 0, hookConn = 0, evtPiece = 0, evtConn = 0 }
local SAMPLE_MAX = 24
local samples = 0

-- UE4SS hands hook/event args as RemoteUnrealParam userdata (call :get()); be
-- liberal so a build that passes plain values still reads
local function rget(p)
    if type(p) == "userdata" then
        local ok, v = pcall(function() return p:get() end)
        if ok and v ~= nil then return v end
    end
    return p
end

local function asInt(p)
    local v = rget(p)
    local n = tonumber(v)
    return n or v
end

local function lockNameOf(ctx)
    local obj = rget(ctx)
    local nm
    pcall(function()
        local u = obj.m_UniqueName
        if type(u) == "userdata" and u.ToString then
            nm = u:ToString()
        else
            nm = tostring(u)
        end
    end)
    return nm or "?"
end

local function onPiece(via, ctx, id, rot)
    if via == "hook" then stat.hookPiece = stat.hookPiece + 1
    else stat.evtPiece = stat.evtPiece + 1 end
    if samples < SAMPLE_MAX then
        samples = samples + 1
        log(string.format("CAPTURE[%s] AddPiece(%s, %s) on %s", via,
            tostring(asInt(id)), tostring(asInt(rot)), lockNameOf(ctx)))
    end
end

local function onConn(via, ctx, id, connId, dir)
    if via == "hook" then stat.hookConn = stat.hookConn + 1
    else stat.evtConn = stat.evtConn + 1 end
    if samples < SAMPLE_MAX then
        samples = samples + 1
        log(string.format("CAPTURE[%s] AddConnection(%s, %s, %s) on %s", via,
            tostring(asInt(id)), tostring(asInt(connId)), tostring(asInt(dir)),
            lockNameOf(ctx)))
    end
end

local function summary(tag)
    log(string.format("%s | hook: AddPiece=%d AddConnection=%d | event: "
        .. "AddPiece=%d AddConnection=%d", tag, stat.hookPiece, stat.hookConn,
        stat.evtPiece, stat.evtConn))
    local total = stat.hookPiece + stat.hookConn + stat.evtPiece + stat.evtConn
    if total == 0 then
        log(tag .. " -> NO build calls observed yet (AS-native bypass holds for "
            .. "these seams)")
    else
        log(tag .. " -> build calls ARE observable: capture is viable")
    end
end

-- ----------------------------------------------------------- arm the seams --

-- A. UFunction hooks (covers ProcessInternal/LocalScriptFunction/ByName reach
--    too, since those flags are enabled). Each callback is its own pcall so a
--    bad arg read inside a hook can never escape into the engine.
local function regHook(name, fn)
    local ok, e = pcall(function() RegisterHook(name, fn) end)
    log("RegisterHook " .. name .. ": " .. (ok and "armed" or ("FAILED "
        .. firstLine(e))))
end
regHook("/Script/G1R.GothicLockConfig:AddPiece", function(ctx, a, b)
    pcall(onPiece, "hook", ctx, a, b)
end)
regHook("/Script/G1R.GothicLockConfig:AddConnection", function(ctx, a, b, c)
    pcall(onConn, "hook", ctx, a, b, c)
end)

-- B. name-based custom-event hooks
local function regEvt(name, fn)
    local ok, e = pcall(function() RegisterCustomEvent(name, fn) end)
    log("RegisterCustomEvent " .. name .. ": " .. (ok and "armed" or ("FAILED "
        .. firstLine(e))))
end
regEvt("AddPiece", function(ctx, a, b) pcall(onPiece, "event", ctx, a, b) end)
regEvt("AddConnection", function(ctx, a, b, c)
    pcall(onConn, "event", ctx, a, b, c)
end)

-- world-load marker: locks instance around here, so captures should land just
-- after one of these if the seams work at all
local gen = 0
pcall(RegisterInitGameStatePostHook, function()
    gen = gen + 1
    log("world load #" .. gen .. " (locks instance around here)")
    summary("after world load #" .. gen)
end)

-- a minigame start is well after instancing: a clean point to read the totals
pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick", function()
    summary("minigame start")
end)

-- on-demand summary without restarting
pcall(function()
    RegisterKeyBind(Key.F9, function()
        ExecuteInGameThread(function() summary("F9") end)
    end)
end)

log("loaded: connection-capture seams armed. FULLY RESTART the game, load a "
    .. "save, open a lock, press F9 for the summary, send the log.")
