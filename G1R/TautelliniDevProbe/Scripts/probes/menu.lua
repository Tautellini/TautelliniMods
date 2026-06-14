-- probes/menu.lua  --  P3 tuner menu: tabbed, compact, mouse + numpad, Lua-only UMG.
-- Input on this build = numpad + MOUSE polling (keybinds give only F-keys/numpad/mouse;
-- OnClicked:Add crashes). Rows are explicit per-column widgets so click zones match the
-- glyphs. Font is shrunk via read-modify SetFont (forensic-logged, struct-marshal risk).
--   F2 toggle (+cursor). Tabs: click, or numpad 7/9 prev/next. Numpad 8/2 select,
--   4/6 change. CLICK a tab to switch, a row to select, [-]/[+] or [ON/OFF] to change.

local ipairs, tostring, string, pcall, math = ipairs, tostring, string, pcall, math

return function(ctx)
    local log = ctx.makeLog("menu")
    local isValid, try, guard = ctx.isValid, ctx.try, ctx.guard
    local firstLive = ctx.firstLive
    local SFO, SCO = ctx.StaticFindObject, ctx.StaticConstructObject

    local function cls(path) return try(function() return SFO(path) end) end
    local function getPC() return firstLive("GothicPlayerController") or firstLive("PlayerController") end
    local function wlib() return cls("/Script/UMG.Default__WidgetBlueprintLibrary") end
    local function wll()  return cls("/Script/UMG.Default__WidgetLayoutLibrary") end

    local function toText(s)
        local kt = cls("/Script/Engine.Default__KismetTextLibrary")
        if not isValid(kt) then return nil end
        return try(function() return kt:Conv_StringToText(s) end)
    end

    local FONT = 11
    local L = { panelX = 50, panelY = 60, panelW = 410,
                closeY = 62, closeW = 40, closeH = 18,
                tabY = 70, tabH = 20, tabX0 = 60, tabStep = 92, tabW = 86,
                rowY0 = 100, rowH = 22,
                markX = 60, nameX = 78, decX = 250, valX = 300, incX = 350, colW = 40 }
    -- anchor the close button to the panel's right edge (not a magic number)
    L.closeX = L.panelX + L.panelW - L.closeW - 2

    local tabs = {
        { name = "Player", items = {
            { name = "God Mode",   kind = "bool", val = false },
            { name = "Dexterity",  kind = "num", val = 18,  step = 1,   min = 0,   max = 100 },
            { name = "Strength",   kind = "num", val = 10,  step = 1,   min = 0,   max = 100 },
            { name = "Move Speed", kind = "num", val = 1.0, step = 0.1, min = 0.1, max = 5 },
        } },
        { name = "Combat", items = {
            { name = "Damage Mult", kind = "num", val = 1.0, step = 0.1, min = 0, max = 10 },
            { name = "Invulnerable", kind = "bool", val = false },
        } },
        { name = "World", items = {
            { name = "Time (h)", kind = "num", val = 12, step = 1, min = 0, max = 23 },
            { name = "Weather",  kind = "num", val = 0,  step = 1, min = 0, max = 5 },
        } },
        { name = "Lockpick", items = {
            { name = "Tries",      kind = "num", val = 4, step = 1, min = 1, max = 99 },
            { name = "Auto-Solve", kind = "bool", val = false },
        } },
    }
    local M = { open = false, tab = 1, sel = 1, widget = nil }
    local function curItems() return tabs[M.tab].items end
    local function clampSel() local n = #curItems(); if M.sel < 1 then M.sel = n elseif M.sel > n then M.sel = 1 end end
    local function clampNum(it)
        if it.min and it.val < it.min then it.val = it.min end
        if it.max and it.val > it.max then it.val = it.max end
        it.val = math.floor(it.val * 100 + 0.5) / 100
    end

    local function build()
        local pc = getPC(); if not isValid(pc) then log("no PlayerController (be in-game)"); return false end
        local lib = wlib()
        local uwC, cpC, brC, tbC = cls("/Script/UMG.UserWidget"), cls("/Script/UMG.CanvasPanel"),
            cls("/Script/UMG.Border"), cls("/Script/UMG.TextBlock")
        if not (isValid(lib) and isValid(uwC) and isValid(cpC) and isValid(brC) and isValid(tbC)) then
            log("missing a UMG class/lib"); return false
        end
        local widget = try(function() return lib:Create(pc, uwC, pc) end)
        if not isValid(widget) then log("Create failed"); return false end
        local tree = guard(widget, function(w) return w.WidgetTree end)
        if not isValid(tree) then log("no WidgetTree"); return false end
        local function make(c) return try(function() return SCO(c, tree) end) end

        local canvas = make(cpC); if not isValid(canvas) then log("no CanvasPanel"); return false end
        pcall(function() tree.RootWidget = canvas end)
        local function place(w, x, y, sx, sy)
            local s = try(function() return canvas:AddChildToCanvas(w) end)
            if s then pcall(function() s:SetAutoSize(false); s:SetPosition({ X = x, Y = y }); s:SetSize({ X = sx, Y = sy }) end) end
        end
        local fontLogged = false
        local function addText(t, x, y, w, size)
            local tb = make(tbC)
            if isValid(tb) then
                local ft = toText(t); if ft ~= nil then pcall(function() tb:SetText(ft) end) end
                place(tb, x, y, w, L.rowH)
                if not fontLogged then fontLogged = true; log("[font] ABOUT TO SetFont") end
                pcall(function() local f = tb.Font; f.Size = size or FONT; tb:SetFont(f) end)
            end
            return tb
        end

        local items = curItems()
        local panelH = (L.rowY0 - L.panelY) + #items * L.rowH + 30
        local bg = make(brC)
        if isValid(bg) then pcall(function() bg:SetBrushColor({ R = 0.06, G = 0.06, B = 0.07, A = 1.0 }) end); place(bg, L.panelX, L.panelY, L.panelW, panelH) end

        local xbtn = addText("[X]", L.closeX, L.closeY, L.closeW)
        pcall(function() xbtn:SetJustification(2) end)  -- right-align into the corner
        -- tab bar
        for t = 1, #tabs do
            local label = (t == M.tab) and ("[" .. tabs[t].name .. "]") or (" " .. tabs[t].name .. " ")
            addText(label, L.tabX0 + (t - 1) * L.tabStep, L.tabY, L.tabW)
        end
        -- items of the current tab
        for i = 1, #items do
            local it = items[i]
            local y = L.rowY0 + (i - 1) * L.rowH
            addText((i == M.sel) and ">" or "", L.markX, y, 14)
            addText(it.name, L.nameX, y, 170)
            if it.kind == "bool" then
                addText(it.val and "[ ON ]" or "[ OFF ]", L.decX, y, 150)
            else
                addText("[-]", L.decX, y, L.colW)
                addText(tostring(it.val), L.valX, y, L.colW)
                addText("[+]", L.incX, y, L.colW)
            end
        end
        addText("[-]/[+] or [ON/OFF] change   -   click row to select   -   F2 close",
            L.nameX, L.rowY0 + #items * L.rowH + 6, 400, 8)

        pcall(function() widget:AddToViewport(50) end)
        M.widget = widget
        return true
    end

    local function close()
        if isValid(M.widget) then
            if not pcall(function() M.widget:RemoveFromParent() end) then pcall(function() M.widget:RemoveFromViewport() end) end
        end
        M.widget = nil
    end

    -- show the cursor + stop the game from eating mouse-look/movement while open
    -- (SetInputMode_*Ex errored on this build; these per-PC ignore flags work)
    -- this build's SetInputMode_* take an extra bFlushInput param (UE5.x):
    --   UIOnlyEx(PC, WidgetToFocus, MouseLockMode, bFlushInput)
    --   GameOnly(PC, bFlushInput)
    local function setUIInput(on)
        local pc = getPC(); if not isValid(pc) then return end
        local lib = wlib(); if not isValid(lib) then return end
        pcall(function() pc.bShowMouseCursor = on end)
        local ok, err
        if on then ok, err = pcall(function() lib:SetInputMode_UIOnlyEx(pc, M.widget, 0, true) end)
        else ok, err = pcall(function() lib:SetInputMode_GameOnly(pc, true) end) end
        log("setUIInput(" .. tostring(on) .. ") inputMode ok=" .. tostring(ok) .. " err=" .. tostring(err))
    end
    local function closeMenu() M.open = false; close(); setUIInput(false); log("menu closed") end
    local function openMenu()
        M.open = true
        if build() then setUIInput(true); log("menu open") else M.open = false; log("build FAILED") end
    end
    local function toggle() if M.open then closeMenu() else openMenu() end end
    local function refresh() if M.open then close(); build() end end

    local function navItem(d) if not M.open then return end M.sel = M.sel + d; clampSel(); refresh() end
    local function navTab(d) if not M.open then return end M.tab = ((M.tab - 1 + d) % #tabs) + 1; M.sel = 1; refresh() end
    local function adjust(d)
        if not M.open then return end
        local it = curItems()[M.sel]; if not it then return end
        if it.kind == "bool" then it.val = not it.val else it.val = it.val + d * (it.step or 1); clampNum(it) end
        refresh()
    end

    local function mousePos()
        local pc = getPC(); local lib = wll()
        if not (isValid(pc) and isValid(lib)) then return nil end
        local v; pcall(function() v = lib:GetMousePositionOnViewport(pc) end)
        if v == nil then return nil end
        local px, py; pcall(function() px = v.X end); pcall(function() py = v.Y end)
        if px and py then return px, py end
        return nil
    end

    local function onLMB()
        if not M.open then return end
        local px, py = mousePos(); if not px then return end
        local hit = "miss"
        -- close button (top-right)?
        if px >= L.closeX - 4 and px <= L.closeX + L.closeW and py >= L.closeY - 2 and py <= L.closeY + L.closeH then
            log(string.format("click=(%.0f,%.0f) -> close", px, py))
            closeMenu(); return
        end
        -- tab bar?
        if py >= L.tabY and py <= L.tabY + L.tabH then
            for t = 1, #tabs do
                local x0 = L.tabX0 + (t - 1) * L.tabStep
                if px >= x0 and px <= x0 + L.tabW then M.tab = t; M.sel = 1; hit = "tab " .. tabs[t].name; refresh(); break end
            end
        else
            local items = curItems()
            local idx = math.floor((py - L.rowY0) / L.rowH) + 1
            if px >= L.panelX and px <= L.panelX + L.panelW and idx >= 1 and idx <= #items then
                M.sel = idx
                local it = items[idx]; local act = "select"
                if it.kind == "bool" then
                    if px >= L.decX - 6 and px <= L.decX + 150 then it.val = not it.val; act = "toggle " .. tostring(it.val) end
                elseif px >= L.decX - 6 and px <= L.decX + L.colW then it.val = it.val - (it.step or 1); clampNum(it); act = "- " .. tostring(it.val)
                elseif px >= L.incX - 6 and px <= L.incX + L.colW then it.val = it.val + (it.step or 1); clampNum(it); act = "+ " .. tostring(it.val) end
                hit = it.name .. " (" .. act .. ")"; refresh()
            end
        end
        log(string.format("click=(%.0f,%.0f) tabY[%d-%d] dec[%d-%d] inc[%d-%d] -> %s",
            px, py, L.tabY, L.tabY + L.tabH, L.decX, L.decX + L.colW, L.incX, L.incX + L.colW, hit))
    end

    return {
        name = "menu",
        keys = {
            { key = "F2", desc = "toggle tuner menu", fn = toggle },
            { key = "NUM_EIGHT", desc = "select up",   fn = function() navItem(-1) end },
            { key = "NUM_TWO",   desc = "select down", fn = function() navItem(1) end },
            { key = "NUM_FOUR",  desc = "decrease",    fn = function() adjust(-1) end },
            { key = "NUM_SIX",   desc = "increase",    fn = function() adjust(1) end },
            { key = "NUM_SEVEN", desc = "prev tab",    fn = function() navTab(-1) end },
            { key = "NUM_NINE",  desc = "next tab",    fn = function() navTab(1) end },
            { key = "LEFT_MOUSE_BUTTON", desc = "menu: click",     fn = onLMB },
            { key = "LBUTTON",           desc = "menu: click (alt)", fn = onLMB },
        },
        hooks = {},
    }
end
