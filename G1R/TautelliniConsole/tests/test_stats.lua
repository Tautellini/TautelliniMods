-- test_stats.lua  --  the stat command logic (add/remove/set/print, the
-- additive-vs-absolute rule, the clamp-at-zero) is pure once the engine is
-- injected. We drive the real spec closures with a fake engine + out sink, so no
-- UE4SS runtime is needed.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local stats = require("cheats.stats")

-- a fake engine holding one attribute value, ignoring the set/attr names
local function fakeEngine(initial)
    local store = { value = initial }
    return {
        store = store,
        findPlayerAttrSet = function(_name) return { tag = "fake" } end,
        readAttr = function(_set, _attr) return store.value end,
        writeAttr = function(_set, _attr, _base, current)
            store.value = current
            return true
        end,
    }
end

local function fakeOut()
    local o = { lines = {} }
    o.line = function(m) o.lines[#o.lines + 1] = m end
    return o
end

local function specByName(name)
    for _, s in ipairs(stats.specs()) do
        if s.name == name then return s end
    end
    error("no stat spec named " .. name)
end

local function lastLine(o) return o.lines[#o.lines] end

T.add("bare stat prints the current value", function()
    local eng = fakeEngine(10)
    local out = fakeOut()
    specByName("str").run({}, out, eng)
    T.eq(lastLine(out), "str = 10")
    T.eq(eng.store.value, 10, "print must not change the value")
end)

T.add("add increments the value", function()
    local eng = fakeEngine(10)
    local out = fakeOut()
    specByName("str").run({ "add", "5" }, out, eng)
    T.eq(eng.store.value, 15)
    T.eq(lastLine(out), "str: 10 -> 15")
end)

T.add("remove decrements and clamps at zero", function()
    local eng = fakeEngine(10)
    local out = fakeOut()
    specByName("str").run({ "remove", "100" }, out, eng)
    T.eq(eng.store.value, 0)
    T.eq(lastLine(out), "str: 10 -> 0")
end)

T.add("set writes an absolute value where allowed", function()
    local eng = fakeEngine(10)
    local out = fakeOut()
    specByName("str").run({ "set", "50" }, out, eng)
    T.eq(eng.store.value, 50)
    T.eq(lastLine(out), "str: 10 -> 50")
end)

T.add("xp has no set (additive only) and refuses it", function()
    local eng = fakeEngine(10)
    local out = fakeOut()
    specByName("xp").run({ "set", "5" }, out, eng)
    T.eq(eng.store.value, 10, "a refused set must not change the value")
    T.ok(lastLine(out):find("no 'set'", 1, true), "should explain there is no set")
end)

T.add("xp add still works", function()
    local eng = fakeEngine(10)
    local out = fakeOut()
    specByName("xp").run({ "add", "500" }, out, eng)
    T.eq(eng.store.value, 510)
    T.eq(lastLine(out), "xp: 10 -> 510")
end)

T.add("a bad number prints usage and does not write", function()
    local eng = fakeEngine(10)
    local out = fakeOut()
    specByName("str").run({ "add", "lots" }, out, eng)
    T.eq(eng.store.value, 10)
    T.ok(lastLine(out):find("usage", 1, true), "should print usage")
end)

os.exit(T.run())
