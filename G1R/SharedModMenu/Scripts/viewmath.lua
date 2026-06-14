-- viewmath.lua  --  the menu's pure value, slider and hit-test math.
--
-- This holds the panel LAYOUT and every calculation that turns an item plus a pixel into a value
-- or a click target. It names no engine globals, so it loads under bare LuaJIT and is unit-tested
-- on its own (tests/test_viewmath.lua); render.lua owns only the reflection and widget plumbing.
-- Keeping the math here is deliberate: the click-zone overlap and bar-fill rounding are exactly the
-- parts that have bitten us, and they are the parts a test can pin down.

local tonumber, tostring, math, string = tonumber, tostring, math, string
local floor, rep = math.floor, string.rep

local VM = {}

-- number of cells in a slider bar (|####------| style)
VM.BAR_CHARS = 12

-- Panel layout in viewport pixels. The num-row columns are spaced so the [-] / bar / [+] click
-- zones never overlap (there is a gap between each), which is what makes a click on the bar's left
-- edge set the value instead of falling through to [-]:
--   [-] 234..258 | bar 266..378 | value 390..436 | [+] 446..470
local L = {
    panelX = 50, panelY = 58, panelW = 440,
    closeW = 40, closeH = 18, closeY = 60,
    modTabY = 68, subTabY = 92, tabH = 20, tabX0 = 60, tabStep = 98, tabW = 92,
    rowH = 22, markX = 60, nameX = 78, nameW = 150,
    decX = 234, barX = 266, barW = 112, valX = 390, valW = 46, incX = 446, colW = 24,
}
L.closeX = L.panelX + L.panelW - L.closeW - 2
VM.L = L

-- A num item carries a slider only when it is range-bounded.
function VM.hasBar(it) return it.kind == "num" and it.min and it.max end

-- The slider's text: a filled fraction of BAR_CHARS, rounded to the nearest cell, clamped to [0,1].
function VM.barString(it)
    local lo, hi = it.min or 0, it.max or 1
    local frac = (hi > lo) and (((tonumber(it.value) or 0) - lo) / (hi - lo)) or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local filled = floor(frac * VM.BAR_CHARS + 0.5)
    return "|" .. rep("#", filled) .. rep("-", VM.BAR_CHARS - filled) .. "|"
end

-- The value column's text, by kind.
function VM.valText(it)
    if it.kind == "bool" then return it.value and "[ ON ]" or "[ OFF ]" end
    if it.kind == "action" then return "[ RUN ]" end
    return tostring(it.value)
end

-- Wrap-around clamp for tab / sub-tab / row navigation: past the end wraps to the start and back.
function VM.clampWrap(n, lo, hi)
    if n < lo then return hi elseif n > hi then return lo else return n end
end

-- New value for a num item after a [-] (d=-1) or [+] (d=1) step, clamped to its bounds.
function VM.stepValue(it, d)
    local v = (tonumber(it.value) or 0) + d * (it.step or 1)
    if it.min and v < it.min then v = it.min elseif it.max and v > it.max then v = it.max end
    return v
end

-- New value for a num item from a click at pixel px inside its bar: pixel -> fraction -> value,
-- snapped to step and clamped. px at barX is the minimum, px at barX+barW is the maximum.
function VM.valueFromBar(it, px)
    local lo, hi = it.min or 0, it.max or 1
    local frac = (px - L.barX) / L.barW
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local v = lo + frac * (hi - lo)
    if it.step and it.step > 0 then v = lo + floor((v - lo) / it.step + 0.5) * it.step end
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

-- which tab in a row sits under px, or nil
local function hitTabRow(px, py, y, count)
    if py < y or py > y + L.tabH then return nil end
    for i = 1, count do
        local x0 = L.tabX0 + (i - 1) * L.tabStep
        if px >= x0 and px <= x0 + L.tabW then return i end
    end
end

-- Resolve a click at (px, py) into a zone. The view is the current frame's shape:
--   { tabCount, subCount, showSub, rowTop, items }   (items as read from the bridge)
-- Returns one of, or nil for a miss outside any target:
--   { zone = "close" }
--   { zone = "modtab", index = n }
--   { zone = "subtab", index = n }
--   { zone = "item",   index = i, part = "select" | "toggle" | "dec" | "inc" | "bar" }
function VM.hitZone(px, py, view)
    if px >= L.closeX - 4 and px <= L.closeX + L.closeW and py >= L.closeY - 2 and py <= L.closeY + L.closeH then
        return { zone = "close" }
    end
    local mt = hitTabRow(px, py, L.modTabY, view.tabCount or 0)
    if mt then return { zone = "modtab", index = mt } end
    if view.showSub then
        local st = hitTabRow(px, py, L.subTabY, view.subCount or 0)
        if st then return { zone = "subtab", index = st } end
    end
    local items = view.items or {}
    local idx = floor((py - view.rowTop) / L.rowH) + 1
    if px < L.panelX or px > L.panelX + L.panelW or idx < 1 or idx > #items then return nil end
    local it = items[idx]
    local part = "select"
    if it.kind == "bool" or it.kind == "action" then
        if px >= L.decX - 6 and px <= L.decX + 150 then part = "toggle" end
    elseif it.kind == "num" then
        if px >= L.decX - 6 and px <= L.decX + L.colW then part = "dec"
        elseif px >= L.incX - 6 and px <= L.incX + L.colW then part = "inc"
        elseif VM.hasBar(it) and px >= L.barX and px <= L.barX + L.barW then part = "bar" end
    end
    return { zone = "item", index = idx, part = part }
end

return VM
