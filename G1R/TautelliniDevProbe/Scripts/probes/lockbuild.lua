-- probes/lockbuild.lua  --  dev-only: can the lock CONNECTION GRAPH be CAPTURED from
-- the running game at build time? (TECH-DEBT investigation item 2.)
--
-- The graph is built by GothicLockConfig:AddPiece and :AddConnection, two write-only
-- natives. The game's AngelScript calls them through its own native binding table (a
-- CALLSYS to a raw C++ pointer), which bypasses UE UFunction dispatch, so the standard
-- RegisterHook is EXPECTED to never fire (see LuaModdingSurface.md, "AS bypass"). This
-- probe fact-checks that against every Lua-level capture seam at once:
--   A. RegisterHook on /Script/G1R.GothicLockConfig:AddPiece and :AddConnection.
--      With HookProcessInternal, HookProcessLocalScriptFunction and
--      HookCallFunctionByNameWithArguments all enabled in UE4SS-settings.ini, this one
--      test also covers whether those alternate dispatch points catch the AS calls.
--   B. RegisterCustomEvent by short name ("AddPiece" / "AddConnection"): the name-based
--      seam the investigation plan calls out specifically.
--
-- The locks are pre-instanced at WORLD load (LockPickSubsystem.m_InstancedLocks), so the
-- build calls fire there, not during the minigame. The world-load init marker logs a
-- marker so captures can be placed relative to each instancing pass.
--
-- READ-ONLY. It never calls AddPiece/AddConnection itself (write-only; calling them would
-- corrupt a lock config). No polling loop and no FindAllOf sweep: it only reacts to seam
-- fires, so it is far lighter than the geometry probe.
--
-- VERDICT to read off the log: if ANY AddConnection/AddPiece capture is logged, the build
-- calls are observable and capture is viable. If the counters stay 0 across a fresh launch,
-- a save load and opening a lock, capture via these seams is dead.
--
-- Usage: FULLY RESTART the game (hooks load at boot), load a save (instances the locks),
-- open any lock, press F3 for the running summary, then send the UE4SS.log.

local pcall, tostring, type, tonumber, string =
    pcall, tostring, type, tonumber, string

return function(ctx)
    local log = ctx.makeLog("lockbuild")

    -- counters per seam, plus a small detailed sample (instancing can fire thousands of
    -- calls in one pass: log the first few in full, then just count)
    local stat = { hookPiece = 0, hookConn = 0, evtPiece = 0, evtConn = 0 }
    local SAMPLE_MAX = 24
    local samples = 0

    -- UE4SS hands hook/event args as RemoteUnrealParam userdata (call :get()); be liberal
    -- so a build that passes plain values still reads
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

    local function lockNameOf(c)
        local obj = rget(c)
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

    local function onPiece(via, c, id, rot)
        if via == "hook" then stat.hookPiece = stat.hookPiece + 1
        else stat.evtPiece = stat.evtPiece + 1 end
        if samples < SAMPLE_MAX then
            samples = samples + 1
            log(string.format("CAPTURE[%s] AddPiece(%s, %s) on %s", via,
                tostring(asInt(id)), tostring(asInt(rot)), lockNameOf(c)))
        end
    end

    local function onConn(via, c, id, connId, dir)
        if via == "hook" then stat.hookConn = stat.hookConn + 1
        else stat.evtConn = stat.evtConn + 1 end
        if samples < SAMPLE_MAX then
            samples = samples + 1
            log(string.format("CAPTURE[%s] AddConnection(%s, %s, %s) on %s", via,
                tostring(asInt(id)), tostring(asInt(connId)), tostring(asInt(dir)),
                lockNameOf(c)))
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

    local gen = 0

    return {
        name = "lockbuild",
        -- A. UFunction hooks (covers ProcessInternal/LocalScriptFunction/ByName too, since
        --    those flags are enabled). Each dispatch is pcall'd by main.lua already.
        hooks = {
            { path = "/Script/G1R.GothicLockConfig:AddPiece", tag = "AddPiece",
              cb = function(c, a, b) pcall(onPiece, "hook", c, a, b) end },
            { path = "/Script/G1R.GothicLockConfig:AddConnection", tag = "AddConnection",
              cb = function(c, a, b, d) pcall(onConn, "hook", c, a, b, d) end },
        },
        -- B. name-based custom-event seam
        events = {
            { name = "AddPiece",
              cb = function(c, a, b) pcall(onPiece, "event", c, a, b) end },
            { name = "AddConnection",
              cb = function(c, a, b, d) pcall(onConn, "event", c, a, b, d) end },
        },
        -- world-load marker: locks instance around here, so captures should land just
        -- after one of these if the seams work at all
        inits = {
            function()
                gen = gen + 1
                log("world load #" .. gen .. " (locks instance around here)")
                summary("after world load #" .. gen)
            end,
        },
        -- a minigame start is well after instancing: a clean point to read the totals
        notifies = {
            { path = "/Script/G1R.AbilityTask_LockPick",
              cb = function() summary("minigame start") end },
        },
        keys = {
            { key = "F3", desc = "on-demand connection-capture summary",
              fn = function() summary("F3") end },
        },
    }
end
