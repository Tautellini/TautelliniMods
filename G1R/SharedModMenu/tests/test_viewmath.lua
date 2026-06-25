-- tests for viewmath  --  the menu's pure value, slider, layout and hit-test math.
-- These are the parts that have actually broken in play (the [-]/bar click overlap, the bar fill,
-- the click-to-set clamping, tab overflow/overlap, the 1200x800 bounds and item paging) plus the
-- computed item columns (name width, description growth) that drive the draw AND the hit-test, so
-- the two can never drift. viewmath names no engine globals, so it loads straight under Lua 5.4.
package.path = "./?.lua;../Scripts/?.lua;" .. package.path

local T = require("tinytest")
local VM = require("viewmath")
local L = VM.L

local function num(v, min, max, step)
    return { kind = "num", value = v, min = min, max = max, step = step }
end
local function named(name, v, min, max, step)
    return { kind = "num", name = name, value = v, min = min, max = max, step = step }
end
local function names(prefix, n) local t = {} for i = 1, n do t[i] = prefix .. " " .. i end return t end

-- a view with `mods` mod tabs, `subs` sub tabs (0 = none), and the given item list
local function view(mods, subs, items)
    local showSub = subs > 0
    local lay = VM.layout({ modNames = names("Mod", mods), subNames = showSub and names("Sub", subs) or {},
                            showSub = showSub, items = items })
    return { tabCount = mods, subCount = subs, showSub = showSub, items = items, lay = lay }
end
local function defView() return view(2, 2, { num(50, 0, 100, 5), { kind = "bool", value = true } }) end
local function rowY(i, v) return v.lay.rowTop + (i - 1) * L.rowH + 4 end -- a few px into row i

-- ------------------------------------------------------------ bar fill --
T.add("barFrac is 0 at min, 1 at max, half at the midpoint, clamped out of range", function()
    T.eq(VM.barFrac(num(0, 0, 100)), 0)
    T.eq(VM.barFrac(num(100, 0, 100)), 1)
    T.eq(VM.barFrac(num(50, 0, 100)), 0.5)
    T.eq(VM.barFrac(num(-20, 0, 100)), 0, "below min pins to 0")
    T.eq(VM.barFrac(num(999, 0, 100)), 1, "above max pins to 1")
    T.eq(VM.barFrac(num(5, 5, 5)), 0, "a degenerate range is empty")
end)

