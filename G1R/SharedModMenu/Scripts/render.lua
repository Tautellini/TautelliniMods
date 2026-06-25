-- render.lua  --  the pure-Lua UMG menu renderer.
--
-- Builds an in-game panel from UE4SS reflection and shows whatever mods registered through the
-- bridge (modmenu): a top row of mod tabs, a second row of the selected mod's sub-tabs, then that
-- section's items. Settings arrive as DATA (modmenu.readAll), and an edit becomes a
-- modmenu.sendEdit the owning mod applies in its own state; the row updates optimistically.
--
-- Input is mouse (an LMB keybind + GetMousePositionOnViewport hit-testing) and numpad. The widget
-- is built ONCE and re-attached on reopen; it is rebuilt only when the registered set or the
-- selected mod/sub-tab changes (a signature), or on a world change.

local print, ipairs, tostring, tonumber, type, string, pcall, math, table =
      print, ipairs, tostring, tonumber, type, string, pcall, math, table
local rawget, rawset = rawget, rawset

local FindAllOf             = rawget(_G, "FindAllOf")
local StaticFindObject      = rawget(_G, "StaticFindObject")
local StaticConstructObject = rawget(_G, "StaticConstructObject")

-- self-contained: the native-safety helpers are inline, and the cross-mod bridge is the
-- standalone modmenu.lua (the same one file consumers vendor).
local function isValid(o)
    if o == nil then return false end
    local k, v = pcall(function() return o:IsValid() end)
    return (k and v) and true or false
end
local function guard(o, fn) if not isValid(o) then return nil end local k, r = pcall(fn, o) if k then return r end return nil end
local function try(fn) local k, r = pcall(fn) if k then return r end return nil end
local okMenu, menu = pcall(require, "modmenu")
if not okMenu then menu = nil end

local function log(m) print("[SharedModMenu] " .. tostring(m) .. "\n") end

-- intra-mod state (own _G, survives CTRL+R so a lingering widget can be cleaned)
local S = rawget(_G, "__smmState")
if not S then S = { open = false, tab = 1, sub = 1, sel = 1, off = 0 }; rawset(_G, "__smmState", S) end

-- cached reflection lookups (StaticFindObject results are process-stable; the PlayerController
-- is re-resolved only when it goes invalid). FindAllOf per click was the original hitch.
local clsCache = {}
local function cls(p)
    local c = clsCache[p]; if isValid(c) then return c end
    c = try(function() return StaticFindObject(p) end); clsCache[p] = c; return c
end
local function firstLive(c)
    local list = try(function() return FindAllOf(c) end); if not list then return nil end
    for _, o in ipairs(list) do
        if isValid(o) and not string.find(guard(o, function(x) return x:GetFullName() end) or "", "Default__", 1, true) then return o end
    end
end
local function getPC()
    if isValid(S.pc) then return S.pc end
    S.pc = firstLive("GothicPlayerController") or firstLive("PlayerController"); return S.pc
end
local function wlib() return cls("/Script/UMG.Default__WidgetBlueprintLibrary") end
local function wll()  return cls("/Script/UMG.Default__WidgetLayoutLibrary") end
local function toText(s)
    local kt = cls("/Script/Engine.Default__KismetTextLibrary"); if not isValid(kt) then return nil end
    return try(function() return kt:Conv_StringToText(s) end)
end

-- All value, slider and hit-test math (and the panel layout) live in the pure viewmath module so
-- they can be unit-tested without the engine; render.lua keeps only the reflection/widget plumbing.
local VM = require("viewmath")
local L = VM.L
local FONT = 12
local ROW_TEXT_DY = 4  -- nudge row text down so it sits centered against the slider track
local TAB_TEXT_DY = 6  -- vertical inset of a tab / close label inside its (taller) button

