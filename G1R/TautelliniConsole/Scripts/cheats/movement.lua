-- cheats/movement.lua  --  fly (free no-clip flight), runspeed, noclip.
--
-- fly is an authoritative-position driver: the Gothic movement component re-applies
-- its own mode/gravity every frame, so we override it. Each frame (driven by
-- main.lua's single LoopAsync via movement.holdTick -- NO second loop, so nothing
-- dangles across a hot reload) we zero gravity + force Falling, advance a tracked
-- position along the camera look from the WASD intent, and AddActorWorldOffset
-- toward it. Collision is off while flying (true no-clip). runspeed scales the
-- Movement SpeedModifier. PURE of UE4SS globals: engine is injected.

local require, tonumber, tostring, math = require, tonumber, tostring, math
local args = require("util.args")

local movement = {}

local FLY_SPEED       = 1500.0   -- cm/s base flight speed
local FLY_ENABLE_LIFT = 300.0    -- smooth upward nudge on enable (so you clear the ground)
local FLY_RISE_SPEED  = 600.0    -- cm/s of that nudge
local DT              = 0.016     -- ~per-frame seconds (the loop runs at 16 ms)

local fly = { on = false, speed = FLY_SPEED,
              posX = nil, posY = nil, posZ = nil, rise = 0,
              savedGravity = nil, savedSmoothing = nil }
local noclipOn = false

local cachedPawn
local function resolvePawn(engine)
    if engine.isValid(cachedPawn) then return cachedPawn end
    cachedPawn = engine.findPlayerPawn()
    return cachedPawn
end

-- pure: project the WASD intent (ix, iy world input) onto the camera look (yaw,
-- pitch in degrees) -> a move vector (mx, my, mz). Looking up while moving climbs.
-- Exposed for tests.
local function project(ix, iy, yaw, pitch)
    local imag = math.sqrt(ix * ix + iy * iy)
    if imag > 0.0001 then ix, iy = ix / imag, iy / imag end
    local yawR, pitchR = yaw * math.pi / 180.0, pitch * math.pi / 180.0
    local cp = math.cos(pitchR)
    local fX, fZ = cp * math.cos(yawR), math.sin(pitchR)
    local fY = cp * math.sin(yawR)
    local rX, rY = -math.sin(yawR), math.cos(yawR)
    local fhX, fhY = math.cos(yawR), math.sin(yawR)
    local fwdAmt = ix * fhX + iy * fhY
    local rightAmt = ix * rX + iy * rY
    return fX * fwdAmt + rX * rightAmt, fY * fwdAmt + rY * rightAmt, fZ * fwdAmt
end
movement._project = project

local function setFly(engine, want)
    local pawn = resolvePawn(engine)
    if not pawn then return "fly: no player pawn (be in-game)" end
    if want then
        fly.savedGravity, fly.savedSmoothing = engine.flyEnable(pawn, fly.speed)
        fly.posX, fly.posY, fly.posZ = nil, nil, nil
        fly.rise = FLY_ENABLE_LIFT
        fly.on = true
        engine.persist("flying", true) -- so a CTRL+R mid-flight can be recovered
        return "fly ON: W/A/S/D + look to fly (look up while moving to climb). "
            .. "Turn it OFF in open space, not inside a wall."
    end
    fly.on = false
    engine.flyDisable(pawn, fly.savedGravity, fly.savedSmoothing)
    fly.savedGravity, fly.savedSmoothing = nil, nil
    engine.persist("flying", false)
    return "fly OFF."
end

function movement.isFlying() return fly.on end

-- a hot reload nils fly.on (and the saved gravity/collision) while the pawn is still
-- in the flight pose; main.lua calls this once on load to put collision + flying
-- back to normal so the player is not stuck no-clipping. The Gothic move comp
-- re-applies its own gravity, so a nil saved value still recovers.
function movement.recover(engine)
    if not engine.persisted("flying") then return end
    if fly.on then return end
    local pawn = resolvePawn(engine)
    if pawn then engine.flyDisable(pawn, nil, nil) end
    engine.persist("flying", false)
end

