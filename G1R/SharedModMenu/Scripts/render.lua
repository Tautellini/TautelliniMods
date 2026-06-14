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

local print, ipairs, tostring, tonumber, type, string, pcall, math =
      print, ipairs, tostring, tonumber, type, string, pcall, math
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
if not S then S = { open = false, tab = 1, sub = 1, sel = 1 }; rawset(_G, "__smmState", S) end

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

local FONT, BAR_CHARS = 11, 12
-- num row columns, laid out so the [-]/bar/[+] click zones never overlap (gaps between each):
--   [-] 234..258 | bar 266..378 | value 390..436 | [+] 446..470
local L = {
    panelX = 50, panelY = 58, panelW = 440,
    closeW = 40, closeH = 18, closeY = 60,
    modTabY = 68, subTabY = 92, tabH = 20, tabX0 = 60, tabStep = 98, tabW = 92,
    rowH = 22, markX = 60, nameX = 78, nameW = 150,
    decX = 234, barX = 266, barW = 112, valX = 390, valW = 46, incX = 446, colW = 24,
}
L.closeX = L.panelX + L.panelW - L.closeW - 2

-- ----------------------------------------------------------- data access --
local function curMod() return S.tabs and S.tabs[S.tab] end
local function curSections() local m = curMod(); return m and m.sections or {} end
local function curItems() local s = curSections()[S.sub]; return s and s.items or {} end
local function modName() local m = curMod(); return m and m.name end
local function tabCount() return S.tabs and #S.tabs or 0 end
local function subCount() return #curSections() end
local function clamp(n, lo, hi) if n < lo then return hi elseif n > hi then return lo else return n end end

local function hasBar(it) return it.kind == "num" and it.min and it.max end
local function barString(it)
    local lo, hi = it.min or 0, it.max or 1
    local frac = (hi > lo) and (((tonumber(it.value) or 0) - lo) / (hi - lo)) or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local filled = math.floor(frac * BAR_CHARS + 0.5)
    return "|" .. string.rep("#", filled) .. string.rep("-", BAR_CHARS - filled) .. "|"
end
local function valText(it)
    if it.kind == "bool" then return it.value and "[ ON ]" or "[ OFF ]" end
    if it.kind == "action" then return "[ RUN ]" end
    return tostring(it.value)
end

-- send an edit to the owning mod and reflect it locally at once
local function editItem(it, d)
    if not menu then return end
    if it.kind == "bool" then
        it.value = not it.value
    elseif it.kind == "num" then
        local v = (tonumber(it.value) or 0) + d * (it.step or 1)
        if it.min and v < it.min then v = it.min elseif it.max and v > it.max then v = it.max end
        it.value = v
    elseif it.kind ~= "action" then
        return
    end
    menu.sendEdit(modName(), it.flat, it.kind, it.value)
