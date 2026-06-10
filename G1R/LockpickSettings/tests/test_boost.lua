-- test_boost.lua  --  boost.BASE_TRIES, boost.perTier and boost.plan are pure
-- (no engine), so they test directly under bare LuaJIT. The vanilla bases moved
-- out of the user config into boost.lua (game constants); this pins them and the
-- per-tier math. extraTries is a per-tier table ONLY (the single-number form was
-- dropped). The plan must NEVER produce an ambiguous boost (one whose total could
-- be misread as another tier and stacked).

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

T.add("a non-table extra boosts nothing (the single-number form was dropped)", function()
    local pt = boost.perTier(10)
    T.eq(pt.untrained, 0); T.eq(pt.trained, 0); T.eq(pt.master, 0)
    local pt2 = boost.perTier(nil)
    T.eq(pt2.untrained, 0); T.eq(pt2.trained, 0); T.eq(pt2.master, 0)
end)

T.add("a per-tier table gives a bonus per tier; missing or <=0 means none", function()
    local pt = boost.perTier({ untrained = 10, trained = 20 }) -- master omitted
    T.eq(pt.untrained, 10); T.eq(pt.trained, 20); T.eq(pt.master, 0)
    local pt2 = boost.perTier({ untrained = -5, trained = 0, master = 30 })
    T.eq(pt2.untrained, 0); T.eq(pt2.trained, 0); T.eq(pt2.master, 30)
end)

T.add("plan maps each base to its boosted total and back", function()
    local p = boost.plan({ untrained = 10, trained = 20, master = 30 })
    T.eq(p.boostable[2].name, "untrained"); T.eq(p.boostable[2].target, 12)
    T.eq(p.boostable[4].name, "trained");   T.eq(p.boostable[4].target, 24)
    T.eq(p.boostable[6].name, "master");    T.eq(p.boostable[6].target, 36)
    T.eq(p.targets[12], "untrained")
    T.eq(p.targets[24], "trained")
    T.eq(p.targets[36], "master")
    T.eq(p.effective.untrained, 12)
    T.eq(p.effective.trained, 24)
    T.eq(p.effective.master, 36)
    T.eq(#p.skipped, 0)
end)

T.add("plan never produces a total that collides with a vanilla base", function()
    local p = boost.plan({ untrained = 5, trained = 10, master = 20 })
    for total in pairs(p.targets) do
        T.ok(total ~= 2 and total ~= 4 and total ~= 6,
            "boosted total collides with a vanilla base: " .. total)
    end
end)

T.add("a tier whose total hits another tier's vanilla base is skipped", function()
    -- untrained 2 + 2 = 4 == trained's vanilla base: ambiguous, must be skipped
    local p = boost.plan({ untrained = 2, trained = 20, master = 30 })
    T.eq(p.boostable[2], nil, "untrained must not be boostable")
    T.eq(p.targets[4], nil, "4 must not be a recognized boosted total")
    T.eq(p.effective.untrained, 2, "skipped tier stays at its vanilla base")
    T.eq(p.boostable[4].target, 24, "trained still boosts")
    T.eq(p.boostable[6].target, 36, "master still boosts")
    local found = false
    for _, n in ipairs(p.skipped) do if n == "untrained" then found = true end end
    T.ok(found, "untrained should be reported as skipped")
end)

T.add("two tiers boosting to the same total are both skipped", function()
    -- untrained 2 + 10 = 12 and trained 4 + 8 = 12: collide, both skipped
    local p = boost.plan({ untrained = 10, trained = 8, master = 30 })
    T.eq(p.boostable[2], nil)
    T.eq(p.boostable[4], nil)
    T.eq(p.targets[12], nil)
    T.eq(p.effective.untrained, 2)
    T.eq(p.effective.trained, 4)
    T.eq(p.boostable[6].target, 36, "master is unaffected")
    T.eq(#p.skipped, 2)
end)

T.add("a zero/omitted tier stays vanilla but is still a known tier", function()
    local p = boost.plan({ untrained = 0, trained = 20, master = 30 })
    T.eq(p.boostable[2], nil)
    T.eq(p.effective.untrained, 2)
    T.eq(p.bases[2], "untrained", "an unboosted tier is still recognized")
end)

os.exit(T.run())
