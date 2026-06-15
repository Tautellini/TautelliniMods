-- cheats/movement.lua  --  fly, noclip, flyspeed, up, down. EXPERIMENTAL.
--
-- fly = MOVE_Flying + gravity 0: a stable hover with horizontal movement from the
-- normal controls. This is the one mode that HOLDS on land. (Swim-mode gave true
-- 3D control but only in water; forcing it on land just oscillates and breaks
-- movement. Clearing the locomotion flatten flag did nothing.) So vertical comes
-- from up/down, which teleport the pawn.
-- noclip toggles collision; flyspeed sets MaxFlySpeed. The pawn is CACHED
-- (revalidated each use) so we do not FindAllOf per command. PURE of UE4SS
-- globals: engine is injected.

local require, tostring, tonumber, ipairs, type =
    require, tostring, tonumber, ipairs, type
local args = require("util.args")

local movement = {}

-- EMovementMode values (engine enum): walking = 1, flying = 5.
local MOVE_WALKING = 1
local MOVE_FLYING  = 5
-- EMovementMode walking / swimming. fly reproduces the in-water state by flagging
-- the player's physics volume as water, which keeps the game in MOVE_Swimming on
-- land (the only state that gives true 3D control from the normal controls).
local MOVE_WALKING  = 1
local MOVE_SWIMMING = 4
-- default up/down launch velocity (game units/sec) for the up/down commands.
local LAUNCH_SPEED = 1500

local flyOn = false
local noclipOn = false

local cachedPawn
-- the physics volume we flagged as water, and its original flag, to restore.
local waterVol = nil
local savedWaterFlag = nil

local function resolvePawn(engine, out, label)
    if engine.isValid(cachedPawn) then return cachedPawn end
    cachedPawn = engine.findPlayerPawn()
    if not cachedPawn then
        if out then out.line(label .. ": no player pawn (be in-game)") end
        return nil
    end
    return cachedPawn
end

local function resolveComp(engine, out, label)
    local pawn = resolvePawn(engine, out, label)
    if not pawn then return nil end
    local mc = engine.movementComp(pawn)
    if not mc then
        if out then out.line(label .. ": no movement component on the pawn") end
        return nil
    end
    return mc
end

local function doFly(params, out, engine)
    local verb = args.toggleVerb(params[1])
    if verb == nil then out.line("usage: fly [on|off]"); return end
    local want
    if verb == "toggle" then want = not flyOn else want = (verb == "on") end

    local mc = resolveComp(engine, out, "fly")
    if not mc then return end
    local pawn = cachedPawn

    if want then
        -- flag the player's physics volume as water so the game keeps you in
        -- MOVE_Swimming (true 3D control). Saved and restored on fly off.
        local vol = engine.physicsVolume(pawn)
        if vol then
            waterVol = vol
            savedWaterFlag = engine.getObjProp(vol, "bWaterVolume")
            engine.setObjProp(vol, "bWaterVolume", true)
        end
        engine.setObjProp(mc, "MovementMode", MOVE_SWIMMING)
        flyOn = true
        local tail = ""
        if not vol then tail = " [no physics volume found]" end
        out.line("fly ON (swim-fly): move in 3D with your normal controls, like "
            .. "swimming." .. tail .. " Experimental; tell me if it does nothing, "
            .. "drifts, or makes nearby NPCs swim.")
    else
        engine.setObjProp(mc, "MovementMode", MOVE_WALKING)
        if waterVol and savedWaterFlag ~= nil then
            engine.setObjProp(waterVol, "bWaterVolume", savedWaterFlag)
        end
        waterVol, savedWaterFlag = nil, nil
        flyOn = false
        out.line("fly OFF (walking, water flag restored).")
    end
end

local function doNoclip(params, out, engine)
    local verb = args.toggleVerb(params[1])
    if verb == nil then out.line("usage: noclip [on|off]"); return end
    local want
    if verb == "toggle" then want = not noclipOn else want = (verb == "on") end

    local pawn = resolvePawn(engine, out, "noclip")
    if not pawn then return end

    if want then
        engine.setActorCollision(pawn, false)
        noclipOn = true
        out.line("noclip ON (collision off). Turn 'fly' on too, or you will fall "
            .. "through the world.")
    else
        engine.setActorCollision(pawn, true)
        noclipOn = false
        out.line("noclip OFF (collision restored).")
    end
end

local function doFlySpeed(params, out, engine)
    local mc = resolveComp(engine, out, "flyspeed")
    if not mc then return end
    -- swim-fly runs in MOVE_Swimming, so MaxSwimSpeed is the cap that matters; we
    -- also set MaxFlySpeed in case the mode changes.
    if params[1] == nil then
        out.line("flyspeed (swim) = " .. tostring(engine.getObjProp(mc, "MaxSwimSpeed")))
        return
    end
    local n = tonumber(params[1])
    if not n then
        out.line("usage: flyspeed <number>  (e.g. flyspeed 2000)")
        return
    end
    local ok = engine.setObjProp(mc, "MaxSwimSpeed", n)
    engine.setObjProp(mc, "MaxFlySpeed", n)
    if ok then
        out.line("flyspeed set to " .. n .. " (MaxSwimSpeed + MaxFlySpeed)")
    else
        out.line("flyspeed: write failed")
    end