-- Brand "Aurum" palette (premium-dark, gold accent). SetBrushColor / SetColorAndOpacity take a
-- LINEAR FLinearColor, but the brand tokens are sRGB hex, so convert once here.
local function lin(c) if c <= 0.04045 then return c / 12.92 end return ((c + 0.055) / 1.055) ^ 2.4 end
local function rgb(r, g, b, a) return { R = lin(r / 255), G = lin(g / 255), B = lin(b / 255), A = a or 1 } end
local PANEL_BG     = rgb(0x0a, 0x0a, 0x0c, 0.94)  -- near-black panel surface
local SEP_COLOR    = rgb(0x3a, 0x3a, 0x46, 0.90)  -- neutral hairline dividers
local BRACKET      = rgb(0x3a, 0x3a, 0x46, 0.90)  -- corner-bracket frame
local TAB_BG       = rgb(0x19, 0x19, 0x20, 0.95)  -- an idle mod / section tab
local TAB_SEL      = rgb(0xd4, 0xb0, 0x6a, 0.96)  -- the active tab (gold)
local ACCENT       = rgb(0xd4, 0xb0, 0x6a, 1.00)  -- slider fill, selection edge
local SLIDER_TRACK = rgb(0x2a, 0x2a, 0x33, 1.00)  -- the unfilled slider track
local SEL_BG       = rgb(0x24, 0x20, 0x16, 0.55)  -- selected-row highlight (warm dark)
local INK0         = rgb(0xec, 0xec, 0xef, 1.00)  -- primary text: names, values
local INK1         = rgb(0xa6, 0xa6, 0xb0, 1.00)  -- secondary: descriptions, idle tab labels
local INK2         = rgb(0x6e, 0x6e, 0x7a, 1.00)  -- tertiary: paging, hints
local TAB_SEL_INK  = rgb(0x12, 0x0e, 0x07, 1.00)  -- dark text on the gold active tab

-- ----------------------------------------------------------- data access --
local function curMod() return S.tabs and S.tabs[S.tab] end
local function curSections() local m = curMod(); return m and m.sections or {} end
local function curItems() local s = curSections()[S.sub]; return s and s.items or {} end
local function modName() local m = curMod(); return m and m.name end
local function tabCount() return S.tabs and #S.tabs or 0 end
local function subCount() return #curSections() end
local clamp, hasBar, barFrac, valText = VM.clampWrap, VM.hasBar, VM.barFrac, VM.valText

-- send an edit to the owning mod and reflect it locally at once
local function editItem(it, d)
    if not menu then return end
    if it.kind == "bool" then it.value = not it.value
    elseif it.kind == "num" then it.value = VM.stepValue(it, d)
    elseif it.kind ~= "action" then return end
    menu.sendEdit(modName(), it.flat, it.kind, it.value)
end
local function setItemFromBar(it, px)
    local cols = S.lay and S.lay.cols
    it.value = VM.valueFromBar(it, px, cols and cols.barX or L.markX, cols and cols.barW or L.barW)
    if menu then menu.sendEdit(modName(), it.flat, "num", it.value) end
end