T.add("barString renders the text bar from the same fraction", function()
    T.eq(VM.barString(num(0, 0, 100)), "|------------|")
    T.eq(VM.barString(num(100, 0, 100)), "|############|")
    T.eq(VM.barString(num(50, 0, 100)), "|######------|")
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
-- barX / barW now come from the computed columns, so feed them in from a real layout.
T.add("valueFromBar maps the bar edges to min and max", function()
    local c = defView().lay.cols
    local it = num(0, 0, 100)
    T.eq(VM.valueFromBar(it, c.barX, c.barX, c.barW), 0, "left edge is min")
    T.eq(VM.valueFromBar(it, c.barX + c.barW, c.barX, c.barW), 100, "right edge is max")
    T.eq(VM.valueFromBar(it, c.barX + c.barW / 2, c.barX, c.barW), 50, "midpoint is the middle")
end)

T.add("valueFromBar clamps clicks outside the bar", function()
    local c = defView().lay.cols
    local it = num(0, 0, 100)
    T.eq(VM.valueFromBar(it, c.barX - 40, c.barX, c.barW), 0, "left of the bar pins to min")
    T.eq(VM.valueFromBar(it, c.barX + c.barW + 40, c.barX, c.barW), 100, "right of the bar pins to max")
end)

T.add("valueFromBar snaps to step", function()
    local c = defView().lay.cols
    local it = num(0, 0, 10, 1)
    T.eq(VM.valueFromBar(it, c.barX + c.barW * 0.37, c.barX, c.barW), 4) -- ~3.7 snaps to 4
end)

-- ------------------------------------------------------------- ellipsize --
T.add("ellipsize keeps short strings and truncates long ones with an ellipsis", function()
    T.eq(VM.ellipsize("Combat", 12), "Combat")
    T.eq(VM.ellipsize("abcdefghij", 5), "abcd…")
end)

-- --------------------------------------------------------------- columns --
T.add("the name column fits the section and clamps to the range", function()
    local tiny = VM.layout({ modNames = { "M" }, showSub = false, items = { num(1, 0, 9) } }).cols
    T.eq(tiny.nameW, L.minNameW, "a section with no/short names floors at minNameW")
    local mid = VM.layout({ modNames = { "M" }, showSub = false,
        items = { named(string.rep("x", 22), 1, 0, 9) } }).cols
    T.ok(mid.nameW > L.minNameW and mid.nameW < L.maxNameW, "a mid-length name sizes between the bounds")
    T.lt(tiny.decX, mid.decX, "a wider name pushes the controls right")
    local huge = VM.layout({ modNames = { "M" }, showSub = false,
        items = { named(string.rep("x", 120), 1, 0, 9) } }).cols
    T.eq(huge.nameW, L.maxNameW, "a very long name caps at maxNameW")
end)

T.add("a description grows the panel; no description leaves it narrower", function()
    local none = VM.layout({ modNames = { "M" }, showSub = false, items = { named("Opt", 1, 0, 9) } })
    local desc = VM.layout({ modNames = { "M" }, showSub = false,
        items = { { kind = "num", name = "Opt", value = 1, min = 0, max = 9, desc = string.rep("d", 40) } } })
    T.lt(none.panelW, desc.panelW, "a description widens the panel")
    T.ok(desc.cols.descW > 0, "the description column has width")
    T.ok(none.cols.descW == 0, "no description means no description column")
end)

T.add("a very long description is capped at maxPanelW and still leaves room to draw", function()
    local lay = VM.layout({ modNames = { "M" }, showSub = false,
        items = { { kind = "num", name = "Opt", value = 1, min = 0, max = 9, desc = string.rep("d", 400) } } })
    T.ok(lay.panelW <= L.maxPanelW, "the panel never exceeds maxPanelW")
    T.ok(lay.cols.descChars > 0, "there is still room to draw part of the description")
end)

T.add("a section with no numeric row tucks the description in after the toggle", function()
    local c = VM.layout({ modNames = { "M" }, showSub = false,
        items = { { kind = "bool", name = "Flag", value = true, desc = "hint" } } }).cols
    T.eq(c.hasNum, false)
    T.eq(c.descX, c.decX + L.toggleW + L.valDescGap, "no slider/value run is reserved")
end)

T.add("corners returns eight bracket segments inside the panel rect", function()
    local p = { x = 50, y = 60, w = 400, h = 300 }
    local cs = VM.corners(p)
    T.eq(#cs, 8)
    for _, r in ipairs(cs) do
        T.ok(r.x >= p.x and r.x + r.w <= p.x + p.w, "a segment stays within the panel width")
        T.ok(r.y >= p.y and r.y + r.h <= p.y + p.h, "a segment stays within the panel height")
    end
end)

-- --------------------------------------------------------------- layout --
T.add("panel width grows with more and longer tabs, capped at maxPanelW", function()
    local one  = VM.layout({ modNames = names("M", 1), showSub = false, itemCount = 1 })
    local many = VM.layout({ modNames = names("StressMod", 30), showSub = false, itemCount = 1 })
    T.lt(one.panelW, many.panelW, "more tabs widen the panel")
    T.ok(many.panelW <= L.maxPanelW, "never exceeds maxPanelW")
    local short = VM.layout({ modNames = names("A", 8), showSub = false, itemCount = 1 })
    local long  = VM.layout({ modNames = names("ModNameHere", 8), showSub = false, itemCount = 1 })
    T.lt(short.panelW, long.panelW, "auto-sizes to the name length")
end)

T.add("tabs collapse onto new rows and every tab stays within the panel", function()
    local lay = VM.layout({ modNames = names("StressMod", 30), showSub = false, itemCount = 1 })
    local seen = {}
    for _, r in ipairs(lay.modRects) do
        seen[r.y] = true
        T.ok(r.x + r.w <= L.panelX + L.maxPanelW, "a tab never extends past the panel width")
    end
    local rows = 0; for _ in pairs(seen) do rows = rows + 1 end
    T.ok(rows >= 2, "30 mods wrap to more than one row")
end)

T.add("a very long mod name is ellipsized and does not break the layout", function()
    local lay = VM.layout({ modNames = { string.rep("X", 200), "Short" }, showSub = false, itemCount = 1 })
    local r = lay.modRects[1]
    T.ok(#r.name < 40, "the 200-char name is truncated")
    T.ok(r.x + r.w <= L.panelX + L.maxPanelW, "its tab still fits the panel")
    local v = { tabCount = 2, subCount = 0, showSub = false, items = {}, lay = lay }
    local r2 = lay.modRects[2]
    T.eq(VM.hitZone(r2.x + 2, r2.y + 2, v).index, 2, "the next tab is still hit-testable")
end)

T.add("a long item list pages within maxPanelH; a short one does not", function()
    local big = VM.layout({ modNames = { "M" }, showSub = false, itemCount = 1000 })
    T.eq(big.paging, true, "1000 items page")
    T.ok(big.visible < 1000, "only a window of rows is shown")
    T.ok(big.panelH <= L.maxPanelH, "height is capped at maxPanelH")
    local small = VM.layout({ modNames = { "M" }, showSub = false, itemCount = 3 })
    T.eq(small.paging, false)
    T.eq(small.visible, 3)
    T.ok(small.panelH <= L.maxPanelH)
end)

T.add("pageOffset advances by a full page and clamps at the ends", function()
    T.eq(VM.pageOffset(0, 1, 33, 100), 33, "page down from the top")
    T.eq(VM.pageOffset(33, 1, 33, 100), 66, "page down again")
    T.eq(VM.pageOffset(66, 1, 33, 100), 67, "clamps to the last page (maxOff = 67)")
    T.eq(VM.pageOffset(67, 1, 33, 100), 67, "no-op past the end")
    T.eq(VM.pageOffset(40, -1, 33, 100), 7, "page up")
    T.eq(VM.pageOffset(7, -1, 33, 100), 0, "page up clamps to the top")
    T.eq(VM.pageOffset(0, 1, 33, 20), 0, "a list that fits never pages")
end)

T.add("scrollOffset keeps the selected item inside the window", function()
    T.eq(VM.scrollOffset(1, 0, 10, 100), 0, "selection at the top: no scroll")
    T.eq(VM.scrollOffset(5, 0, 10, 100), 0, "selection already in the window: unchanged")
    T.eq(VM.scrollOffset(50, 0, 10, 100), 40, "below the window scrolls it to the last row")
    T.eq(VM.scrollOffset(50, 45, 10, 100), 45, "already visible: unchanged")
    T.eq(VM.scrollOffset(3, 40, 10, 100), 2, "above the window scrolls up")
    T.eq(VM.scrollOffset(100, 0, 10, 100), 90, "clamps to the last page")
    T.eq(VM.scrollOffset(5, 0, 10, 8), 0, "a list that fits never scrolls")
end)

-- ------------------------------------------------------------- hit zones --
T.add("clicking the [X] button hits close", function()
    local v = defView()
    T.eq(VM.hitZone(v.lay.closeX + 4, L.closeY + 4, v).zone, "close")
end)

T.add("clicking a mod tab and a sub tab resolves to its index", function()
    local v = defView()
    local m1, m2 = v.lay.modRects[1], v.lay.modRects[2]
    T.eq(VM.hitZone(m1.x + 4, m1.y + 4, v).zone, "modtab")
    T.eq(VM.hitZone(m2.x + 4, m2.y + 4, v).index, 2, "second mod tab")
    local s1, s2 = v.lay.subRects[1], v.lay.subRects[2]
    T.eq(VM.hitZone(s1.x + 4, s1.y + 4, v).zone, "subtab")
    T.eq(VM.hitZone(s2.x + 4, s2.y + 4, v).index, 2, "second sub tab")
end)

T.add("a num row resolves [-], the bar, [+], and a bare select by column", function()
    local v = defView()
    local c = v.lay.cols
    local y = rowY(1, v)
    T.eq(VM.hitZone(c.decX + 2, y, v).part, "dec", "[-] column")
    T.eq(VM.hitZone(c.incX + 2, y, v).part, "inc", "[+] column")
    T.eq(VM.hitZone(c.barX + 4, y, v).part, "bar", "bar interior")
    T.eq(VM.hitZone(c.nameX + 2, y, v).part, "select", "name column just selects")
    T.eq(VM.hitZone(c.barX + 4, y, v).index, 1, "row index")
end)

-- the regression that bit us: the [-] zone must not bleed onto the bar, or a click on the bar's
-- left edge would step down by one instead of setting the value where you clicked.
T.add("the [-] zone and the bar zone do not overlap", function()
    local v = defView()
    local c = v.lay.cols
    local y = rowY(1, v)
    T.eq(VM.hitZone(c.barX, y, v).part, "bar", "the bar's first pixel is bar, not dec")
    T.lt(c.decX + c.colW, c.barX, "[-] right edge sits left of the bar's left edge")
    T.lt(c.barX + c.barW, c.incX - 6, "bar right edge sits left of the [+] hit zone")
end)

T.add("a bool row resolves its toggle zone", function()
    local v = defView()
    local c = v.lay.cols
    local z = VM.hitZone(c.decX + 4, rowY(2, v), v)
    T.eq(z.zone, "item")
    T.eq(z.index, 2)
    T.eq(z.part, "toggle")
end)

T.add("the scroll arrows resolve to scroll up / down when paging", function()
    local lay = VM.layout({ modNames = { "M" }, showSub = false, itemCount = 1000 })
    local pv = { tabCount = 1, subCount = 0, showSub = false, items = {}, lay = lay }
    local yInd = lay.rowTop + lay.visible * L.rowH
    T.eq(VM.hitZone(L.markX + 2, yInd + 4, pv).zone, "scroll")
    T.eq(VM.hitZone(L.markX + 2, yInd + 4, pv).dir, -1, "left arrow scrolls up")
    T.eq(VM.hitZone(L.markX + 36, yInd + 4, pv).dir, 1, "right arrow scrolls down")
    -- the two zones are contiguous (no dead strip between the glyphs)
    T.eq(VM.hitZone(L.markX + 32, yInd + 4, pv).dir, -1, "the boundary belongs to up")
    T.eq(VM.hitZone(L.markX + 33, yInd + 4, pv).dir, 1, "just past the boundary is down")
end)

T.add("clicks off the panel and below the last row miss", function()
    local v = defView()
    T.eq(VM.hitZone(L.panelX - 20, rowY(1, v), v), nil, "left of the panel")
    T.eq(VM.hitZone(L.nameX, v.lay.rowTop + 5 * L.rowH, v), nil, "below the last row")
end)

os.exit(T.run())
