-- engine_lock.lua -- the lockpicking engine adapter (the only file with Gothic
-- domain literals). Re-exports the generic kit primitives so session/tinter/boost
-- see one `engine` surface. pcall does NOT catch native AVs; the IsValid gates here
-- are the real guard (banned-ops rules live in kit/engine.lua + LuaModdingSurface.md).

local ipairs = ipairs
local string = string
local os = os
local pcall = pcall
local type = type
local tostring = tostring
local FName = FName
local StaticFindObject = StaticFindObject

local kit = require("kit")

-- FNames are process-global and never torn down, so build each MPC/material parameter name
-- ONCE and reuse it. The hot path (readSlot/readHighlight/writeColor per piece per tick)
-- otherwise re-interns the name on every native call. Lazy so construction happens after
-- the engine is up, never at require time. Built inside the callers' pcalls.
local slotFNames = {}
local function slotName(i)
    local fn = slotFNames[i]
    if not fn then fn = FName("Slot_" .. i); slotFNames[i] = fn end
    return fn
end
local highlightFName
local function highlightName()
    local fn = highlightFName
    if not fn then fn = FName("HighlightColor"); highlightFName = fn end
    return fn
end

local engine = {}
engine.liveInstances = kit.engine.liveInstances
engine.readRootPos = kit.engine.readRootPos
local isValid = kit.engine.isValid
engine.isValid = isValid
local try = kit.engine.try
local tonumber = tonumber
local StaticConstructObject = StaticConstructObject
local rawget, rawset = rawget, rawset

-- Cached singleton handles. A FindAllOf scan walks the whole object array and is a frame
-- hitch, so the session-long singletons (the LockPickSubsystem and the player's attribute
-- set) are resolved once and reused. Each resolver revalidates with isValid() on use, and
-- engine.dropHandles() clears them on a world change (main's InitGameStatePost hook).
local subsysCache = nil
local attrSetCache = nil

-- the active lock's FName, via the current task's owning Ability (m_Lock). Abilities
-- are reused, so prefer the freshest notify-captured spawn.
function engine.currentLockName(freshTask, freshAbility)
    if freshTask and os.clock() - freshTask.t < 30.0 then
        local name
        local ok = pcall(function()
            local obj = freshTask.obj
            if not obj:IsValid() then return end
            -- IsValid-gate the Ability sub-object before reading m_Lock off it: a freed
            -- Ability is an uncatchable native AV (pcall does not catch it), and this runs
            -- first on the open, before any other gate.
            local ability = obj.Ability
            if not (ability and ability:IsValid()) then return end
            name = ability.m_Lock:ToString()
        end)
        if ok and name and name ~= "" and name ~= "None" then return name end
    end
    if freshAbility and os.clock() - freshAbility.t < 30.0 then
        local name
        local ok = pcall(function()
            if freshAbility.obj:IsValid() then
                name = freshAbility.obj.m_Lock:ToString()
            end
        end)
        if ok and name and name ~= "" and name ~= "None" then return name end
    end
    for _, cls in ipairs({ "GameplayAbilityOpen", "GameplayAbilityDoor" }) do
        for _, ab in ipairs(engine.liveInstances(cls)) do
            if string.find(ab:GetFullName(), "PlayerState", 1, true) then
                local name
                local ok = pcall(function() name = ab.m_Lock:ToString() end)
                if ok and name and name ~= "" and name ~= "None" then return name end
            end
        end
    end
    return nil
end

-- the live LockPickSubsystem, CACHED: a session-long singleton, so the ~30ms FindAllOf
-- runs once instead of every lock open. The scene actor it owns IS per-minigame and is
-- read fresh by mpcHandles below; only the subsystem handle is cached here.
local function lockPickSubsystem()
    if subsysCache and isValid(subsysCache) then return subsysCache end
    subsysCache = nil
    for _, sub in ipairs(engine.liveInstances("LockPickSubsystem")) do
        subsysCache = sub
        return sub
    end
    return nil
end

-- the KismetMaterialLibrary CDO, the MPC_Lockpicking asset (both cheap StaticFindObject
-- hash lookups), and the live scene actor read off the CACHED subsystem. Returns
-- lib, mpc, scene or nil. No FindAllOf once the subsystem is cached.
function engine.mpcHandles()
    local lib, mpc, scene
    pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary") end)
    pcall(function() mpc = StaticFindObject("/Game/Blueprints/LockPick/MPC_Lockpicking.MPC_Lockpicking") end)
    local sub = lockPickSubsystem()
    if sub then
        pcall(function()
            local sc = sub.m_LockSceneActor
            if sc and sc:IsValid() then scene = sc end
        end)
    end
    if lib and lib:IsValid() and mpc and mpc:IsValid() and scene then
        return lib, mpc, scene
    end
    return nil
end

-- the player's lockpicking AttributeSet (the one under PlayerState), CACHED. Boost and
-- the precision read both need it, so resolving it here makes them share ONE scan, and
-- the cache makes later opens free. isValid() plus the PlayerState identity check
-- re-resolve a stale handle after a save-load / respawn.
function engine.playerLockAttrSet()
    local hit = attrSetCache
    if hit and isValid(hit) then
        local ok, full = pcall(function() return hit:GetFullName() end)
        if ok and full and string.find(full, "PlayerState", 1, true) then return hit end
    end
    attrSetCache = nil
    for _, s in ipairs(engine.liveInstances("AttributeSet_Lockpicking")) do
        local ok, full = pcall(function() return s:GetFullName() end)
        if ok and full and string.find(full, "PlayerState", 1, true) then
            attrSetCache = s
            return s
        end
    end
    return nil
end

-- player's lockpicking GAS attributes (native, safe read): LockpickPrecision (=
-- connections the game prunes) and LockpickDurability. GAS exposes each as an
-- FGameplayAttributeData (CurrentValue/BaseValue) or a bare number.
function engine.lockpickAttributes()
    local function valueOf(a)
        if type(a) == "number" then return a end
        if a == nil then return nil end
        local v
        pcall(function() v = a.CurrentValue end)
        if type(v) ~= "number" then pcall(function() v = a.BaseValue end) end
        return type(v) == "number" and v or nil
    end
    local set = engine.playerLockAttrSet()
    if not set then return nil end
    local out
    pcall(function()
        out = { precision = valueOf(set.LockpickPrecision),
                durability = valueOf(set.LockpickDurability) }
    end)
    if out and (out.precision or out.durability) then return out end
    return nil
