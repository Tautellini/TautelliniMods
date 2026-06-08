-- test_boost.lua  --  boost.BASE_TRIES + boost.tierTables are pure (no engine),
-- so they test directly under bare LuaJIT. The vanilla bases moved out of the
-- user config into boost.lua (game constants); this pins them and the math.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local boost = require("tries.boost")

T.add("BASE_TRIES are the vanilla per-tier durability values", function()
    T.eq(boost.BASE_TRIES.untrained, 2)
    T.eq(boost.BASE_TRIES.trained, 4)
    T.eq(boost.BASE_TRIES.master, 6)
end)

T.add("tierTables maps each base to base+extra and the boosted target back", function()
    local tiers, targets = boost.tierTables(10)
    T.eq(tiers[2].name, "untrained"); T.eq(tiers[2].target, 12)
    T.eq(tiers[4].name, "trained"); T.eq(tiers[4].target, 14)
    T.eq(tiers[6].name, "master"); T.eq(tiers[6].target, 16)
    T.eq(targets[12], "untrained")
    T.eq(targets[14], "trained")
    T.eq(targets[16], "master")
end)

T.add("a sane extra keeps boosted targets clear of the vanilla bases", function()
    local _, targets = boost.tierTables(10)
    for target in pairs(targets) do
        T.ok(target ~= 2 and target ~= 4 and target ~= 6,
            "boosted target collides with a vanilla base: " .. target)
    end
end)

os.exit(T.run())
