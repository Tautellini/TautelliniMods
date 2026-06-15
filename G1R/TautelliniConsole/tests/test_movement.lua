-- test_movement.lua  --  the fly/noclip/flyspeed/up/down command wiring is pure
-- once the engine is injected. We drive the real spec closures with a fake engine
-- that records property writes and a fake location. (The in-game question,
-- whether the game HONORS these, is separate.)

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local movement = require("cheats.movement")

local function fakeEngine()
    local mc = { props = {} }
    local ai = { props = {} }       -- low-level (movement comp) anim instance
    local mainAi = { props = {} }   -- GothicAnimInstance (sneak/jump flags)
    local vol = { props = { bWaterVolume = false } } -- the physics volume
    local pawn = { collision = true, launched = nil, props = {}, vinput = 0 }
    local e = {
        isValid = function(o) return o == pawn end,
        findPlayerPawn = function() return pawn end,
        movementComp = function(_p) return mc end,
        animInstance = function(_c) return ai end,
        mainAnimInstance = function(_p) return mainAi end,
        physicsVolume = function(_p) return vol end,
        getObjProp = function(o, n) return o.props and o.props[n] end,
        setObjProp = function(o, n, v) o.props = o.props or {}; o.props[n] = v; return true end,
        setActorCollision = function(p, on) p.collision = on; return true end,
        launchZ = function(p, vz) p.launched = vz; return true end,
        addMovementInput = function(p, _x, _y, z, _s) p.vinput = z; return true end,
    }
    return e, mc, ai, pawn, mainAi, vol
end

local function fakeOut()
    local o = { lines = {} }
    o.line = function(m) o.lines[#o.lines + 1] = m end
    return o
end

local function spec(name)
    for _, s in ipairs(movement.specs()) do
        if s.name == name then return s end
    end
    error("no movement spec named " .. name)
end

T.add("fly on flags the volume as water and sets swimming mode", function()
    local e, mc, _ai, _pawn, _mainAi, vol = fakeEngine()
    spec("fly").run({ "on" }, fakeOut(), e)
    T.eq(mc.props.MovementMode, 4) -- MOVE_Swimming
    T.eq(vol.props.bWaterVolume, true)
    T.eq(movement.isFlying(), true)
end)

T.add("fly off restores walking and the original water flag", function()
    local e, mc, _ai, _pawn, _mainAi, vol = fakeEngine()
    spec("fly").run({ "on" }, fakeOut(), e) -- saves bWaterVolume=false
    spec("fly").run({ "off" }, fakeOut(), e)
    T.eq(mc.props.MovementMode, 1)
    T.eq(vol.props.bWaterVolume, false, "the original water flag is restored")
    T.eq(movement.isFlying(), false)
end)

T.add("holdTick keeps the water flag set while on, no-op when off", function()
    local e, _mc, _ai, _pawn, _mainAi, vol = fakeEngine()
    spec("fly").run({ "on" }, fakeOut(), e)
    vol.props.bWaterVolume = false -- simulate the game clearing it
    movement.holdTick(e)
    T.eq(vol.props.bWaterVolume, true, "the tick re-flags it as water")
    spec("fly").run({ "off" }, fakeOut(), e)
    vol.props.bWaterVolume = false
    movement.holdTick(e) -- no-op now
    T.eq(vol.props.bWaterVolume, false)
end)

T.add("flydbg watch logs only changed flags after a baseline", function()
    local e, _mc, _ai, _pawn, mainAi = fakeEngine()
    spec("flydbg").run({ "on" }, fakeOut(), e)
    T.eq(movement.isWatching(), true)
    local logs = {}
    local log = function(m) logs[#logs + 1] = m end
    movement.watchTick(e, log) -- baseline, logs nothing
    T.eq(#logs, 0)
    mainAi.props.bIsCrouching = true
    movement.watchTick(e, log) -- now logs the change
    T.ok(#logs >= 1, "a flag change should be logged")
    T.ok(logs[#logs]:find("bIsCrouching", 1, true) ~= nil, "logs the changed flag")
    spec("flydbg").run({ "off" }, fakeOut(), e)
    T.eq(movement.isWatching(), false)
end)

T.add("flyspeed <n> writes MaxSwimSpeed and MaxFlySpeed; bare prints swim", function()
    local e, mc = fakeEngine()
    spec("flyspeed").run({ "2000" }, fakeOut(), e)
    T.eq(mc.props.MaxSwimSpeed, 2000)
    T.eq(mc.props.MaxFlySpeed, 2000)
    mc.props.MaxSwimSpeed = 600
    local out = fakeOut()
    spec("flyspeed").run({}, out, e)
    T.eq(out.lines[#out.lines], "flyspeed (swim) = 600")
end)

T.add("noclip on disables collision, off restores it", function()
    local e, _mc, _ai, pawn = fakeEngine()
    spec("noclip").run({ "on" }, fakeOut(), e)
    T.eq(pawn.collision, false)
    spec("noclip").run({ "off" }, fakeOut(), e)
    T.eq(pawn.collision, true)
end)

T.add("up launches up, down launches down, with the given speed", function()
    local e, _mc, _ai, pawn = fakeEngine()
    spec("up").run({ "1000" }, fakeOut(), e)
    T.eq(pawn.launched, 1000)
    spec("down").run({ "600" }, fakeOut(), e)
    T.eq(pawn.launched, -600)
end)

T.add("bare up uses the default launch speed", function()
    local e, _mc, _ai, pawn = fakeEngine()
    spec("up").run({}, fakeOut(), e)
    T.eq(pawn.launched, 1500)
end)

os.exit(T.run())