end

-- ------------------------------------------------------- lockpick inventory --
-- Immersive Mode counts + consumes the lockpick item (ItKe_Lockpick) -- the same Gothic seams as the
-- ore read in FastTravelAnywhere: the InventoryComponent under the player state. We call ONLY the
-- KNOWN-good UFunctions (CountItemsOfClass, RemoveItemFromInventory); never batter unknown names (a
-- guessed UFunction call native-AVs and pcall cannot catch it).
local AS_PACKAGES = { "/Script/Angelscript.", "/Script/AngelscriptCode.", "/Script/G1R.", "/Script/Engine." }

local sfoCache = {}
local function sfo(p)
    local h = sfoCache[p]
    if isValid(h) then return h end
    h = StaticFindObject and try(function() return StaticFindObject(p) end) or nil
    if isValid(h) then sfoCache[p] = h end
    return h
end

local function firstLive(cls)
    for _, o in ipairs(engine.liveInstances(cls)) do return o end
    return nil
end

local itemClassCache = {}
local function resolveItemClass(name)
    if not name or name == "" then return nil end
    local hit = itemClassCache[name]
    if hit ~= nil then return hit or nil end
    local found
    for _, form in ipairs({ name, name .. "_C" }) do
        for _, pkg in ipairs(AS_PACKAGES) do
            local c = sfo(pkg .. form)
            if isValid(c) then found = c; break end
        end
        if not found then local c = sfo(form); if isValid(c) then found = c end end
        if found then break end
    end
    itemClassCache[name] = found or false
    return found or nil
end

local function libCDO(className)
    for _, pkg in ipairs(AS_PACKAGES) do
        local cdo = sfo(pkg .. "Default__" .. className)
        if isValid(cdo) then return cdo end
    end
    return nil
end

local function playerState()
    local pawn = firstLive("GothicPlayerCharacter")
    if not isValid(pawn) then return nil end
    local state = try(function() return pawn.PlayerState end)
    if not isValid(state) then state = try(function() return pawn.m_CharacterState end) end
    return pawn, (isValid(state) and state or nil)
end

local function inventoryOf(pawn, state)
    local direct = isValid(state) and try(function() return state.InventoryComponent end) or nil
    if isValid(direct) then return direct end
    local cls = resolveItemClass("InventoryComponent")
    for _, owner in ipairs({ state, pawn }) do
        if isValid(owner) and cls then
            local c = try(function() return owner:GetComponentByClass(cls) end)
            if isValid(c) then return c end
        end
    end
    return nil
