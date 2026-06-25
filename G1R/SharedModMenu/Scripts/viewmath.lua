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

-- Fixed layout constants in viewport pixels. The item-row COLUMNS (name width, [-], bar, [+],
-- value, description) are computed per section by VM.layout into lay.cols, because the name width
-- now fits the section and the panel grows to fit descriptions. render and hitZone both read
-- lay.cols, so the draw and the hit-test can never drift. The gaps below keep the [-] / bar / [+]
-- click zones from overlapping (a click on the bar's left edge sets the value, not a step down).
local L = {
    panelX = 50, panelY = 58,
    closeW = 28,       -- the [X] button; its Y / H are derived below to sit in the mod-tab row
    modTabY = 68, tabH = 28, tabX0 = 60,
    tabRowStep = 32,   -- vertical pitch when a tab row collapses onto the next
    tabGap = 8,        -- horizontal gap between two tabs in a row
    charW = 8.5,       -- approx px per char at the menu font, over-estimated so text never collides
    tabPad = 22,       -- horizontal padding inside a tab on top of its text width
    tabNameMax = 28,   -- a tab name is ellipsized to this many chars so one long name can't dominate
    maxPanelW = 1200,  -- the panel never grows wider than this (tab rows collapse, descriptions clip)
    maxPanelH = 800,   -- the panel never grows taller than this (items page within it)
    subGap = 10,       -- gap between the mod-tab row and the sub-page row (a divider sits centered in it)
    rowGap = 14,       -- gap below the tab blocks before the first item row (a divider sits centered in it)
    pad = 12,          -- panel inner padding / gutter
    rowH = 24,
    markX = 60,        -- left gutter; the selection edge sits here
    nameX = 78,
    minNameW = 120, maxNameW = 300,  -- the name column fits the section, clamped to this range
    nameGap = 18,      -- name column to the first control
    colW = 24,         -- [-] / [+] button width
    decBarGap = 8,     -- [-] to the bar
    barW = 120,        -- slider track width (CONSTANT, so the bar never changes length)
    barH = 10,         -- slider track thickness
    barIncGap = 12,    -- bar to [+]
    incValGap = 14,    -- [+] to the value readout
    valW = 56,         -- numeric value readout width
    valDescGap = 22,   -- value (or toggle) to the description column
    toggleW = 66,      -- [ ON ] / [ OFF ] / [ RUN ] control width
    maxDescW = 460,    -- description column width cap; longer text ellipsizes
    brkLen = 14, brkW = 2, brkInset = 5,  -- corner-bracket arm length / thickness / inset from the edge
}
-- the [X] sits in the mod-tab row, right-aligned and the same height as a tab
L.closeY = L.modTabY
L.closeH = L.tabH
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
--   spec = { modNames = {..}, subNames = {..}, showSub = bool, items = {..} }
-- `items` is the current section's list, used for the name width, the description width and whether
-- any row carries a slider. spec.itemCount is still honoured for count-only callers (e.g. paging).
function VM.layout(spec)
    local modNames  = spec.modNames or {}
    local showSub   = spec.showSub and true or false
    local subNames  = showSub and (spec.subNames or {}) or {}
    local items     = spec.items or {}
    local itemCount = spec.itemCount or #items

    local modRects, modBottom, modRight = flow(modNames, L.modTabY)
    local subTabY = modBottom + L.subGap
    local subRects, subBottom, subRight = {}, modBottom, L.tabX0
    if showSub then subRects, subBottom, subRight = flow(subNames, subTabY) end

    local rowTop = (showSub and subBottom or modBottom) + L.rowGap

    -- item columns: the name fits the widest name in this section (clamped), every control lines up
    -- under it, and the description sits past the controls. A section with no numeric row reserves
    -- no slider/value run, so its description tucks in right after the toggle.
    local widestName, widestDesc, hasNum = 0, 0, false
    for _, it in ipairs(items) do
        local nlen = #tostring(it.name or "")
        if nlen > widestName then widestName = nlen end
        if it.kind == "num" then hasNum = true end
        if type(it.desc) == "string" and it.desc ~= "" and #it.desc > widestDesc then widestDesc = #it.desc end
    end
    local nameW = widestName * L.charW + 6
    if nameW < L.minNameW then nameW = L.minNameW elseif nameW > L.maxNameW then nameW = L.maxNameW end

    local nameX = L.nameX
    local decX  = nameX + nameW + L.nameGap
    local barX  = decX + L.colW + L.decBarGap
    local incX  = barX + L.barW + L.barIncGap
    local valX  = incX + L.colW + L.incValGap
    local controlsRight = hasNum and (valX + L.valW) or (decX + L.toggleW)
    local descX = controlsRight + L.valDescGap

    local descW = 0
    if widestDesc > 0 then
        descW = widestDesc * L.charW + 6
        if descW > L.maxDescW then descW = L.maxDescW end
    end

    -- items page vertically so the panel never passes maxPanelH; one row is kept for the scroll
    -- indicator while paging.
    local maxRows   = max(1, floor((L.maxPanelH - (rowTop - L.panelY) - 14) / L.rowH))
    local paging    = itemCount > maxRows
    local visible   = paging and max(1, maxRows - 1) or itemCount
    local shownRows = paging and (visible + 1) or max(1, itemCount)
    local panelH = (rowTop - L.panelY) + shownRows * L.rowH + 14
    if panelH > L.maxPanelH then panelH = L.maxPanelH end

    -- width fills to the widest of: the tab row (plus the [X] reserve), the control columns, and
    -- the description column. Capped at maxPanelW; past the cap the description ellipsizes.
    local usedRight    = max(modRight, subRight, L.tabX0)
    local contentRight = (descW > 0) and (descX + descW) or controlsRight
    local panelRight   = max(contentRight + L.pad, usedRight + L.closeW + 12)
    if panelRight > L.panelX + L.maxPanelW then panelRight = L.panelX + L.maxPanelW end
    local panelW = panelRight - L.panelX
    -- the [X] right edge sits at the same inset from the panel as the left tab margin, so it lines
    -- up with the content (and the border) pixel-for-pixel instead of poking out farther right.
    local closeX = panelRight - L.closeW - (L.tabX0 - L.panelX)

    local descAvailW = (panelRight - L.pad) - descX
    if descAvailW < 0 then descAvailW = 0 end
    local cols = {
        markX = L.markX, nameX = nameX, nameW = nameW, nameChars = floor(nameW / L.charW),
        decX = decX, colW = L.colW, barX = barX, barW = L.barW,
        incX = incX, valX = valX, valW = L.valW, toggleW = L.toggleW, hasNum = hasNum,
        descX = descX, descW = descW, descChars = floor(descAvailW / L.charW),
    }

    return { modRects = modRects, subRects = subRects, subTabY = subTabY, rowTop = rowTop,
             panelW = panelW, panelH = panelH, closeX = closeX, visible = visible, paging = paging,
             cols = cols }
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

-- The slider's filled fraction, clamped to [0,1]. The drawn bar uses this directly (fill width =
-- barFrac * barW); the text bar below is kept for tests and any text-only consumer.
function VM.barFrac(it)
    local lo, hi = it.min or 0, it.max or 1
    local frac = (hi > lo) and (((tonumber(it.value) or 0) - lo) / (hi - lo)) or 0
    if frac < 0 then return 0 elseif frac > 1 then return 1 end
    return frac
