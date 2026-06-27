-- snackbar.lua  --  stackable, transient on-screen messages: a small custom UMG "snackbar" stack.
--
-- The game exposes no Lua-callable text-toast function (its notifications are internal C++ delegates
-- for item pickups, quests and the like), so this draws its own. Crash-safe by the same rules as any
-- viewport UMG: the container widget plus a FIXED pool of rows (Border + TextBlock) are built ONCE and
-- reused. Messages only show, reposition and hide existing rows, never construct a widget per message.
-- Build it off any transition (call snackbar.prebuild during calm gameplay) and only show() from a
-- calm context, never while the game is tearing down or building UI.
--
-- The kit stays game-agnostic, so the MOD injects the pieces it needs via snackbar.bind: kit.engine,
-- kit.async, and a controller() resolver returning the player controller (its exact class is
-- game-specific). Then call snackbar.show(text, opts) from the GAME THREAD (UMG must be touched there;
-- the reward and cost callers already run there). Stacks up to MAX_ROWS, oldest evicted when full.

local ipairs, math, tostring, type = ipairs, math, tostring, type
local table, tonumber, os = table, tonumber, os
local rawget, rawset = rawget, rawset

local snackbar = {}

local E, getController -- injected via bind()

local MAX_ROWS    = 5
local DEFAULT_MS  = 5500
local ROW_H, GAP, BORDER, TEXT_H = 30, 6, 2, 18 -- row height, gap, gold-rim thickness, text-slot height
local CHAR_W = 8 -- estimated glyph width at font size 14 (no reliable text measure on this build)
local FROM_BOTTOM = 90      -- design-space margin from the bottom edge
local UIKEY       = "__kit_snackbar" -- the built widget lives in _G so it survives a hot reload

-- sRGB -> linear (the engine renders in linear space, so encode the intended sRGB once)
local function lin(c) if c <= 0.04045 then return c / 12.92 end return ((c + 0.055) / 1.055) ^ 2.4 end
local function rgb(r, g, b, a) return { R = lin(r / 255), G = lin(g / 255), B = lin(b / 255), A = a or 1 } end
local PANEL  = rgb(0x0a, 0x0a, 0x0c, 0.92)
local ACCENT = rgb(0xd4, 0xb0, 0x6a, 1) -- the menu / tooltip gold, used as the rim
local KIND = {
    info   = rgb(0xec, 0xec, 0xef),
    reward = rgb(0x8a, 0xd6, 0x6a),
    cost   = rgb(0xd4, 0xb0, 0x6a),
    warn   = rgb(0xd9, 0x4a, 0x3a),
}

function snackbar.bind(deps)
    E = deps.engine
    getController = deps.controller
end

local function toText(s)
    local kt = E.find("/Script/Engine.Default__KismetTextLibrary")
    if not E.isValid(kt) then return nil end
    return E.guard(kt, function(o) return o:Conv_StringToText(s) end)
end

local function slotInto(canvas, child)
    local slot = E.guard(canvas, function(c) return c:AddChildToCanvas(child) end)
    if slot then E.try(function() slot:SetAutoSize(false) end) end
    return slot
end

-- build the container widget + the fixed row pool ONCE
local function build()
    local pc = getController and getController()
    if not E.isValid(pc) then return nil end
    local wlib = E.find("/Script/UMG.Default__WidgetBlueprintLibrary")
    local uwC  = E.find("/Script/UMG.UserWidget")
    local cpC  = E.find("/Script/UMG.CanvasPanel")
    local brC  = E.find("/Script/UMG.Border")
    local tbC  = E.find("/Script/UMG.TextBlock")
    if not (E.isValid(wlib) and E.isValid(uwC) and E.isValid(cpC) and E.isValid(brC) and E.isValid(tbC)) then return nil end
    local widget = E.guard(wlib, function(w) return w:Create(pc, uwC, pc) end)
    local tree = E.guard(widget, function(w) return w.WidgetTree end)
    if not E.isValid(tree) then return nil end
    local canvas = E.construct(cpC, tree)
    if not E.isValid(canvas) then return nil end
    E.try(function() tree.RootWidget = canvas end)
    local rows = {}
    for i = 1, MAX_ROWS do
        local outer = E.construct(brC, tree) -- gold rim
        local inner = E.construct(brC, tree) -- dark panel, inset so the gold shows as a border
        local tb    = E.construct(tbC, tree)
        if not (E.isValid(outer) and E.isValid(inner) and E.isValid(tb)) then return nil end
        E.try(function() outer:SetBrushColor(ACCENT) end)
        E.try(function() inner:SetBrushColor(PANEL) end)
        E.try(function() local f = tb.Font; f.Size = 14; tb:SetFont(f) end)
        E.try(function() tb:SetJustification(1) end) -- ETextJustify::Center
        local outerSlot = slotInto(canvas, outer)
        local innerSlot = slotInto(canvas, inner)
        local tbSlot    = slotInto(canvas, tb)
        E.try(function() tbSlot:SetAutoSize(true) end) -- the text slot hugs the text; we center by position
        E.try(function() outer:SetVisibility(1) end) -- Collapsed until used
        E.try(function() inner:SetVisibility(1) end)
        E.try(function() tb:SetVisibility(1) end)
        rows[i] = { outer = outer, inner = inner, tb = tb,
                    outerSlot = outerSlot, innerSlot = innerSlot, tbSlot = tbSlot, busy = false }
    end
    E.try(function() widget:SetVisibility(3) end) -- HitTestInvisible: render, never eat clicks
    E.try(function() widget:AddToViewport(110) end)
    return { widget = widget, rows = rows, active = {} }
