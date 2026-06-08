-- tests for kit.num (pure)
-- run from this dir (tests/run.ps1 sets the cwd); the kit is two levels up
package.path = "../../?/?.lua;./?.lua;" .. package.path

local T = require("tinytest")
local kit = require("kit")

T.add("lookup tolerates float fuzz, misses return nil", function()
    T.eq(kit.num.lookup({ [2] = "a", [4] = "b" }, 2.0005), "a")
    T.eq(kit.num.lookup({ [2] = "a", [4] = "b" }, 4), "b")
    T.eq(kit.num.lookup({ [2] = "a" }, 5), nil)
end)

T.add("colorDist2 is the squared RGB distance (alpha ignored)", function()
    T.eq(kit.num.colorDist2({ R = 0, G = 0, B = 0 }, { R = 0, G = 0, B = 0 }), 0)
    T.eq(kit.num.colorDist2({ R = 1, G = 0, B = 0 }, { R = 0, G = 0, B = 0 }), 1)
    T.eq(kit.num.colorDist2({ R = 0, G = 3, B = 4 }, { R = 0, G = 0, B = 0 }), 25)
end)

os.exit(T.run())