-- one flight frame, called by main.lua's loop while fly is on.
function movement.holdTick(engine)
    if not fly.on then return end
    local pawn = resolvePawn(engine)
    if not pawn then return end
    local mc = engine.flyComp(pawn)
    local loco = engine.locoModule(pawn)
    engine.flyUpkeep(mc, loco)

    if not fly.posX then
        local x, y, z = engine.getActorLocation(pawn)
        if not x then return end
        fly.posX, fly.posY, fly.posZ, fly.rise = x, y, z, FLY_ENABLE_LIFT
    end

    local ix, iy, amt = engine.flyInput(loco)
    local yaw, pitch = engine.controlRotation(pawn)
    local dX, dY, dZ = 0.0, 0.0, 0.0
    if fly.rise and fly.rise > 0 then
        local rstep = math.min(fly.rise, FLY_RISE_SPEED * DT)
        dZ = rstep
        fly.rise = fly.rise - rstep
    elseif amt > 0.05 and yaw then
        local mX, mY, mZ = project(ix, iy, yaw, pitch)
        local len = math.sqrt(mX * mX + mY * mY + mZ * mZ)
        if len > 0.01 then
            local step = fly.speed * DT / len
            dX, dY, dZ = mX * step, mY * step, mZ * step
        end
    end
    fly.posX, fly.posY, fly.posZ = fly.posX + dX, fly.posY + dY, fly.posZ + dZ
    local cx, cy, cz = engine.getActorLocation(pawn)
    if cx then engine.addActorWorldOffset(pawn, fly.posX - cx, fly.posY - cy, fly.posZ - cz) end
end

-- noclip is independent of fly (fly already disables collision); kept so you can drop
-- collision without flight.
local function setNoclip(engine, want)
    local pawn = resolvePawn(engine)
    if not pawn then return false end
    engine.setActorCollision(pawn, not want)
    noclipOn = want
    return true
end

local function doFly(params, out, engine)
    local verb = args.toggleVerb(params[1])
    if verb == nil then out.line("usage: fly [on|off] [speed]"); return end
    local want
    if verb == "toggle" then want = not fly.on else want = (verb == "on") end
    local n = tonumber(params[2]); if n and n > 0 then fly.speed = n end
    out.line(setFly(engine, want))
end

local function doNoclip(params, out, engine)
    local verb = args.toggleVerb(params[1])
    if verb == nil then out.line("usage: noclip [on|off]"); return end
    local want
    if verb == "toggle" then want = not noclipOn else want = (verb == "on") end
    if setNoclip(engine, want) then
        out.line("noclip: " .. (want and "ON (collision off)" or "OFF"))
    else
        out.line("noclip: no player pawn (be in-game)")
    end
end

local function doRunSpeed(params, out, engine)
    if params[1] == nil then
        out.line("runspeed = " .. tostring(engine.getRunSpeed()) .. " (1 = normal)")
        return
    end
    local n = tonumber(params[1])
    if not n or n <= 0 then out.line("usage: runspeed <multiplier> (e.g. runspeed 2)"); return end
    out.line(engine.setRunSpeed(n) and ("runspeed: " .. n .. "x") or "runspeed: failed (be in-game)")
end

function movement.specs()
    return {
        { name = "fly",
          help = "free no-clip flight [on|off] [speed]",
          run = function(p, out, engine) doFly(p, out, engine) end },
        { name = "noclip",
          help = "collision-off toggle [on|off]",
          run = function(p, out, engine) doNoclip(p, out, engine) end },
        { name = "runspeed",
          help = "run-speed multiplier (1 = normal, 2 = double)",
          run = function(p, out, engine) doRunSpeed(p, out, engine) end },
    }
end

-- SharedModMenu: the Movement tab.
function movement.menu(engine)
    return { title = "Movement", items = {
        { name = "Fly Mode", kind = "bool",
          get = function() return fly.on end,
          set = function(v) setFly(engine, v and true or false) end },
        { name = "No-Clip", kind = "bool",
          get = function() return noclipOn end,
          set = function(v) setNoclip(engine, v and true or false) end },
        { name = "Run Speed", kind = "num", min = 0.5, max = 5, step = 0.25,
          get = function() return engine.getRunSpeed() end,
          set = function(v) engine.setRunSpeed(v) end },
    } }
end

return movement
