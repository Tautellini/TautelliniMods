-- test_lockpicking.lua  --  the lockskill command logic: tier resolution (names,
-- the "trained" alias, numbers), the clear-then-grant exclusivity, the read-back
-- status line, and the grant-failure path. Pure once the engine is injected, so we
-- drive the real spec closure with a fake engine recording grant/remove calls.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local lockpicking = require("cheats.lockpicking")

-- fake engine: records removed/granted skill names and serves a precision that a
-- successful grant updates to that tier's value, so the read-back is observable.
local function fakeEngine(opts)
    opts = opts or {}
    local e = {
        removed = {}, granted = {},
        precision = opts.precision,
        hasSet = opts.hasSet ~= false,
        grantOk = opts.grantOk ~= false,
    }
    e.findPlayerAttrSet = function(_n) return e.hasSet and { tag = "lock" } or nil end
    e.readAttr = function(_s, _a) return e.precision end
    e.removeSkill = function(name) e.removed[#e.removed + 1] = name; return true, name end
    e.grantSkill = function(name)
        e.granted[#e.granted + 1] = name
        if not e.grantOk then return false, "no player state" end
        local v = ({ Picklock_Untrained = 0, Picklock_Skilled = 1, Picklock_Master = 2 })[name]
        if v ~= nil then e.precision = v end
        return true, "GE_Skill_" .. name
    end
    return e
end

local function fakeOut()
    local o = { lines = {} }
    o.line = function(m) o.lines[#o.lines + 1] = m end
    return o
end
local function lastLine(o) return o.lines[#o.lines] end

local function spec()
    for _, s in ipairs(lockpicking.specs()) do
        if s.name == "lockskill" then return s end
    end
    error("no lockskill spec")
end

local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

T.add("master grants the Master skill and reports the new precision", function()
    local eng = fakeEngine({ precision = 0 })
    local out = fakeOut()
    spec().run({ "master" }, out, eng)
    T.eq(contains(eng.granted, "Picklock_Master"), true, "Master skill granted")
    T.ok(lastLine(out):find("Master", 1, true), "status names the tier")
    T.ok(lastLine(out):find("0 %-> 2"), "status shows precision 0 -> 2")
end)

T.add("setting a tier clears all three tiers first (exclusivity)", function()
    local eng = fakeEngine({ precision = 2 })
    spec().run({ "untrained" }, fakeOut(), eng)
    T.eq(#eng.removed, 3, "all three picklock tiers removed before granting")
    T.ok(contains(eng.removed, "Picklock_Untrained"), "removes Untrained")
    T.ok(contains(eng.removed, "Picklock_Skilled"), "removes Skilled")
    T.ok(contains(eng.removed, "Picklock_Master"), "removes Master")
    T.ok(contains(eng.granted, "Picklock_Untrained"), "then grants Untrained")
end)

T.add("'trained' is an alias for the Skilled tier", function()
    local eng = fakeEngine({ precision = 0 })
    spec().run({ "trained" }, fakeOut(), eng)
    T.eq(eng.granted[#eng.granted], "Picklock_Skilled", "trained -> Skilled")
end)

T.add("a numeric token maps to the matching tier", function()
    local eng = fakeEngine({ precision = 0 })
    spec().run({ "2" }, fakeOut(), eng)
    T.eq(eng.granted[#eng.granted], "Picklock_Master", "2 -> Master")
end)

T.add("a bad tier token prints usage and grants nothing", function()
    local eng = fakeEngine({ precision = 0 })
    local out = fakeOut()
    spec().run({ "wizard" }, out, eng)
    T.eq(#eng.granted, 0, "no skill granted on a bad token")
    T.ok(lastLine(out):find("usage", 1, true), "prints usage")
end)

T.add("bare lockskill prints the current tier and grants nothing", function()
    local eng = fakeEngine({ precision = 1 })
    local out = fakeOut()
    spec().run({}, out, eng)
    T.eq(#eng.granted, 0, "a bare read must not grant")
    T.ok(lastLine(out):find("Skilled", 1, true), "names the current tier")
end)

T.add("not in-game: bare lockskill explains there is no player set", function()
    local eng = fakeEngine({ hasSet = false })
    local out = fakeOut()
    spec().run({}, out, eng)
    T.ok(lastLine(out):find("be in-game", 1, true), "asks the player to be in-game")
end)

T.add("a failed grant is reported, not claimed as success", function()
    local eng = fakeEngine({ precision = 0, grantOk = false })
    local out = fakeOut()
    spec().run({ "master" }, out, eng)
    T.ok(lastLine(out):find("could not grant", 1, true), "reports the failure")
end)

os.exit(T.run())
