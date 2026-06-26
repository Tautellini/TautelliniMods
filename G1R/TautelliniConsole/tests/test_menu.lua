-- test_menu.lua  --  the SharedModMenu builders. Each CONTRIBUTING cheat module's
-- menu(engine) must return a well-formed section (the SharedModMenu item spec:
-- bool/num/action with get/set), and core.menu.build must aggregate them, skip
-- non-contributors (movement, whose tab is hidden) and skip errors. We drive the
-- real builders with a fake engine, so no UE4SS is needed.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local resources = require("cheats.resources")
local stats     = require("cheats.stats")
local timeCmd   = require("cheats.time")
local worldCmd  = require("cheats.world")
local movement  = require("cheats.movement")
local lockpicking = require("cheats.lockpicking")
local coreMenu  = require("core.menu")

-- a fake engine covering the seams the menu get/set closures touch. It stores
-- attribute writes and the clock so round-trips are observable.
local function fakeEngine()
    local store = {}
    local scratch = {}
    local clock = { hour = 9, minute = 0 }
    local fakeSet = { tag = "set" }
    return {
        store = store, clock = clock,
        findPlayerAttrSet = function(_n) return fakeSet end,
        readAttr = function(_s, attr) return store[attr] end,
        writeAttr = function(_s, attr, _b, current) store[attr] = current; return true end,
        persist = function(k, v) scratch[k] = v end,
        persisted = function(k) return scratch[k] end,
        healFull = function() store.healed = true; return true end,
        setCombatFlag = function(field, value) store[field] = value; return true end,
        incStatViaMixin = function(inc, delta) store[inc] = (store[inc] or 0) + delta; return true end,
        addItem = function(id, count) store.lastItem = id; store.lastCount = count; return true, id end,
        setWeather = function(id) store.weather = id; return true end,
        freezeTime = function(w) store.frozen = w; return true end,
        setTimeDilation = function(v) store.dilation = v; return true end,
        setRunSpeed = function(v) store.runspeed = v; return true end,
        getRunSpeed = function() return store.runspeed or 1 end,
        readClock = function() return { hour = clock.hour, minute = clock.minute } end,
        setClock = function(h, m) clock.hour, clock.minute = h, m; return true end,
        grantSkill = function(name) store.grantedSkill = name; return true, name end,
        removeSkill = function(name) store.removedSkill = name; return true, name end,
    }
end

local KINDS = { bool = true, num = true, action = true }

local function assertItem(it, where)
    T.ok(type(it.name) == "string" and it.name ~= "", where .. ": name")
    T.ok(KINDS[it.kind], where .. ": kind '" .. tostring(it.kind) .. "' must be bool|num|action")
    if it.kind == "action" then
        T.ok(type(it.set) == "function", where .. ": action needs set")
    else
        T.ok(type(it.get) == "function", where .. ": " .. it.kind .. " needs get")
        T.ok(type(it.set) == "function", where .. ": " .. it.kind .. " needs set")
    end
    if it.kind == "num" then
        for _, f in ipairs({ "min", "max", "step" }) do
            T.ok(type(it[f]) == "number", where .. ": num needs numeric " .. f)
        end
        T.ok(it.max > it.min, where .. ": num max > min")
    end
end

