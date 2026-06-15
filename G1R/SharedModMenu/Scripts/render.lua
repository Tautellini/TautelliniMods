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
local FONT = 11
-- premium-dark surface: a near-black, slightly translucent panel, with faint dividers between the
-- mod-tab row, the sub-page row, and the field list.
local PANEL_BG  = { R = 0.02, G = 0.02, B = 0.03, A = 0.90 }
local SEP_COLOR = { R = 0.35, G = 0.35, B = 0.42, A = 0.70 }
local TAB_BG    = { R = 0.10, G = 0.10, B = 0.13, A = 0.92 }  -- a mod / section tab button (idle)
local TAB_SEL   = { R = 0.24, G = 0.30, B = 0.40, A = 0.96 }  -- the active mod / section tab button

-- ----------------------------------------------------------- data access --
local function curMod() return S.tabs and S.tabs[S.tab] end
local function curSections() local m = curMod(); return m and m.sections or {} end
local function curItems() local s = curSections()[S.sub]; return s and s.items or {} end
local function modName() local m = curMod(); return m and m.name end
local function tabCount() return S.tabs and #S.tabs or 0 end
local function subCount() return #curSections() end
local clamp, hasBar, barString, valText = VM.clampWrap, VM.hasBar, VM.barString, VM.valText

-- send an edit to the owning mod and reflect it locally at once
local function editItem(it, d)
    if not menu then return end
    if it.kind == "bool" then it.value = not it.value
    elseif it.kind == "num" then it.value = VM.stepValue(it, d)
    elseif it.kind ~= "action" then return end
    menu.sendEdit(modName(), it.flat, it.kind, it.value)