end
local function setItemFromBar(it, px)
    local lo, hi = it.min or 0, it.max or 1
    local frac = (px - L.barX) / L.barW
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local v = lo + frac * (hi - lo)
    if it.step and it.step > 0 then v = lo + math.floor((v - lo) / it.step + 0.5) * it.step end
    if v < lo then v = lo elseif v > hi then v = hi end
    it.value = v
    if menu then menu.sendEdit(modName(), it.flat, "num", v) end
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

    local sections, items = curSections(), curItems()
    S.showSub = #sections > 1 or (sections[1] and sections[1].title ~= nil) or false
    S.rowTop = S.showSub and (L.subTabY + L.tabH + 6) or (L.modTabY + L.tabH + 6)
    local rows = math.max(1, #items)
    local panelH = (S.rowTop - L.panelY) + rows * L.rowH + 14

    local bg = make(brC)
    if isValid(bg) then
        pcall(function() bg:SetBrushColor({ R = 0.06, G = 0.06, B = 0.07, A = 1.0 }) end)
        local slot = try(function() return canvas:AddChildToCanvas(bg) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetPosition({ X = L.panelX, Y = L.panelY }); slot:SetSize({ X = L.panelW, Y = panelH }) end) end
    end

    addText("[X]", L.closeX, L.closeY, L.closeW, FONT, 2)
    for t = 1, tabCount() do
        local n = S.tabs[t].name
        addText(t == S.tab and ("[" .. n .. "]") or (" " .. n .. " "), L.tabX0 + (t - 1) * L.tabStep, L.modTabY, L.tabW)
    end
    if S.showSub then
        for s = 1, #sections do
            local n = sections[s].title or "Main"
            addText(s == S.sub and ("[" .. n .. "]") or (" " .. n .. " "), L.tabX0 + (s - 1) * L.tabStep, L.subTabY, L.tabW)
        end
    end

    S.marks, S.vals, S.bars = {}, {}, {}
    if #items == 0 then
        addText(tabCount() == 0 and "(no mods registered yet)" or "(no settings)", L.nameX, S.rowTop, 320)
    else
        for i = 1, #items do
            local it, y = items[i], S.rowTop + (i - 1) * L.rowH
            S.marks[i] = addText(i == S.sel and ">" or "", L.markX, y, 14)
            addText(tostring(it.name), L.nameX, y, L.nameW)
            if it.kind == "num" then
                addText("[-]", L.decX, y, L.colW)
                if hasBar(it) then S.bars[i] = addText(barString(it), L.barX, y, L.barW) end
                S.vals[i] = addText(tostring(it.value), L.valX, y, L.valW)
                addText("[+]", L.incX, y, L.colW)
            else
                S.vals[i] = addText(valText(it), L.decX, y, 150)
            end
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
    local sig = "t" .. S.tab .. "s" .. S.sub
    for _, m in ipairs(S.tabs or {}) do
        sig = sig .. "|" .. tostring(m.name) .. ":" .. #m.sections
        for _, sec in ipairs(m.sections) do sig = sig .. "/" .. #sec.items end
    end
    return sig
end
local function syncRows() -- refresh markers + values in place (reuse path)
    for i, it in ipairs(curItems()) do
        if S.marks[i] then setText(S.marks[i], i == S.sel and ">" or "") end
        if S.vals[i] then setText(S.vals[i], valText(it)) end
        if S.bars and S.bars[i] then setText(S.bars[i], barString(it)) end
    end
end

local function readTabs() S.tabs = (menu and menu.readAll()) or {} end
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
local function showSelection(newSel)
    if not S.open then return end
    local n = #curItems(); if n == 0 then return end
    newSel = clamp(newSel, 1, n)
    if newSel == S.sel then return end
    if S.marks[S.sel] then setText(S.marks[S.sel], "") end
    S.sel = newSel
    if S.marks[S.sel] then setText(S.marks[S.sel], ">") end
end
local function showValue(i)
    local it = curItems()[i]; if not it then return end
    if S.vals[i] then setText(S.vals[i], valText(it)) end
    if S.bars and S.bars[i] then setText(S.bars[i], barString(it)) end
end
local function navItem(d) showSelection(S.sel + d) end
local function navSub(d) if S.open and subCount() > 0 then S.sub = clamp(S.sub + d, 1, subCount()); S.sel = 1; rebuild() end end
local function navTab(d) if S.open and tabCount() > 0 then S.tab = clamp(S.tab + d, 1, tabCount()); S.sub = 1; S.sel = 1; rebuild() end end
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
local function hitTabRow(px, py, y, count, get)
    if py < y or py > y + L.tabH then return nil end
    for i = 1, count do
        local x0 = L.tabX0 + (i - 1) * L.tabStep
        if px >= x0 and px <= x0 + L.tabW then return i end
    end
end
local function onLMB()
    if not S.open then return end
    local px, py = mousePos(); if not px then return end
    if px >= L.closeX - 4 and px <= L.closeX + L.closeW and py >= L.closeY - 2 and py <= L.closeY + L.closeH then closeMenu(); return end
    local mt = hitTabRow(px, py, L.modTabY, tabCount())
    if mt then if mt ~= S.tab then S.tab = mt; S.sub = 1; S.sel = 1; rebuild() end return end
    if S.showSub then
        local st = hitTabRow(px, py, L.subTabY, subCount())
        if st then if st ~= S.sub then S.sub = st; S.sel = 1; rebuild() end return end
    end
    local items = curItems()
    local idx = math.floor((py - S.rowTop) / L.rowH) + 1
    if px < L.panelX or px > L.panelX + L.panelW or idx < 1 or idx > #items then return end
    showSelection(idx)
    local it = items[idx]
    if it.kind == "bool" or it.kind == "action" then
        if px >= L.decX - 6 and px <= L.decX + 150 then editItem(it, 1); showValue(idx) end
    elseif it.kind == "num" then
        if px >= L.decX - 6 and px <= L.decX + L.colW then editItem(it, -1); showValue(idx)
        elseif px >= L.incX - 6 and px <= L.incX + L.colW then editItem(it, 1); showValue(idx)
        elseif hasBar(it) and px >= L.barX and px <= L.barX + L.barW then setItemFromBar(it, px); showValue(idx) end
    end
end

return {
    toggle = toggle, onLMB = onLMB, navItem = navItem, navSub = navSub,
    navTab = navTab, adjust = adjust, close = closeMenu, resetState = resetState,
}