end

local function vertical(params, out, engine, sign, label)
    local pawn = resolvePawn(engine, out, label)
    if not pawn then return end
    local n = tonumber(params[1]) or LAUNCH_SPEED
    if n < 0 then n = -n end
    if engine.launchZ(pawn, sign * n) then
        out.line(label .. " (launch " .. n .. ")"
            .. (flyOn and "" or " (enable 'fly' first so you do not fall back)"))
    else
        out.line(label .. ": failed")
    end
end

-- for the main.lua tick: is fly on?
function movement.isFlying()
    return flyOn
end

-- for the main.lua tick: is fly on? (drives the watch loop too.)

-- per-frame fly upkeep while fly is on: keep the physics volume flagged as water
-- so swimming sticks. We do NOT force MovementMode here (that is what oscillated
-- before): the water flag lets the game keep swimming on its own. Cheap + silent.
function movement.holdTick(engine)
    if not flyOn then return end
    if waterVol then engine.setObjProp(waterVol, "bWaterVolume", true) end
end

-- diagnostic: `flydbg` prints state once; `flydbg on` watches it every frame and
-- logs any CHANGE to the UE4SS log, so the player can do what the console can not,
-- hold an input, or WALK INTO WATER. The water transition is the prize: it shows
-- exactly what state makes swimming stick, which is what we want to reproduce.
local function flydbgSources(engine, pawn)
    local mc = engine.movementComp(pawn)
    local ai = engine.mainAnimInstance(pawn)
    local dm = ai and engine.getObjProp(ai, "m_DataModule_Locomotion")
    return {
        { src = "mc", obj = mc, names = { "MovementMode", "GravityScale" } },
        { src = "anim", obj = ai, names = { "m_MovementAction", "m_MovementState",
            "bIsCrouching", "m_IsInWater", "m_InWaterDepth", "m_DesiredSwimType",
            "m_SwimSpeed" } },
        { src = "loco", obj = dm, names = { "m_MovementState", "m_MovementAction",
            "m_IsBuoyancyEnabled" } },
        { src = "pawn", obj = pawn, names = { "bIsCrouched" } },
    }
end

local watchOn = false
local watchPrev = {}

local function doFlyDbg(params, out, engine)
    local verb = args.lower(params[1])
    if verb == "on" then
        watchOn, watchPrev = true, {}
        out.line("flydbg watch ON. Close the console, then do the thing (hold an "
            .. "input, or walk into and out of water). Changes go to the UE4SS log "
            .. "as 'watch ...'. Type 'flydbg off' when done.")
        return
    elseif verb == "off" then
        watchOn = false
        out.line("flydbg watch OFF.")
        return
    end
    local pawn = resolvePawn(engine, out, "flydbg")
    if not pawn then return end
    out.line("flydbg (one-shot; 'flydbg on' to watch inputs / water):")
    for _, s in ipairs(flydbgSources(engine, pawn)) do
        if not s.obj then
            out.line("  " .. s.src .. ": <not found>")
        else
            for _, n in ipairs(s.names) do
                out.line("  " .. s.src .. "." .. n .. " = "
                    .. tostring(engine.getObjProp(s.obj, n)))
            end
        end
    end
end

function movement.isWatching()
    return watchOn
end

-- poll the watch sources; log only flags that CHANGED since last poll (the first
-- poll records a silent baseline). log is injected (kit logger).
function movement.watchTick(engine, log)
    if not watchOn then return end
    local pawn = resolvePawn(engine, nil, "flydbg")
    if not pawn then return end
    for _, s in ipairs(flydbgSources(engine, pawn)) do
        if s.obj then
            for _, n in ipairs(s.names) do
                local key = s.src .. "." .. n
                local sv = tostring(engine.getObjProp(s.obj, n))
                if watchPrev[key] ~= sv then
                    if watchPrev[key] ~= nil then
                        log("watch " .. key .. ": " .. watchPrev[key] .. " -> " .. sv)
                    end
                    watchPrev[key] = sv
                end
            end
        end
    end
end

function movement.specs()
    return {
        { name = "fly",
          help = "flight/hover toggle [on|off]",
          run = function(p, out, engine) doFly(p, out, engine) end },
        { name = "noclip",
          help = "collision-off toggle [on|off] (use with fly)",
          run = function(p, out, engine) doNoclip(p, out, engine) end },
        { name = "flyspeed",
          help = "print or set swim/fly speed (e.g. flyspeed 2000)",
          run = function(p, out, engine) doFlySpeed(p, out, engine) end },
        { name = "up",
          help = "rise (up [speed], default 1500). Use with fly on.",
          run = function(p, out, engine) vertical(p, out, engine, 1, "up") end },
        { name = "down",
          help = "descend (down [speed], default 1500). Use with fly on.",
          run = function(p, out, engine) vertical(p, out, engine, -1, "down") end },
        { name = "flydbg",
          help = "dump fly input-state flags (run while sneaking/blocking/jumping)",
          run = function(p, out, engine) doFlyDbg(p, out, engine) end },
    }
end

return movement