end
local function setItemFromBar(it, px)
    it.value = VM.valueFromBar(it, px)
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
    local function addText(t, x, y, w, size, justify)
        local tb = make(tbC); if not isValid(tb) then return nil end
        local ft = toText(t); if ft ~= nil then pcall(function() tb:SetText(ft) end) end
        local slot = try(function() return canvas:AddChildToCanvas(tb) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = w, Y = L.rowH }) end) end
        pcall(function() local f = tb.Font; f.Size = size or FONT; tb:SetFont(f) end)
        if justify then pcall(function() tb:SetJustification(justify) end) end
        return tb
    end
    local function addLine(x, y, w)  -- a thin horizontal divider (a 1px-tall Border)
        local ln = make(brC); if not isValid(ln) then return end
        pcall(function() ln:SetBrushColor(SEP_COLOR) end)
        local slot = try(function() return canvas:AddChildToCanvas(ln) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = w, Y = 1 }) end) end
    end
    local function addButton(r, selected)  -- a filled box behind a tab label
        local b = make(brC); if not isValid(b) then return end
        pcall(function() b:SetBrushColor(selected and TAB_SEL or TAB_BG) end)
        local slot = try(function() return canvas:AddChildToCanvas(b) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetPosition({ X = r.x, Y = r.y }); slot:SetSize({ X = r.w, Y = L.tabH }) end) end
    end

    local sections, items = curSections(), curItems()
    S.showSub = #sections > 1 or (sections[1] and sections[1].title ~= nil) or false
    local modNames = {}
    for t = 1, tabCount() do modNames[t] = S.tabs[t].name end
    local subNames = {}
    if S.showSub then for s = 1, #sections do subNames[s] = sections[s].title or "Main" end end
    local lay = VM.layout({ modNames = modNames, subNames = subNames, showSub = S.showSub, itemCount = #items })
    S.lay = lay
    S.off = VM.scrollOffset(S.sel, S.off or 0, lay.visible, #items)  -- keep the selection in view

    local bg = make(brC)
    if isValid(bg) then
        pcall(function() bg:SetBrushColor(PANEL_BG) end)
        local slot = try(function() return canvas:AddChildToCanvas(bg) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetPosition({ X = L.panelX, Y = L.panelY }); slot:SetSize({ X = lay.panelW, Y = lay.panelH }) end) end
    end

    -- dividers: one between the mod-tab row and the sub-page row (when sub-pages exist), one below
    -- the whole selector area, each centered in the gap the layout reserves (subGap / rowGap).
    local lineX, lineW = L.panelX + 6, lay.panelW - 12
    if S.showSub then addLine(lineX, (lay.subTabY - L.subGap) + math.floor(L.subGap / 2), lineW) end
    addLine(lineX, (lay.rowTop - L.rowGap) + math.floor(L.rowGap / 2), lineW)

    addText("[X]", lay.closeX, L.closeY, L.closeW, FONT, 2)
    for t = 1, tabCount() do
        local r = lay.modRects[t]
        addButton(r, t == S.tab)
        addText(r.name, r.x, r.y + 2, r.w, FONT, 1)  -- centered label on the button
    end
    if S.showSub then
        for s = 1, #sections do
            local r = lay.subRects[s]
            addButton(r, s == S.sub)
            addText(r.name, r.x, r.y + 2, r.w, FONT, 1)
        end
    end

    S.marks, S.vals, S.bars = {}, {}, {}
    if #items == 0 then
        addText(tabCount() == 0 and "(no mods registered yet)" or "(no settings)", L.nameX, lay.rowTop, 320)
    else
        local off, vis = S.off, lay.visible
        for row = 1, vis do
            local i = off + row
            local it = items[i]; if not it then break end
            local y = lay.rowTop + (row - 1) * L.rowH
            S.marks[row] = addText(i == S.sel and ">" or "", L.markX, y, 14)
            addText(VM.ellipsize(it.name, L.itemNameMax), L.nameX, y, L.nameW)
            if it.kind == "num" then
                addText("[-]", L.decX, y, L.colW)
                if hasBar(it) then S.bars[row] = addText(barString(it), L.barX, y, L.barW) end
                S.vals[row] = addText(tostring(it.value), L.valX, y, L.valW)
                addText("[+]", L.incX, y, L.colW)
            else
                S.vals[row] = addText(valText(it), L.decX, y, 150)
            end
        end
        if lay.paging then
            local y = lay.rowTop + vis * L.rowH
            addText("[ ^ ]", L.markX, y, 30)
            addText("[ v ]", L.markX + 34, y, 30)
            -- floor the args: Lua 5.4's %d throws on a non-integer (LuaJIT silently truncated)
            local first, last = math.floor(off + 1), math.floor(math.min(off + vis, #items))
            addText(string.format("%d-%d of %d", first, last, #items), L.markX + 74, y, 200, 9)
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
local function resetState() S.open = false; S.widget = nil; S.sig = nil; S.pc = nil end

local function setUIInput(on)
    local pc, lib = getPC(), wlib()
    if not (isValid(pc) and isValid(lib)) then return end
    pcall(function() pc.bShowMouseCursor = on end)
    if on then pcall(function() lib:SetInputMode_UIOnlyEx(pc, S.widget, 0, true) end)
    else pcall(function() lib:SetInputMode_GameOnly(pc, true) end) end
end

local function setText(tb, s)
    if not isValid(tb) then return end
    local ft = toText(s); if ft ~= nil then pcall(function() tb:SetText(ft) end) end
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
            for _, it in ipairs(sec.items) do sig = sig .. "~" .. tostring(it.kind) .. tostring(it.name) end
        end
    end
    return sig
end
local function syncRows() -- refresh the visible window's markers + values in place (reuse path)
    local items, off = curItems(), S.off or 0
    local vis = (S.lay and S.lay.visible) or #items
    for row = 1, vis do
        local i = off + row
        local it = items[i]
        if it then
            if S.marks[row] then setText(S.marks[row], i == S.sel and ">" or "") end
            if S.vals[row] then setText(S.vals[row], valText(it)) end
            if S.bars and S.bars[row] then setText(S.bars[row], barString(it)) end
        end
    end
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
    if S.marks[rowOf(S.sel)] then setText(S.marks[rowOf(S.sel)], "") end
    S.sel = newSel
    if S.marks[rowOf(S.sel)] then setText(S.marks[rowOf(S.sel)], ">") end
end
local function showValue(i)
    local it = curItems()[i]; if not it then return end
    local row = rowOf(i)
    if S.vals[row] then setText(S.vals[row], valText(it)) end
    if S.bars and S.bars[row] then setText(S.bars[row], barString(it)) end
end
local function navItem(d) showSelection(S.sel + d) end
local function navSub(d) if S.open and subCount() > 0 then S.sub = clamp(S.sub + d, 1, subCount()); S.sel = 1; S.off = 0; rebuild() end end
local function navTab(d) if S.open and tabCount() > 0 then S.tab = clamp(S.tab + d, 1, tabCount()); S.sub = 1; S.sel = 1; S.off = 0; rebuild() end end
local function adjust(d) if S.open then local it = curItems()[S.sel]; if it then editItem(it, d); showValue(S.sel) end end end

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
    navTab = navTab, adjust = adjust, close = closeMenu, resetState = resetState,
}
