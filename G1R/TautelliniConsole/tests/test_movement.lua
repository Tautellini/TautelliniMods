-- test_movement.lua  --  the movement cheats: the pure camera-projection math and
-- the fly / noclip / runspeed state, driven through a fake engine (no UE4SS needed).

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local movement = require("cheats.movement")

local function fakeEngine()
    local store = { collision = true, runspeed = 1, flyEnabled = false, upkeep = 0 }
    local pawn = { tag = "pawn" }
    return {
        store = store,
        isValid = function(o) return o ~= nil end,
        findPlayerPawn = function() return pawn end,
        flyComp = function() return { tag = "mc" } end,
        locoModule = function() return { tag = "loco" } end,
        flyUpkeep = function() store.upkeep = store.upkeep + 1 end,
        flyInput = function() return 1, 0, 1 end,        -- forward, full magnitude
        controlRotation = function() return 0, 0 end,     -- yaw 0, pitch 0
        getActorLocation = function() return 100, 200, 300 end,
        addActorWorldOffset = function(_p, dx, dy, dz) store.lastOffset = { dx, dy, dz }; return true end,
        flyEnable = function(_p, speed) store.flyEnabled = true; store.flySpeed = speed; return 1.0, 0 end,
        flyDisable = function() store.flyEnabled = false end,
        setActorCollision = function(_p, on) store.collision = on end,
        setRunSpeed = function(v) store.runspeed = v; return true end,
        getRunSpeed = function() return store.runspeed end,
        persist = function(k, v) store["p_" .. k] = v end,
        persisted = function(k) return store["p_" .. k] end,
    }
end

local function specByName(name)
    for _, s in ipairs(movement.specs()) do if s.name == name then return s end end
end
local function run(eng, name, ...)
    local out = {}
    specByName(name).run({ ... }, { line = function(m) out[#out + 1] = m end }, eng)
    return table.concat(out, " | ")
end

T.add("project: forward input with yaw 0 moves +X", function()
    local mx, my, mz = movement._project(1, 0, 0, 0)
    T.ok(math.abs(mx - 1) < 1e-6, "mx ~ 1")
    T.ok(math.abs(my) < 1e-6, "my ~ 0")
    T.ok(math.abs(mz) < 1e-6, "mz ~ 0")
end)

T.add("project: looking up while moving forward climbs (mz > 0)", function()
    local _, _, mz = movement._project(1, 0, 0, 80) -- pitch 80 deg up
    T.ok(mz > 0.5, "climbs")
end)

T.add("fly on enables the pose; off restores", function()
    local eng = fakeEngine()
    run(eng, "fly", "on")
    T.eq(movement.isFlying(), true, "fly is on")
    T.eq(eng.store.flyEnabled, true, "engine.flyEnable called")
    run(eng, "fly", "off")
    T.eq(movement.isFlying(), false, "fly is off")
    T.eq(eng.store.flyEnabled, false, "engine.flyDisable called")
end)

T.add("fly on with a speed arg sets the speed", function()
    local eng = fakeEngine()
    run(eng, "fly", "on", "3000")
    T.eq(eng.store.flySpeed, 3000, "speed arg applied")
    run(eng, "fly", "off")
end)

T.add("holdTick runs upkeep each frame and moves the actor", function()
    local eng = fakeEngine()
    run(eng, "fly", "on")
    movement.holdTick(eng) -- first frame: inits pos + rise
    movement.holdTick(eng) -- second frame
    T.ok(eng.store.lastOffset ~= nil, "addActorWorldOffset was called")
    T.ok(eng.store.upkeep >= 2, "flyUpkeep ran each frame")
    run(eng, "fly", "off")
end)

T.add("noclip toggles collision", function()
    local eng = fakeEngine()
    run(eng, "noclip", "on")
    T.eq(eng.store.collision, false, "collision off")
    run(eng, "noclip", "off")
    T.eq(eng.store.collision, true, "collision restored")
end)

T.add("runspeed sets the multiplier and bare prints it", function()
    local eng = fakeEngine()
    run(eng, "runspeed", "2")
    T.eq(eng.store.runspeed, 2, "multiplier written")
    T.ok(run(eng, "runspeed"):find("2"), "bare runspeed prints the value")
end)

os.exit(T.run())