-- --------------------------------------------------------------- build UI --
local function build()
    local pc = getPC(); if not isValid(pc) then log("no PlayerController (be in-game)"); return false end
    local lib = wlib()
    local uwC, cpC, brC, tbC = cls("/Script/UMG.UserWidget"), cls("/Script/UMG.CanvasPanel"),
        cls("/Script/UMG.Border"), cls("/Script/UMG.TextBlock")
    if not (isValid(lib) and isValid(uwC) and isValid(cpC) and isValid(brC) and isValid(tbC)) then log("missing UMG class/lib"); return false end
    local widget = try(function() return lib:Create(pc, uwC, pc) end)
    local tree = isValid(widget) and guard(widget, function(w) return w.WidgetTree end)
    if not isValid(tree) then log("widget create failed"); return false end
    local function make(c) return try(function() return StaticConstructObject(c, tree) end) end
    local canvas = make(cpC); if not isValid(canvas) then return false end
    pcall(function() tree.RootWidget = canvas end)
    local function applyColor(tb, color)
        if not color then return end
        pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    end
    local function addText(t, x, y, w, size, justify, color)
        local tb = make(tbC); if not isValid(tb) then return nil end
        local ft = toText(t); if ft ~= nil then pcall(function() tb:SetText(ft) end) end
        local slot = try(function() return canvas:AddChildToCanvas(tb) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = w, Y = L.rowH }) end) end
        pcall(function() local f = tb.Font; f.Size = size or FONT; tb:SetFont(f) end)
        if justify then pcall(function() tb:SetJustification(justify) end) end
        applyColor(tb, color)
        return tb
    end
    -- a filled rectangle (Border); returns its canvas slot so the caller can move or resize it later
    local function addBox(color, x, y, w, h)
        local b = make(brC); if not isValid(b) then return nil end
        pcall(function() b:SetBrushColor(color) end)
        local slot = try(function() return canvas:AddChildToCanvas(b) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = w, Y = h }) end) end
        return slot
    end
    -- the four edges of a rectangle outline (panel frame, section buttons)
    local function addRectBorder(color, x, y, w, h)
        addBox(color, x, y, w, 1); addBox(color, x, y + h - 1, w, 1)
        addBox(color, x, y, 1, h); addBox(color, x + w - 1, y, 1, h)
    end
    local function addButton(r, selected) addBox(selected and TAB_SEL or TAB_BG, r.x, r.y, r.w, L.tabH) end

    local sections, items = curSections(), curItems()
    S.showSub = #sections > 1 or (sections[1] and sections[1].title ~= nil) or false
    local modNames = {}
    for t = 1, tabCount() do modNames[t] = S.tabs[t].name end
    local subNames = {}
    if S.showSub then for s = 1, #sections do subNames[s] = sections[s].title or "Main" end end
    local lay = VM.layout({ modNames = modNames, subNames = subNames, showSub = S.showSub, items = items })
    S.lay = lay
    local cols = lay.cols
    S.off = VM.scrollOffset(S.sel, S.off or 0, lay.visible, #items)  -- keep the selection in view

    addBox(PANEL_BG, L.panelX, L.panelY, lay.panelW, lay.panelH)
    -- a full hairline border framing the panel (in place of the internal section dividers)
    addRectBorder(SEP_COLOR, L.panelX, L.panelY, lay.panelW, lay.panelH)
    -- corner brackets, inset from the edge so they read as free-floating inner corners
    local bi = L.brkInset
    for _, c in ipairs(VM.corners({ x = L.panelX + bi, y = L.panelY + bi, w = lay.panelW - 2 * bi, h = lay.panelH - 2 * bi })) do
        addBox(BRACKET, c.x, c.y, c.w, c.h)
    end

    -- close: a square button sitting in the mod-tab row, right-aligned
    addBox(TAB_BG, lay.closeX, L.closeY, L.closeW, L.closeH)
    addText("X", lay.closeX, L.closeY + TAB_TEXT_DY, L.closeW, FONT, 1, INK1)
    -- mod tabs (primary nav): solid filled buttons, gold when active
    for t = 1, tabCount() do
        local r = lay.modRects[t]
        addButton(r, t == S.tab)
        addText(r.name, r.x, r.y + TAB_TEXT_DY, r.w, FONT, 1, t == S.tab and TAB_SEL_INK or INK1)
    end
    -- sub-tabs (sections, secondary nav): OUTLINED buttons, distinct from the FILLED mod buttons.
    -- Active = gold outline + gold label; idle = a hairline outline + a muted label.
    if S.showSub then
        for s = 1, #sections do
            local r = lay.subRects[s]
            local active = s == S.sub
            addRectBorder(active and ACCENT or SEP_COLOR, r.x, r.y, r.w, L.tabH)
            addText(r.name, r.x, r.y + TAB_TEXT_DY, r.w, FONT, 1, active and ACCENT or INK1)
        end
    end

    S.vals, S.bars, S.selHi, S.selEdge = {}, {}, nil, nil
    if #items == 0 then
        addText(tabCount() == 0 and "(no mods registered yet)" or "(no settings)", cols.nameX, lay.rowTop + ROW_TEXT_DY, 320, FONT, nil, INK1)
    else
        local off, vis = S.off, lay.visible
        -- selected-row highlight + gold left edge: drawn once behind the rows, repositioned on nav
        local sy = lay.rowTop + (S.sel - off - 1) * L.rowH
        S.selHi   = addBox(SEL_BG, L.panelX + L.pad - 4, sy, lay.panelW - 2 * (L.pad - 4), L.rowH)
        S.selEdge = addBox(ACCENT, L.panelX + 4, sy, 3, L.rowH)
        for row = 1, vis do
            local i = off + row
            local it = items[i]; if not it then break end
            local y = lay.rowTop + (row - 1) * L.rowH
            local ty = y + ROW_TEXT_DY  -- row text, centered against the slider track
            addText(VM.ellipsize(it.name, cols.nameChars), cols.nameX, ty, cols.nameW, FONT, nil, INK0)
            if it.kind == "num" then
                addText("[-]", cols.decX, ty, cols.colW, FONT, nil, INK1)
                if hasBar(it) then
                    -- center the track on the text line: 2px below the geometric row center, tuned
                    -- from screenshots (the engine renders the label a hair below dead center).
                    local by = y + math.floor((L.rowH - L.barH) / 2) + 2
                    addBox(SLIDER_TRACK, cols.barX, by, cols.barW, L.barH)
                    S.bars[row] = addBox(ACCENT, cols.barX, by, barFrac(it) * cols.barW, L.barH)
                end
                addText("[+]", cols.incX, ty, cols.colW, FONT, nil, INK1)
                S.vals[row] = addText(tostring(it.value), cols.valX, ty, cols.valW, FONT, nil, INK0)
            else
                S.vals[row] = addText(valText(it), cols.decX, ty, cols.toggleW + 24, FONT, nil, INK0)
            end
            if it.desc and it.desc ~= "" then
                addText(VM.ellipsize(it.desc, cols.descChars), cols.descX, ty, cols.descW, FONT, nil, INK1)
            end
        end
        if lay.paging then
            local y = lay.rowTop + vis * L.rowH + ROW_TEXT_DY
            addText("[ ^ ]", L.markX, y, 30, FONT, nil, INK1)
            addText("[ v ]", L.markX + 34, y, 30, FONT, nil, INK1)
            -- floor the args: Lua 5.4's %d throws on a non-integer (LuaJIT silently truncated)
            local first, last = math.floor(off + 1), math.floor(math.min(off + vis, #items))
            addText(string.format("%d-%d of %d", first, last, #items), L.markX + 74, y, 200, 10, nil, INK2)
        end
    end

    pcall(function() widget:AddToViewport(50) end)
    S.widget = widget
    return true
end

-- ------------------------------------------------------- widget lifecycle --
-- BUILD ONCE; detach/re-attach on toggle (RemoveFromParent removes the window but keeps the
-- widget, so AddToViewport re-shows it with no rebuild). DESTROY only to rebuild.
local function removeFromViewport()
    if not isValid(S.widget) then return end
    if not pcall(function() S.widget:RemoveFromParent() end) then pcall(function() S.widget:RemoveFromViewport() end) end
end
local function destroyWidget() removeFromViewport(); S.widget = nil; S.sig = nil end
local function showWidget(on)
    if not isValid(S.widget) then return end
    if on then pcall(function() S.widget:AddToViewport(50) end) else removeFromViewport() end
end
local function resetState() S.open = false; S.widget = nil; S.sig = nil; S.pc = nil; S.priorCursor = nil; S.selHi = nil; S.selEdge = nil end

local function readCursor(pc)
    local v; pcall(function() v = pc.bShowMouseCursor end)
    return v == true
end

-- Opening forces the cursor on and routes input to the UI. On close we must hand control back
-- correctly. If a game menu (inventory, pause, ...) still owns the cursor, forcing GameOnly +
-- cursor-off strips it from that menu. But if we opened over a game menu the player has SINCE closed
-- (back to gameplay while our menu stayed open), keeping the cursor on leaves it stuck with input on
-- a dead UI focus, which deadlocks. So we snapshot the cursor at open AND re-read it live: keep it
-- only if it was owned at open and is STILL on at close. We are event-driven, not a per-tick force,
-- so once the game reclaims the cursor (sets it off) that read is the game's real intent; the open
-- snapshot is downgraded as soon as we see that, in case a rebuild re-forces the cursor on after.
local function setUIInput(on)
    local pc, lib = getPC(), wlib()
    if not (isValid(pc) and isValid(lib)) then return end
    if on then
        local cur = readCursor(pc)
        if S.priorCursor == nil then S.priorCursor = cur            -- first open: did a game menu own it?
        elseif S.priorCursor and not cur then S.priorCursor = false end  -- game reclaimed gameplay since
        pcall(function() pc.bShowMouseCursor = true end)
        pcall(function() lib:SetInputMode_UIOnlyEx(pc, S.widget, 0, true) end)
    else
        local keepCursor = S.priorCursor and readCursor(pc)  -- a game menu owned it at open AND still does
        S.priorCursor = nil
        if keepCursor then
            -- leave the cursor visible and input on UI, so the game does not eat keys/look behind that menu
            pcall(function() lib:SetInputMode_UIOnlyEx(pc, nil, 0, true) end)
            pcall(function() pc.bShowMouseCursor = true end)
        else  -- plain gameplay (or the game menu is gone): hand control fully back to the game
            pcall(function() pc.bShowMouseCursor = false end)
            pcall(function() lib:SetInputMode_GameOnly(pc, true) end)
        end
    end
end

local function setText(tb, s)
    if not isValid(tb) then return end
    local ft = toText(s); if ft ~= nil then pcall(function() tb:SetText(ft) end) end
end

-- resize a slider's gold fill to the item's current value (the reuse path's equivalent of redraw)
local function setBarFill(row, it)
    local slot = S.bars and S.bars[row]
    local cols = S.lay and S.lay.cols
    if slot and cols then pcall(function() slot:SetSize({ X = barFrac(it) * cols.barW, Y = L.barH }) end) end
end
-- move the selection highlight + gold edge to the currently selected row (no rebuild)
local function moveSelection()
    local sy = (S.lay and S.lay.rowTop or 0) + (S.sel - (S.off or 0) - 1) * L.rowH
    if S.selHi   then pcall(function() S.selHi:SetPosition({ X = L.panelX + L.pad - 4, Y = sy }) end) end
    if S.selEdge then pcall(function() S.selEdge:SetPosition({ X = L.panelX + 4, Y = sy }) end) end
end

-- the cached widget is reused only while this is unchanged; a registration / mod / sub-tab change
-- forces one rebuild.
local function computeSig()
    -- Capture everything that changes the drawn frame or the layout, so the reuse path fires only
    -- for pure value updates (syncRows handles those). Values are excluded; tab/sub names, item
    -- kinds and item names are included, since they drive widths, controls and hit zones. The
    -- per-item detail is only walked for the CURRENT mod (the only one whose rows are drawn).
    local sig = "t" .. S.tab .. "s" .. S.sub
    for _, m in ipairs(S.tabs or {}) do sig = sig .. "|" .. tostring(m.name) .. ":" .. #m.sections end
    local m = S.tabs and S.tabs[S.tab]
    if m then
        for _, sec in ipairs(m.sections) do
            sig = sig .. "/" .. tostring(sec.title) .. ":" .. #sec.items
            for _, it in ipairs(sec.items) do sig = sig .. "~" .. tostring(it.kind) .. tostring(it.name) .. "#" .. tostring(it.desc) end
        end
    end
    return sig
end
local function syncRows() -- refresh the visible window's values + slider fills in place (reuse path)
    local items, off = curItems(), S.off or 0
    local vis = (S.lay and S.lay.visible) or #items
    for row = 1, vis do
        local i = off + row
        local it = items[i]
        if it then
            if S.vals[row] then setText(S.vals[row], valText(it)) end
            setBarFill(row, it)
        end
    end
    moveSelection()
end

-- mods arrive in registration order (nondeterministic across isolated mod states), so show the
-- tabs alphabetically for a stable order. Sub-page order is left as the owning mod defined it.
local function readTabs()
    S.tabs = (menu and menu.readAll()) or {}
    table.sort(S.tabs, function(a, b) return string.lower(tostring(a.name)) < string.lower(tostring(b.name)) end)
end
local function clampNav()
    S.tab = tabCount() == 0 and 1 or math.max(1, math.min(S.tab, tabCount()))
    S.sub = subCount() == 0 and 1 or math.max(1, math.min(S.sub, subCount()))
    local n = #curItems(); S.sel = n == 0 and 1 or math.max(1, math.min(S.sel, n))
end

local function closeMenu()
    S.open = false; showWidget(false); setUIInput(false)
end
local function rebuild() destroyWidget(); clampNav(); if build() then S.sig = computeSig(); setUIInput(true) end end
local function openMenu()
    readTabs(); S.open = true; clampNav()
    local sig = computeSig()
    if isValid(S.widget) and S.sig == sig then syncRows(); showWidget(true)
    else destroyWidget(); if not build() then S.open = false; return end S.sig = sig end
    setUIInput(true)
end
local function toggle() if S.open then closeMenu() else openMenu() end end

-- ------------------------------------------------------------ navigation --
local function rowOf(i) return i - (S.off or 0) end  -- screen row of item i within the window

local function showSelection(newSel)
    if not S.open then return end
    local n = #curItems(); if n == 0 then return end
    newSel = clamp(newSel, 1, n)
    if newSel == S.sel then return end
    local vis, off = (S.lay and S.lay.visible) or n, S.off or 0
    if newSel < off + 1 or newSel > off + vis then  -- off the window: scroll, then redraw the rows
        S.sel = newSel; rebuild(); return
    end
    S.sel = newSel
    moveSelection()
end
local function showValue(i)
    local it = curItems()[i]; if not it then return end
    local row = rowOf(i)
    if S.vals[row] then setText(S.vals[row], valText(it)) end
    setBarFill(row, it)
end
local function navItem(d) showSelection(S.sel + d) end
local function navSub(d) if S.open and subCount() > 0 then S.sub = clamp(S.sub + d, 1, subCount()); S.sel = 1; S.off = 0; rebuild() end end
local function navTab(d) if S.open and tabCount() > 0 then S.tab = clamp(S.tab + d, 1, tabCount()); S.sub = 1; S.sel = 1; S.off = 0; rebuild() end end
local function adjust(d) if S.open then local it = curItems()[S.sel]; if it then editItem(it, d); showValue(S.sel) end end end
-- run the selected action / flip the selected switch: the keyboard equivalent of clicking [ RUN ]
-- or [ ON/OFF ]. A num row has no single "activate", so it is left to the value keys.
local function activate()
    if not S.open then return end
    local it = curItems()[S.sel]; if not it then return end
    if it.kind == "action" or it.kind == "bool" then editItem(it, 1); showValue(S.sel) end
end

-- ----------------------------------------------------------------- mouse --
local function mousePos()
    local pc, lib = getPC(), wll()
    if not (isValid(pc) and isValid(lib)) then return nil end
    local v; pcall(function() v = lib:GetMousePositionOnViewport(pc) end)
    if v == nil then return nil end
    local px, py; pcall(function() px = v.X end); pcall(function() py = v.Y end)
    if px and py then return px, py end
end
local function onLMB()
    if not S.open or not S.lay then return end
    local px, py = mousePos(); if not px then return end
    local items, off = curItems(), S.off or 0
    local vis = S.lay.visible or #items
    local window = {}  -- the rows currently drawn; hitZone returns a window-relative index
    for row = 1, math.min(vis, #items - off) do window[row] = items[off + row] end
    local z = VM.hitZone(px, py, {
        tabCount = tabCount(), subCount = subCount(), showSub = S.showSub, items = window, lay = S.lay,
    })
    if not z then return end
    if z.zone == "close" then closeMenu()
    elseif z.zone == "modtab" then if z.index ~= S.tab then S.tab = z.index; S.sub = 1; S.sel = 1; S.off = 0; rebuild() end
    elseif z.zone == "subtab" then if z.index ~= S.sub then S.sub = z.index; S.sel = 1; S.off = 0; rebuild() end
    elseif z.zone == "scroll" then
        local newOff = VM.pageOffset(S.off or 0, z.dir, vis, #items)
        if newOff ~= (S.off or 0) then S.off = newOff; S.sel = newOff + 1; rebuild() end
    elseif z.zone == "item" then
        local i = off + z.index
        local it = items[i]; if not it then return end
        showSelection(i)
        if z.part == "toggle" or z.part == "inc" then editItem(it, 1); showValue(i)
        elseif z.part == "dec" then editItem(it, -1); showValue(i)
        elseif z.part == "bar" then setItemFromBar(it, px); showValue(i) end
    end
end

return {
    toggle = toggle, onLMB = onLMB, navItem = navItem, navSub = navSub,
    navTab = navTab, adjust = adjust, activate = activate, close = closeMenu, resetState = resetState,
}
