-- test_registry.lua  --  the registry is pure: it stores specs, applies the
-- prefix to full names, and formats sorted help lines.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local registry = require("core.registry")

local function noop() end

T.add("an empty prefix leaves command names plain", function()
    local r = registry.new("")
    r:add({ name = "god", help = "invuln", run = noop })
    T.eq(r:fullName(r:all()[1]), "god")
end)

T.add("a prefix is prepended to the full name", function()
    local r = registry.new("tc_")
    r:add({ name = "god", help = "invuln", run = noop })
    T.eq(r:fullName(r:all()[1]), "tc_god")
end)

T.add("addAll appends a list and all() returns them in order", function()
    local r = registry.new("")
    r:addAll({
        { name = "a", help = "first", run = noop },
        { name = "b", help = "second", run = noop },
    })
    T.eq(#r:all(), 2)
    T.eq(r:all()[1].name, "a")
    T.eq(r:all()[2].name, "b")
end)

T.add("helpLines are prefixed and sorted", function()
    local r = registry.new("tc_")
    r:addAll({
        { name = "time", help = "set clock", run = noop },
        { name = "god", help = "invuln", run = noop },
    })
    local lines = r:helpLines()
    T.eq(#lines, 2)
    -- sorted: "tc_god ..." comes before "tc_time ..."
    T.eq(lines[1], "tc_god  -  invuln")
    T.eq(lines[2], "tc_time  -  set clock")
end)

os.exit(T.run())
