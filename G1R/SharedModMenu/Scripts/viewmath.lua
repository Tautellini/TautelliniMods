-- viewmath.lua  --  the menu's pure value, slider, layout and hit-test math.
--
-- Holds the panel LAYOUT and every calculation that turns an item plus a pixel into a value or a
-- click target. It names no engine globals, so it loads under bare LuaJIT / Lua 5.4 and is unit-
-- tested on its own (tests/test_viewmath.lua); render.lua owns only the reflection/widget plumbing.
--
-- Tabs (both the mod row and the sub-page row) are VARIABLE width, sized to their name, and FLOW
-- left to right, collapsing onto a new row once a row would pass maxRowW. The panel then sizes
-- itself to the content, so adding mods or longer names widens it instead of overflowing. A name
-- longer than tabNameMax (item names: itemNameMax) is ellipsized, so one long name can neither
-- break a tab's bounds nor bleed a row into the value columns. The tab flow, panel sizing, click-
-- zone overlap and bar-fill rounding are exactly the parts that have bitten us, so they live here
-- where a test can pin them down.

local tonumber, tostring, math, string = tonumber, tostring, math, string
local floor, max, rep, ssub = math.floor, math.max, string.rep, string.sub

local VM = {}

-- number of cells in a slider bar (|####------| style)
VM.BAR_CHARS = 12

-- Panel layout in viewport pixels. The num-row columns are spaced so the [-] / bar / [+] click
-- zones never overlap (there is a gap between each), which is what makes a click on the bar's left
-- edge set the value instead of falling through to [-]:
--   [-] 234..258 | bar 266..378 | value 390..436 | [+] 446..470
local L = {
    panelX = 50, panelY = 58,
    closeW = 40, closeH = 18, closeY = 60,
    modTabY = 68, tabH = 20, tabX0 = 60,
    tabRowStep = 24,   -- vertical pitch when a tab row collapses onto the next
    tabGap = 6,        -- horizontal gap between two tabs in a row
    charW = 8.5,       -- approx px per char at the menu font, over-estimated so tabs never collide
    tabPad = 10,       -- horizontal padding inside a tab on top of its text width
    tabNameMax = 28,   -- a tab name is ellipsized to this many chars so one long name can't dominate
    maxPanelW = 1200,  -- the panel never grows wider than this (tab rows collapse to stay within it)
    maxPanelH = 800,   -- the panel never grows taller than this (items page within it)
    subGap = 10,       -- gap between the mod-tab row and the sub-page row (a divider sits centered in it)
    rowGap = 12,       -- gap below the tab blocks before the first item row (a divider sits centered in it)
    rowH = 22, markX = 60, nameX = 78, nameW = 150,
    decX = 234, barX = 266, barW = 112, valX = 390, valW = 46, incX = 446, colW = 24,
}
-- item names are ellipsized to clear the value columns (the gap from the name to the [-] column)
L.itemNameMax = floor((L.decX - L.nameX - 8) / L.charW)
-- a tab row fills names up to this width then collapses to a new row; sized so the panel (left
-- offset + tabs + the [X] reserve) never passes maxPanelW.
L.maxRowW = L.maxPanelW - (L.tabX0 - L.panelX) - L.closeW - 12
VM.L = L

-- Truncate s to maxChars, appending an ellipsis when it would overflow. Char count is byte count
-- (mod and option names are ASCII); good enough for the layout heuristic.
function VM.ellipsize(s, maxChars)
    s = tostring(s)
    if #s <= maxChars then return s end
    if maxChars <= 1 then return "…" end
    return ssub(s, 1, maxChars - 1) .. "…"
end

-- pixel width of a tab whose ellipsized name is ename (+2 chars for the surrounding [ ] / spaces)
local function tabWidth(ename) return (#ename + 2) * L.charW + L.tabPad end

-- Flow a list of names into wrapped rows starting at topY. Returns rects { x, y, w, name } (name
-- already ellipsized, so render draws exactly what was measured), the block's bottom Y, and the
-- rightmost pixel any row used.
local function flow(names, topY)
    local rects, x, y, usedRight = {}, L.tabX0, topY, L.tabX0
    for i = 1, #names do
        local ename = VM.ellipsize(names[i], L.tabNameMax)
        local w = tabWidth(ename)
        if x > L.tabX0 and (x - L.tabX0 + w) > L.maxRowW then x = L.tabX0; y = y + L.tabRowStep end
        rects[i] = { x = x, y = y, w = w, name = ename }
        x = x + w + L.tabGap
        if (x - L.tabGap) > usedRight then usedRight = x - L.tabGap end
    end
    local bottom = (#names > 0) and (y + L.tabH) or topY
    return rects, bottom, usedRight
end

-- The full computed layout for one frame. Inputs describe the view; outputs are every position
-- render.lua draws at and hitZone tests against, so the two can never drift.
--   spec = { modNames = {..}, subNames = {..}, showSub = bool, itemCount = n }
function VM.layout(spec)
    local modNames  = spec.modNames or {}
    local showSub   = spec.showSub and true or false
    local subNames  = showSub and (spec.subNames or {}) or {}
    local itemCount = max(spec.itemCount or 0, 0)

    local modRects, modBottom, modRight = flow(modNames, L.modTabY)
    local subTabY = modBottom + L.subGap
    local subRects, subBottom, subRight = {}, modBottom, L.tabX0
    if showSub then subRects, subBottom, subRight = flow(subNames, subTabY) end

    local rowTop = (showSub and subBottom or modBottom) + L.rowGap

    -- items page vertically so the panel never passes maxPanelH; one row is kept for the scroll
    -- indicator while paging.
    local maxRows   = max(1, floor((L.maxPanelH - (rowTop - L.panelY) - 14) / L.rowH))
    local paging    = itemCount > maxRows
    local visible   = paging and max(1, maxRows - 1) or itemCount
    local shownRows = paging and (visible + 1) or max(1, itemCount)
    local panelH = (rowTop - L.panelY) + shownRows * L.rowH + 14
    if panelH > L.maxPanelH then panelH = L.maxPanelH end

    -- width fills to the widest tab row, leaves room for the [X] to its right, never shrinks below
    -- the item-column area, and is capped at maxPanelW by maxRowW (the flow wrap threshold).
    local usedRight = max(modRight, subRight, L.tabX0)
    local panelRight = max(L.incX + L.colW + 20, usedRight + L.closeW + 12)
    local panelW = panelRight - L.panelX
    local closeX = panelRight - L.closeW - 2

    return { modRects = modRects, subRects = subRects, subTabY = subTabY, rowTop = rowTop,
             panelW = panelW, panelH = panelH, closeX = closeX, visible = visible, paging = paging }
end

-- Scroll offset (0-based) that keeps the selected item visible inside a window of `visible` rows.
function VM.scrollOffset(sel, off, visible, count)
    off = off or 0
    if visible >= count then return 0 end
    if sel < off + 1 then off = sel - 1 end
    if sel > off + visible then off = sel - visible end
    local maxOff = count - visible
    if off < 0 then off = 0 elseif off > maxOff then off = maxOff end
    return off
end

-- New scroll offset after a page step (dir -1 / +1): advance the window by a FULL page, clamped to
-- the last page. Used by the [^]/[v] arrows so one click moves a page, not a single row.
function VM.pageOffset(off, dir, visible, count)
    local maxOff = max(0, count - visible)
    local n = (off or 0) + dir * visible
    if n < 0 then n = 0 elseif n > maxOff then n = maxOff end
    return n
end

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

-- which tab rect sits under (px, py), or nil
local function hitRects(px, py, rects)
    for i = 1, #rects do
        local r = rects[i]
        if px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + L.tabH then return i end
    end
    return nil
end

-- Resolve a click at (px, py) into a zone. view carries the current frame's shape plus the layout:
--   { tabCount, subCount, showSub, items, lay = VM.layout(...) }
-- Returns one of, or nil for a miss outside any target:
--   { zone = "close" }
--   { zone = "modtab", index = n }
--   { zone = "subtab", index = n }
--   { zone = "item",   index = i, part = "select" | "toggle" | "dec" | "inc" | "bar" }
function VM.hitZone(px, py, view)
    local lay = view.lay
    if px >= lay.closeX - 4 and px <= lay.closeX + L.closeW and py >= L.closeY - 2 and py <= L.closeY + L.closeH then
        return { zone = "close" }
    end
    local mt = hitRects(px, py, lay.modRects)
    if mt then return { zone = "modtab", index = mt } end
    if view.showSub then
        local st = hitRects(px, py, lay.subRects)
        if st then return { zone = "subtab", index = st } end
    end
    if lay.paging then
        local yInd = lay.rowTop + lay.visible * L.rowH
        if py >= yInd and py <= yInd + L.rowH then
            if px >= L.markX and px <= L.markX + 32 then return { zone = "scroll", dir = -1 } end
            if px >  L.markX + 32 and px <= L.markX + 64 then return { zone = "scroll", dir = 1 } end
            return nil
        end
    end
    local items = view.items or {}
    local idx = floor((py - lay.rowTop) / L.rowH) + 1
    if px < L.panelX or px > L.panelX + lay.panelW or idx < 1 or idx > #items then return nil end
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