end

local function ui()
    local h = rawget(_G, UIKEY)
    if h and E and E.isValid(h.widget) and h.rows then return h end
    if not (E and getController) then return nil end -- not bound yet
    h = build()
    if h then rawset(_G, UIKEY, h) end
    return h
end

-- pre-build the widget during stable gameplay so the first message never constructs mid-transition.
function snackbar.prebuild() return ui() ~= nil end

local function place(slot, x, y, w, hh)
    if slot then E.try(function() slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = w, Y = hh }) end) end
end

-- estimated text width, plus a box width that hugs it with even padding (so the box is centered on
-- screen and the text, parked at the same center, looks centered without relying on justification).
local function widthFor(text)
    local estW = #tostring(text) * CHAR_W
    local boxW = estW + 36
    if boxW < 90 then boxW = 90 elseif boxW > 520 then boxW = 520 end
    return estW, boxW
end

-- stack the active rows bottom-up (oldest highest, newest lowest), centered horizontally
local function reflow(h)
    local vw, vh, sc = E.viewport(h.widget)
    local dw, dh = 1920, 1080
    if vw and vh and sc then dw, dh = vw / sc, vh / sc end
    local baseY = dh - FROM_BOTTOM
    local n = #h.active
    for i = 1, n do
        local e = h.active[i]
        local fromBottom = n - i -- newest (i == n) sits lowest
        local y = baseY - (fromBottom + 1) * ROW_H - fromBottom * GAP
        local x = dw / 2 - e.width / 2
        place(e.row.outerSlot, x, y, e.width, ROW_H)
        place(e.row.innerSlot, x + BORDER, y + BORDER, e.width - 2 * BORDER, ROW_H - 2 * BORDER)
        -- auto-sized text slot: only its position matters. Park its top-left so the text lands centered.
        place(e.row.tbSlot, dw / 2 - e.textW / 2, y + (ROW_H - TEXT_H) / 2, e.textW, TEXT_H)
    end
end

local function freeRow(h)
    for _, r in ipairs(h.rows) do if not r.busy then return r end end
    return nil
end

local function release(h, e)
    e.row.busy = false
    -- SetVisibility(Collapsed) hides the Border here but NOT the TextBlock, and the reflow never
    -- repositions a dismissed row, so the surest hide is to park both slots off-screen (slot
    -- positioning is what the reflow uses and it works) and clear the text. show() restores them.
    E.try(function() e.row.outer:SetVisibility(1) end)
    E.try(function() e.row.inner:SetVisibility(1) end)
    E.try(function() e.row.tb:SetVisibility(1) end)
    local empty = toText("")
    if empty then E.try(function() e.row.tb:SetText(empty) end) end
    place(e.row.outerSlot, -9999, -9999, 1, 1)
    place(e.row.innerSlot, -9999, -9999, 1, 1)
    place(e.row.tbSlot, -9999, -9999, 1, 1)
end

-- show a transient message. opts.kind = "info" | "reward" | "cost" | "warn", opts.ms = lifetime in ms.
-- Returns true if shown. No-op until bound. Call from the GAME THREAD.
function snackbar.show(text, opts)
    local h = ui()
    if not h then return false end
    opts = opts or {}
    if #h.active >= MAX_ROWS then -- evict the oldest to make room
        local old = table.remove(h.active, 1)
        if old then release(h, old) end
    end
    local row = freeRow(h)
    if not row then return false end
    row.busy = true
    local ink = KIND[opts.kind] or KIND.info
    E.try(function() row.tb:SetColorAndOpacity({ SpecifiedColor = ink, ColorUseRule = 0 }) end)
    local ft = toText(tostring(text))
    if ft then E.try(function() row.tb:SetText(ft) end) end
    E.try(function() row.outer:SetVisibility(3) end) -- HitTestInvisible: render, no clicks
    E.try(function() row.inner:SetVisibility(3) end)
    E.try(function() row.tb:SetVisibility(3) end)
    local ms = tonumber(opts.ms) or DEFAULT_MS
    local estW, boxW = widthFor(text)
    h.active[#h.active + 1] = { row = row, width = boxW, textW = estW, expireAt = os.clock() + ms / 1000 }
    reflow(h)
    return true
end

-- prune expired messages and reflow. The mod must drive this from a GAME-THREAD loop (UMG must be
-- touched there); a per-message one-shot timer proved unreliable, so dismissal is poll-based instead.
function snackbar.tick()
    local h = rawget(_G, UIKEY)
    if not (h and E and E.isValid(h.widget)) then return end
    local now = os.clock()
    local changed = false
    local i = 1
    while i <= #h.active do
        if now >= h.active[i].expireAt then
            release(h, table.remove(h.active, i))
            changed = true
        else
            i = i + 1
        end
    end
    if changed then reflow(h) end
end

return snackbar