end

-- current count of the item class id (e.g. "ItKe_Lockpick"), or nil if it cannot be read.
function engine.itemCount(itemName)
    local cls = resolveItemClass(itemName)
    if not isValid(cls) then return nil end
    local pawn, state = playerState()
    local inv = inventoryOf(pawn, state)
    if not isValid(inv) then return nil end
    local v
    local ok = try(function() v = inv:CountItemsOfClass(cls); return true end)
    if ok then return tonumber(v) end
    return nil
end

-- remove `amount` of the item from the player's inventory (the state-mixin path). True on success.
function engine.spendItem(itemName, amount)
    if not (amount and amount > 0) then return true end
    local cls = resolveItemClass(itemName)
    if not isValid(cls) then return false end
    local pawn, state = playerState()
    if not (isValid(pawn) and isValid(state)) then return false end
    local mix = libCDO("Module_GAS_GASCharacterStateMixinsStatics")
    if not isValid(mix) then return false end
    return (try(function() mix:RemoveItemFromInventory(state, cls, amount, pawn); return true end) == true)
end

-- ------------------------------------------------------------- readout --
-- Immersive Mode's on-minigame tooltip: a small SharedModMenu-styled panel (header + divider + three
-- lines) at a fixed top-left spot while a lock is being picked. Same UMG model as FastTravelAnywhere's
-- stable readout (see [[map-teleport-mod-spec]]): built ONCE and shown/hidden by AddToViewport /
-- RemoveFromParent, text updated in place, never reconstructed. No cursor, so it just sits at the
-- anchor and only its text changes. main.lua's driver computes the lines.
local function lin(c) if c <= 0.04045 then return c / 12.92 end return ((c + 0.055) / 1.055) ^ 2.4 end
local function rgb(r, g, b, a) return { R = lin(r / 255), G = lin(g / 255), B = lin(b / 255), A = a or 1 } end
local PANEL_BG = rgb(0x0a, 0x0a, 0x0c, 0.95)
local FRAME    = rgb(0x3a, 0x3a, 0x46, 0.95)
local ACCENT   = rgb(0xd4, 0xb0, 0x6a, 1.00)
local INK0     = rgb(0xec, 0xec, 0xef, 1.00)
local INK1     = rgb(0xa6, 0xa6, 0xb0, 1.00)
local ALERT    = rgb(0xd9, 0x4a, 0x3a, 1.00)
local ReadoutKey = "__lps_readoutWidget"
local READOUT_SHAPE = 1

local function toText(s)
    local kt = sfo("/Script/Engine.Default__KismetTextLibrary")
    if not isValid(kt) then return nil end
    return try(function() return kt:Conv_StringToText(s) end)
end

local function buildReadout()
    local pc = firstLive("GothicPlayerController") or firstLive("PlayerController")
    local wlibObj = sfo("/Script/UMG.Default__WidgetBlueprintLibrary")
    local uwC, cpC = sfo("/Script/UMG.UserWidget"), sfo("/Script/UMG.CanvasPanel")
    local brC, tbC = sfo("/Script/UMG.Border"), sfo("/Script/UMG.TextBlock")
    if not (isValid(pc) and isValid(wlibObj) and isValid(uwC) and isValid(cpC) and isValid(brC) and isValid(tbC)) then return nil end
    local widget = try(function() return wlibObj:Create(pc, uwC, pc) end)
    local tree = isValid(widget) and try(function() return widget.WidgetTree end) or nil
    if not isValid(tree) then return nil end
    local canvas = try(function() return StaticConstructObject(cpC, tree) end)
    if not isValid(canvas) then return nil end
    pcall(function() tree.RootWidget = canvas end)
    local function box(color)
        local b = try(function() return StaticConstructObject(brC, tree) end)
        if not isValid(b) then return nil end
        pcall(function() b:SetBrushColor(color) end)
        local slot = try(function() return canvas:AddChildToCanvas(b) end)
        if slot then pcall(function() slot:SetAutoSize(false) end) end
        return slot
    end
    local function text(color, size)
        local tb = try(function() return StaticConstructObject(tbC, tree) end)
        if not isValid(tb) then return nil end
        pcall(function() local f = tb.Font; f.Size = size or 14; tb:SetFont(f) end)
        pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
        local slot = try(function() return canvas:AddChildToCanvas(tb) end)
        if slot then pcall(function() slot:SetAutoSize(false) end) end
        return { tb = tb, slot = slot }
    end
    return {
        widget = widget, shown = false, shape = READOUT_SHAPE,
        bg = box(PANEL_BG), accent = box(ACCENT),
        bottom = box(FRAME), left = box(FRAME), right = box(FRAME), divider = box(FRAME),
        header = text(ACCENT, 13), l1 = text(INK0, 14), l2 = text(ACCENT, 15), l3 = text(INK1, 13),
    }
