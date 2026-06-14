-- tests for viewmath  --  the menu's pure value, slider and hit-test math.
-- These are the parts that have actually broken in play (the [-]/bar click overlap, the bar fill,
-- the click-to-set clamping), so they get pinned here. viewmath names no engine globals, so it
-- loads straight under LuaJIT with no mocks.
package.path = "./?.lua;../Scripts/?.lua;" .. package.path

local T = require("tinytest")
local VM = require("viewmath")
local L = VM.L

local function num(v, min, max, step)
    return { kind = "num", value = v, min = min, max = max, step = step }
end

-- ------------------------------------------------------------ bar string --
T.add("barString is empty at min, full at max, half at midpoint", function()
    T.eq(VM.barString(num(0, 0, 100)), "|------------|")            -- 12 cells, none filled
    T.eq(VM.barString(num(100, 0, 100)), "|############|")          -- all filled
    T.eq(VM.barString(num(50, 0, 100)), "|######------|")           -- 6 of 12
end)

T.add("barString clamps out-of-range values instead of overflowing", function()
    T.eq(VM.barString(num(-20, 0, 100)), "|------------|")
    T.eq(VM.barString(num(999, 0, 100)), "|############|")
end)

T.add("barString tolerates a degenerate range (min == max)", function()
    T.eq(VM.barString(num(5, 5, 5)), "|------------|")
end)

-- ----------------------------------------------------------- value text --
T.add("valText renders each kind", function()
    T.eq(VM.valText({ kind = "bool", value = true }), "[ ON ]")
    T.eq(VM.valText({ kind = "bool", value = false }), "[ OFF ]")
    T.eq(VM.valText({ kind = "action" }), "[ RUN ]")
    T.eq(VM.valText({ kind = "num", value = 42 }), "42")
end)

-- --------------------------------------------------------- wrap-around nav --
T.add("clampWrap cycles past either end", function()
    T.eq(VM.clampWrap(2, 1, 3), 2)   -- in range, unchanged
    T.eq(VM.clampWrap(4, 1, 3), 1)   -- past the end wraps to start
    T.eq(VM.clampWrap(0, 1, 3), 3)   -- before the start wraps to end
end)

-- ------------------------------------------------------------ step value --
T.add("stepValue steps by step and clamps to bounds", function()
    T.eq(VM.stepValue(num(10, 0, 100, 5), 1), 15)
    T.eq(VM.stepValue(num(10, 0, 100, 5), -1), 5)
    T.eq(VM.stepValue(num(98, 0, 100, 5), 1), 100, "clamps at max")
    T.eq(VM.stepValue(num(2, 0, 100, 5), -1), 0, "clamps at min")
    T.eq(VM.stepValue(num(10, 0, 100), 1), 11, "defaults step to 1")
end)

-- ----------------------------------------------------- click-to-set on bar --
T.add("valueFromBar maps the bar edges to min and max", function()
    local it = num(0, 0, 100)
    T.eq(VM.valueFromBar(it, L.barX), 0, "left edge is min")
    T.eq(VM.valueFromBar(it, L.barX + L.barW), 100, "right edge is max")
    T.eq(VM.valueFromBar(it, L.barX + L.barW / 2), 50, "midpoint is the middle")
end)

T.add("valueFromBar clamps clicks outside the bar", function()
    local it = num(0, 0, 100)
    T.eq(VM.valueFromBar(it, L.barX - 40), 0, "left of the bar pins to min")
    T.eq(VM.valueFromBar(it, L.barX + L.barW + 40), 100, "right of the bar pins to max")
end)

T.add("valueFromBar snaps to step", function()
    local it = num(0, 0, 10, 1)
    -- a click ~37% along a 0..10 range is 3.7, which snaps to 4
    T.eq(VM.valueFromBar(it, L.barX + L.barW * 0.37), 4)
end)

-- ------------------------------------------------------------- hit zones --
-- the shape a real frame would pass: two num rows starting at rowTop
local function view()
    return {
        tabCount = 2, subCount = 2, showSub = true,
        rowTop = L.subTabY + L.tabH + 6,
        items = {
            num(50, 0, 100, 5),
            { kind = "bool", value = true },
        },
    }
end
local function rowY(i, v) return v.rowTop + (i - 1) * L.rowH + 4 end -- a few px into row i

T.add("clicking the [X] button hits close", function()
    local z = VM.hitZone(L.closeX + 4, L.closeY + 4, view())
    T.eq(z.zone, "close")
end)

T.add("clicking a mod tab and a sub tab resolves to its index", function()
    local v = view()
    T.eq(VM.hitZone(L.tabX0 + 4, L.modTabY + 4, v).zone, "modtab")
    T.eq(VM.hitZone(L.tabX0 + L.tabStep + 4, L.modTabY + 4, v).index, 2, "second mod tab")
    T.eq(VM.hitZone(L.tabX0 + 4, L.subTabY + 4, v).zone, "subtab")
    T.eq(VM.hitZone(L.tabX0 + L.tabStep + 4, L.subTabY + 4, v).index, 2, "second sub tab")
end)

T.add("a num row resolves [-], the bar, [+], and a bare select by column", function()
    local v = view()
    local y = rowY(1, v)
    T.eq(VM.hitZone(L.decX + 2, y, v).part, "dec", "[-] column")
    T.eq(VM.hitZone(L.incX + 2, y, v).part, "inc", "[+] column")
    T.eq(VM.hitZone(L.barX + 4, y, v).part, "bar", "bar interior")
    T.eq(VM.hitZone(L.nameX + 2, y, v).part, "select", "name column just selects")
    T.eq(VM.hitZone(L.barX + 4, y, v).index, 1, "row index")
end)

-- the regression that bit us: the [-] zone must not bleed onto the bar, or a click on the bar's
-- left edge would step down by one instead of setting the value where you clicked.
T.add("the [-] zone and the bar zone do not overlap", function()
    local v = view()
    local y = rowY(1, v)
    T.eq(VM.hitZone(L.barX, y, v).part, "bar", "the bar's first pixel is bar, not dec")
    T.lt(L.decX + L.colW, L.barX, "[-] right edge sits left of the bar's left edge")
    T.lt(L.barX + L.barW, L.incX - 6, "bar right edge sits left of the [+] hit zone")
end)

T.add("a bool row resolves its toggle zone", function()
    local v = view()
    local z = VM.hitZone(L.decX + 4, rowY(2, v), v)
    T.eq(z.zone, "item")
    T.eq(z.index, 2)
    T.eq(z.part, "toggle")
end)

T.add("clicks off the panel and below the last row miss", function()
    local v = view()
    T.eq(VM.hitZone(L.panelX - 20, rowY(1, v), v), nil, "left of the panel")
    T.eq(VM.hitZone(L.nameX, v.rowTop + 5 * L.rowH, v), nil, "below the last row")
end)

os.exit(T.run())
