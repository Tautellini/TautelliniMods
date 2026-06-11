-- test_atmosphere.lua  --  data.atmosphere is a pure catalog + selection helper,
-- so it tests directly under bare LuaJIT. Pins the catalog shape and that select
-- returns the chosen keys IN CATALOG ORDER, skipping unknown keys.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local atmosphere = require("data.atmosphere")

T.add("the catalog is non-empty and well-formed", function()
    T.ok(#atmosphere.list > 0, "catalog should not be empty")
    for _, e in ipairs(atmosphere.list) do
        T.eq(type(e.key), "string", "key is a string")
        T.eq(type(e.prop), "string", "prop is a string")
        T.eq(type(e.label), "string", "label is a string")
        T.eq(type(e.min), "number", "min is a number")
        T.eq(type(e.max), "number", "max is a number")
        T.lt(e.min, e.max, "min < max for " .. e.key)
    end
end)

T.add("byKey indexes every catalog entry", function()
    for _, e in ipairs(atmosphere.list) do
        T.eq(atmosphere.byKey[e.key], e, "byKey for " .. e.key)
    end
end)

T.add("cloud carries the confirmed Intended lerp-target property", function()
    T.eq(atmosphere.byKey.cloud.prop, "Cloud Coverage")
    T.eq(atmosphere.byKey.cloud.intended, "Intended Cloud Coverage")
end)

T.add("select returns chosen keys in catalog order, skipping unknown ones", function()
    local sel = atmosphere.select({ "wind", "cloud", "bogus" })
    T.eq(#sel, 2, "two known keys")
    T.eq(sel[1].key, "cloud", "cloud comes first (catalog order, not input order)")
    T.eq(sel[2].key, "wind")
end)

T.add("select(nil) is an empty selection", function()
    T.eq(#atmosphere.select(nil), 0)
end)

os.exit(T.run())