end

-- The slider as text: a filled fraction of BAR_CHARS, rounded to the nearest cell.
function VM.barString(it)
    local filled = floor(VM.barFrac(it) * VM.BAR_CHARS + 0.5)
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
-- snapped to step and clamped. px at barX is the minimum, px at barX+barW is the maximum. barX/barW
-- come from the computed columns (lay.cols), since the bar's position now depends on the section.
function VM.valueFromBar(it, px, barX, barW)
    local lo, hi = it.min or 0, it.max or 1
    local frac = (px - barX) / barW
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
    local cols = lay.cols
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
        if px >= cols.decX - 6 and px <= cols.decX + cols.toggleW then part = "toggle" end
    elseif it.kind == "num" then
        if px >= cols.decX - 6 and px <= cols.decX + cols.colW then part = "dec"
        elseif px >= cols.incX - 6 and px <= cols.incX + cols.colW then part = "inc"
        elseif VM.hasBar(it) and px >= cols.barX and px <= cols.barX + cols.barW then part = "bar" end
    end
    return { zone = "item", index = idx, part = part }
end

-- The eight thin rectangles that make the four corner brackets for a panel rect { x, y, w, h }:
-- each corner is a short horizontal arm and a short vertical arm (the spec-sheet frame motif).
function VM.corners(p)
    local x, y, w, h, n, t = p.x, p.y, p.w, p.h, L.brkLen, L.brkW
    return {
        { x = x,         y = y,         w = n, h = t }, { x = x,         y = y,         w = t, h = n },
        { x = x + w - n, y = y,         w = n, h = t }, { x = x + w - t, y = y,         w = t, h = n },
        { x = x,         y = y + h - t, w = n, h = t }, { x = x,         y = y + h - n, w = t, h = n },
        { x = x + w - n, y = y + h - t, w = n, h = t }, { x = x + w - t, y = y + h - n, w = t, h = n },
    }
end

return VM
