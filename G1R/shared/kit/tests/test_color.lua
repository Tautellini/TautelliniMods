-- tests for kit.color (pure)
-- run from this dir (tests/run.ps1 sets the cwd); the kit is two levels up
package.path = "../../?/?.lua;./?.lua;" .. package.path

local T = require("tinytest")
local kit = require("kit")

T.add("colorFrom validates a {r,g,b} triple into {R,G,B,A=1}", function()
    local c = kit.color.colorFrom({ 0.1, 0.2, 0.3 }, nil)
    T.eq(c.R, 0.1); T.eq(c.G, 0.2); T.eq(c.B, 0.3); T.eq(c.A, 1.0)
end)

T.add("colorFrom falls back when missing or malformed", function()
    local fb = { R = 9 }
    T.eq(kit.color.colorFrom(nil, fb), fb)
    T.eq(kit.color.colorFrom({ 1, 2 }, fb), fb)
    T.eq(kit.color.colorFrom("nope", fb), fb)
end)

os.exit(T.run())