local function assertSection(sec, where)
    T.ok(type(sec) == "table", where .. ": section is a table")
    T.ok(type(sec.title) == "string" and sec.title ~= "", where .. ": title")
    T.ok(type(sec.items) == "table" and #sec.items > 0, where .. ": non-empty items")
    for i, it in ipairs(sec.items) do assertItem(it, where .. ".items[" .. i .. "]") end
end

T.add("every contributing module's menu() is a well-formed section", function()
    local eng = fakeEngine()
    for _, m in ipairs({
        { "resources", resources }, { "stats", stats }, { "movement", movement },
        { "time", timeCmd }, { "world", worldCmd }, { "lockpicking", lockpicking },
    }) do
        assertSection(m[2].menu(eng), m[1])
    end
end)

T.add("lockpicking section offers Untrained / Skilled / Master buttons", function()
    local sec = lockpicking.menu(fakeEngine())
    T.eq(sec.title, "Lockpicking")
    T.eq(#sec.items, 3, "exactly three tier buttons")
    local names = {}
    for _, it in ipairs(sec.items) do
        T.eq(it.kind, "action", it.name .. " is a button")
        names[it.name] = true
    end
    T.ok(names["Untrained"] and names["Skilled"] and names["Master"], "all three tiers present")
end)

T.add("a lockpicking button grants that tier's skill", function()
    local eng = fakeEngine()
    local master
    for _, it in ipairs(lockpicking.menu(eng).items) do
        if it.name == "Master" then master = it end
    end
    T.ok(master ~= nil, "a Master button exists")
    master.set(true)
    T.eq(eng.store.grantedSkill, "Picklock_Master", "pressing Master grants the Master skill")
end)

T.add("movement contributes a Movement section with a Run Speed slider", function()
    local sec = movement.menu(fakeEngine())
    T.eq(sec.title, "Movement")
    local hasSpeed = false
    for _, it in ipairs(sec.items) do if it.name == "Run Speed" and it.kind == "num" then hasSpeed = true end end
    T.ok(hasSpeed, "a Run Speed num item exists")
end)

T.add("stats num get/set round-trips through the engine", function()
    local eng = fakeEngine()
    local sec = stats.menu(eng)
    local str
    for _, it in ipairs(sec.items) do if it.name == "Strength" then str = it end end
    T.ok(str ~= nil, "a Strength num item exists")
    T.eq(str.get(), 0, "no stored value reads as 0")
    str.set(42)
    T.eq(eng.store.Strength, 42, "set writes the attribute")
    T.eq(str.get(), 42, "get reflects the write")
end)

T.add("stats has no Move Speed row (it belongs under Movement once it works)", function()
    local eng = fakeEngine()
    for _, it in ipairs(stats.menu(eng).items) do
        T.ok(it.name ~= "Move Speed", "Move Speed must not appear in Stats")
    end
end)

T.add("xp is console-only: no XP row in the Stats menu", function()
    local eng = fakeEngine()
    for _, it in ipairs(stats.menu(eng).items) do
        T.ok(not it.name:find("XP", 1, true), "no XP item in the Stats menu")
    end
end)

T.add("god bool get reflects the toggle", function()
    local eng = fakeEngine()
    local sec = resources.menu(eng)
    local god = sec.items[1]
    T.eq(god.name, "God Mode")
    T.eq(god.kind, "bool")
    god.set(true)
    T.eq(god.get(), true, "get is true after set(true)")
    god.set(false)
    T.eq(god.get(), false, "get is false after set(false)")
end)

T.add("time section is titled Time, with a slider and three preset buttons", function()
    local eng = fakeEngine()
    local sec = timeCmd.menu(eng)
    T.eq(sec.title, "Time")
    T.eq(sec.items[1].kind, "num", "first item is the hour slider")
    T.eq(sec.items[1].get(), 9, "reads the fake clock hour")
    local actions = 0
    for _, it in ipairs(sec.items) do if it.kind == "action" then actions = actions + 1 end end
    T.eq(actions, 3, "three preset buttons (8/12/20)")
end)

T.add("time slider clamps + rounds and a preset button jumps the clock", function()
    local eng = fakeEngine()
    local sec = timeCmd.menu(eng)
    local hour = sec.items[1]
    hour.set(13.4)
    T.eq(eng.clock.hour, 13, "slider rounds to the hour")
    hour.set(99)
    T.eq(eng.clock.hour, 23, "slider clamps above 23")
    local btn
    for _, it in ipairs(sec.items) do if it.name == "Set 20:00" then btn = it end end
    T.ok(btn ~= nil, "a Set 20:00 button exists")
    btn.set(true)
    T.eq(eng.clock.hour, 20, "the preset button sets the hour")
end)

T.add("core.menu.build aggregates contributors, skips non-menu + erroring modules", function()
    local eng = fakeEngine()
    local nomenu = {} -- a module with no menu() (like items/skills)
    local boom = { menu = function() error("boom") end }
    local sections = coreMenu.build(eng, resources, stats, timeCmd, nomenu, boom)
    T.eq(#sections, 3, "resources + stats + time; nomenu and boom dropped")
    T.eq(sections[1].title, "Player")
    T.eq(sections[2].title, "Stats")
    T.eq(sections[3].title, "Time")
end)

T.add("build tolerates a nil module without truncating later ones", function()
    local eng = fakeEngine()
    local sections = coreMenu.build(eng, resources, nil, stats, timeCmd)
    T.eq(#sections, 3, "resources + stats + time survive the nil hole")
    T.eq(sections[3].title, "Time")
end)

os.exit(T.run())
