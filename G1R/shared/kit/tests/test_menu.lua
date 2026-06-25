-- tests for kit.menu (the cross-mod menu bridge over UE4SS shared variables)
package.path = "../../?/?.lua;./?.lua;" .. package.path

local T = require("tinytest")

-- mock the UE4SS shared-variable store (the only cross-mod channel)
local store = {}
_G.ModRef = {
    SetSharedVariable = function(_, k, v) store[k] = v end,
    GetSharedVariable = function(_, k) return store[k] end,
}
local kit = require("kit")
local M = kit.menu

local function tab(name)
    for _, m in ipairs(M.readAll()) do if m.name == name then return m end end
end

T.add("available() reflects ModRef presence", function()
    T.ok(M.available(), "ModRef is mocked")
end)

T.add("a flat item list registers as one untitled section", function()
    local cfg = { on = false }
    M.register("Flat", { { name = "On", kind = "bool", get = function() return cfg.on end, set = function(v) cfg.on = v end } })
    local m = tab("Flat")
    T.ok(m ~= nil, "Flat present")
    T.eq(#m.sections, 1)
    T.eq(m.sections[1].title, nil)
    T.eq(m.sections[1].items[1].name, "On")
    T.eq(m.sections[1].items[1].flat, 1)
    T.eq(m.sections[1].items[1].value, false)
end)

T.add("sections are published, read back with titles + flat indices + values", function()
    local cfg = { speed = 1000, tries = 5 }
    M.register("Sectioned", {
        { title = "Auto", items = {
            { name = "Speed", kind = "num", min = 0, max = 2000, step = 10, get = function() return cfg.speed end, set = function(v) cfg.speed = v end },
        } },
        { title = "Durability", items = {
            { name = "Tries", kind = "num", min = 0, max = 30, step = 1, get = function() return cfg.tries end, set = function(v) cfg.tries = v end },
        } },
    })
    local m = tab("Sectioned")
    T.eq(#m.sections, 2)
    T.eq(m.sections[1].title, "Auto")
    T.eq(m.sections[2].title, "Durability")
    T.eq(m.sections[1].items[1].flat, 1)
    T.eq(m.sections[1].items[1].value, 1000)
    T.eq(m.sections[1].items[1].min, 0)
    T.eq(m.sections[1].items[1].max, 2000)
    T.eq(m.sections[2].items[1].flat, 2) -- flat index spans sections
    T.eq(m.sections[2].items[1].value, 5)
end)

T.add("an item description round-trips and omits cleanly when absent", function()
    M.register("Described", {
        { name = "A", kind = "bool", desc = "explain A", get = function() return true end },
        { name = "B", kind = "bool", get = function() return false end },
    })
    local m = tab("Described")
    T.eq(m.sections[1].items[1].desc, "explain A", "desc survives the wire")
    T.eq(m.sections[1].items[2].desc, nil, "no desc reads back as nil")
end)

T.add("a description is stripped of the GS/RS/FS framing bytes", function()
    M.register("Dirty", {
        { name = "A", kind = "bool", desc = "a\31b\30c\29d", get = function() return true end },
    })
    T.eq(tab("Dirty").sections[1].items[1].desc, "abcd", "control bytes removed so the record can't corrupt")
end)

T.add("sendEdit by flat index + pump applies through the local set()", function()
    local cfg = { speed = 1000, tries = 5, fired = false }
    M.register("Edits", {
        { title = "Auto", items = {
            { name = "Speed", kind = "num", min = 0, max = 2000, step = 10, get = function() return cfg.speed end, set = function(v) cfg.speed = v end },
            { name = "Reset", kind = "action", set = function() cfg.fired = true end },
        } },
        { title = "Durability", items = {
            { name = "Tries", kind = "num", min = 0, max = 30, step = 1, get = function() return cfg.tries end, set = function(v) cfg.tries = v end },
        } },
    })
    M.sendEdit("Edits", 1, "num", 600)    -- Speed
    M.sendEdit("Edits", 2, "action", true) -- Reset
    M.sendEdit("Edits", 3, "num", 12)      -- Tries (section 2)
    T.eq(cfg.speed, 1000) -- not applied until pump
    M.pump()
    T.eq(cfg.speed, 600)
    T.ok(cfg.fired, "action fired")
    T.eq(cfg.tries, 12)
    T.eq(tab("Edits").sections[2].items[1].value, 12) -- republished
end)

T.add("register is a safe no-op without the shared store", function()
    local saved = _G.ModRef
    _G.ModRef = nil
    M.register("NoStore", { { name = "X", kind = "bool", get = function() return true end } })
    M.pump()
    T.ok(not M.available(), "no ModRef -> unavailable")
    _G.ModRef = saved
end)

os.exit(T.run())