end

local function ensureReadout()
    local h = rawget(_G, ReadoutKey)
    if h and isValid(h.widget) and h.l1 and h.shape == READOUT_SHAPE then return h end
    if h and isValid(h.widget) then pcall(function() h.widget:RemoveFromParent() end) end
    h = buildReadout()
    if not h then return nil end
    pcall(function() h.widget:SetVisibility(3) end) -- HitTestInvisible: never eats clicks
    h.shown = false
    rawset(_G, ReadoutKey, h)
    return h
end

-- pre-build the panel during gameplay (the driver calls this off-minigame) so opening a lock never
-- constructs a widget mid-transition. No-op once built.
function engine.readoutBuild() return ensureReadout() ~= nil end

local function placeSlot(slot, x, y, w, hh)
    if slot then pcall(function() slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = w, Y = hh }) end) end
end
local function layoutReadout(h, x, y, pw, ph)
    placeSlot(h.bg, x, y, pw, ph)
    placeSlot(h.accent, x, y, pw, 2)
    placeSlot(h.bottom, x, y + ph - 1, pw, 1)
    placeSlot(h.left, x, y, 1, ph)
    placeSlot(h.right, x + pw - 1, y, 1, ph)
    if h.header then placeSlot(h.header.slot, x + 14, y + 9, pw - 22, 18) end
    placeSlot(h.divider, x + 12, y + 31, pw - 24, 1)
    if h.l1 then placeSlot(h.l1.slot, x + 14, y + 39, pw - 22, 20) end
    if h.l2 then placeSlot(h.l2.slot, x + 14, y + 60, pw - 22, 20) end
    if h.l3 and ph > 90 then placeSlot(h.l3.slot, x + 14, y + 82, pw - 22, 18) end
end

local function setText(t, s)
    if t and isValid(t.tb) then local ft = toText(s or ""); if ft then pcall(function() t.tb:SetText(ft) end) end end
end

local function widthFor(...)
    local n = 0
    for _, s in ipairs({ ... }) do if type(s) == "string" and #s > n then n = #s end end
    local w = 28 + n * 9
    if w < 190 then w = 190 elseif w > 460 then w = 460 end
    return w
end

-- show/update the panel with its TOP-LEFT at the design-space (x, y). line2 is red when isRed; line3
-- is optional and grows the panel. Only the text + width change (the panel sits at a fixed spot).
function engine.readoutUpdate(header, line1, line2, line3, isRed, x, y)
    local h = ensureReadout()
    if not h then return false end
    if h.lastHeader ~= header then setText(h.header, header); h.lastHeader = header end
    if h.lastL1 ~= line1 then setText(h.l1, line1); h.lastL1 = line1 end
    if h.lastL2 ~= line2 then setText(h.l2, line2); h.lastL2 = line2 end
    if h.lastL3 ~= line3 then setText(h.l3, line3); h.lastL3 = line3 end
    if h.lastRed ~= isRed and h.l2 and isValid(h.l2.tb) then
        pcall(function() h.l2.tb:SetColorAndOpacity({ SpecifiedColor = isRed and ALERT or ACCENT, ColorUseRule = 0 }) end)
        h.lastRed = isRed
    end
    local pw = widthFor(header, line1, line2, line3)
    local ph = (line3 ~= nil and line3 ~= "") and 110 or 88
    local ox, oy = x or 40, y or 110
    if h.lastX ~= ox or h.lastY ~= oy or h.lastW ~= pw or h.lastH ~= ph then
        layoutReadout(h, ox, oy, pw, ph)
        h.lastX, h.lastY, h.lastW, h.lastH = ox, oy, pw, ph
    end
    if not h.shown then pcall(function() h.widget:AddToViewport(120) end); h.shown = true end
    return true
end

