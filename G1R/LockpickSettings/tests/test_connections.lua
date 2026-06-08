-- test_connections.lua  --  Connection Display feature: the partner tint map
-- is pure.
local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local connections = require("connections.connections")

local palette = { partnerSame = "SAME", partnerOpp = "OPP" }

T.add("maps the selected piece's out-edges to direction-coded colors", function()
    local s = { selectedRow = 0, edges = { [0] = { { b = 1, dir = 1 }, { b = 2, dir = -1 } } } }
    local t = connections.partnerTints(s, palette)
    T.eq(t[1], "SAME") -- dir 1 = travels WITH the selected piece -> purple
    T.eq(t[2], "OPP")  -- dir -1 = travels AGAINST it -> red
end)

T.add("empty when the selected piece has no out-edges", function()
    local s = { selectedRow = 5, edges = {} }
    local t = connections.partnerTints(s, palette)
    T.eq(next(t), nil)
end)

os.exit(T.run())