function engine.readoutHide()
    local h = rawget(_G, ReadoutKey)
    if h and h.shown and isValid(h.widget) then
        if not pcall(function() h.widget:RemoveFromParent() end) then pcall(function() h.widget:RemoveFromViewport() end) end
        h.shown = false
    end
end

-- the live viewport size in PIXELS plus the UMG DPI scale, so a caller can anchor the readout to a
-- screen edge. The slots live in design space (pixels / scale), so a screen-pixel offset O from an
-- edge of pixel-size P maps to slot coordinate (P - O) / scale. Returns nil if it cannot be read.
-- Uses the built readout widget (or the player controller) as the world context.
function engine.viewportSize()
    local wlib = sfo("/Script/UMG.Default__WidgetLayoutLibrary")
    if not isValid(wlib) then return nil end
    local h = rawget(_G, ReadoutKey)
    local ctx = h and h.widget
    if not isValid(ctx) then ctx = firstLive("GothicPlayerController") or firstLive("PlayerController") end
    if not isValid(ctx) then return nil end
    local w, hh, scale
    local ok = try(function()
        local sz = wlib:GetViewportSize(ctx)
        w, hh = sz.X, sz.Y
        scale = wlib:GetViewportScale(ctx)
        return true
    end)
    if not (ok and type(w) == "number" and type(hh) == "number") then return nil end
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end
    return w, hh, scale
end

-- read MPC Slot_i as {R,G,B} (the live per-piece world position). h carries the
-- lib/scene/mpc handles. IsValid-gate the scene: it can die mid-open and pcall can't
-- catch the AV reading a dead scene.
function engine.readSlot(h, i)
    if not isValid(h.scene) then return nil end
    local v
    local ok = pcall(function()
        local c = h.lib:GetVectorParameterValue(h.scene, h.mpc, slotName(i))
        v = { c.R, c.G, c.B }
    end)
    if not ok then return nil end
    return v
end

-- write HighlightColor on every MID of a piece (re-applied per tick; the game's hover
-- overwrites it). IsValid-gate per MID: a cached MID can die and pcall can't catch the AV.
function engine.writeColor(e, color)
    for _, mid in ipairs(e.mids) do
        pcall(function()
            if mid:IsValid() then
                mid:SetVectorParameterValue(highlightName(), color)
            end
        end)
    end
end

-- read/write the scene's piece interpolation speed (baseline 20). Cranking it snaps
-- the move glide (the auto-solve speed lever; restored on stop). IsValid-gate: the
-- scene actor is torn down on open and pcall can't catch the AV indexing a dead AActor.
function engine.getSceneInterp(scene)
    if not isValid(scene) then return nil end
    local v
    local ok = pcall(function() v = scene.m_LockPieceInterpolationSpeed end)
    if ok then return v end
    return nil
end

function engine.setSceneInterp(scene, value)
    if not isValid(scene) then return false end
    return (pcall(function() scene.m_LockPieceInterpolationSpeed = value end))
end

-- read a MID's current HighlightColor (to spot the game's glow vs our own paint).
-- IsValid-gate per call, same staleness risk as writeColor.
function engine.readHighlight(mid)
    local c
    local ok = pcall(function()
        if mid:IsValid() then
            c = mid:K2_GetVectorParameterValue(highlightName())
        end
    end)
    if ok and c then return c end
    return nil
end

-- the ONLY write that DRIVES the minigame: press a task input UFunction (up/down move
-- selection, left/right turn the piece). INPUT-STATE DEPENDENT (moves in some sessions,
-- inert in others), so the caller confirms each press from the measured state. Liveness
-- checked per call (pcall can't catch the AV on a dead task). Returns true if dispatched.
function engine.pressInput(freshTask, which)
    if not freshTask or not freshTask.obj then return false end
    local ok = pcall(function()
        local obj = freshTask.obj
        if not obj:IsValid() then error("task not valid") end
        if which == "up" then obj:UpPressed()
        elseif which == "down" then obj:DownPressed()
        elseif which == "left" then obj:LeftPressed()
        elseif which == "right" then obj:RightPressed()
        else error("unknown press '" .. tostring(which) .. "'") end
    end)
    return ok
end

-- drop the cached singleton handles. Call on a world change: the isValid() revalidation in
-- the resolvers already self-heals, this just avoids carrying a dead wrapper across a GC.
function engine.dropHandles()
    subsysCache = nil
    attrSetCache = nil
end

return engine
