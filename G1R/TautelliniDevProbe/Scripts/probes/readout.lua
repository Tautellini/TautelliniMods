-- probes/readout.lua  --  prove the Immersive-Mode readout: a UMG text label that FOLLOWS THE
-- CURSOR over the open world map and recolors (white / red). This de-risks the riskiest part of
-- the FastTravelAnywhere Immersive-Mode spec: drawing at the cursor over the map, and driving it
-- from a cheap #1180-safe game-thread loop (kit.async.gameLoop), gated on the map being open.
--
-- PERF (lag fix 2026-06-26): the per-tick work MUST NOT call FindAllOf / StaticFindObject each
-- frame -- FindAllOf scans the whole object array and is the documented in-game hitch source. So
-- every engine handle is CACHED: StaticFindObject CDOs are process-stable (cache hard); live actors
-- are revalidated with the cheap isValid() and only re-scanned when invalid, and a MISS is throttled
-- so a closed map (no MapMain yet) does not scan every tick. With the cache the tick is a few
-- isValid checks, field reads and widget setters.
--
-- The label shows the REAL straight-line distance from the player to the cursor's world position
-- (cursor -> map via DPI math -> world via the baked affine, the same path FastTravelAnywhere's
-- ptele uses). It turns red past a threshold, to demonstrate the unaffordable state. The ore half is
-- a placeholder ("-- ore") until the economy probe lands the count read.
--
-- UMG recipe mirrors SharedModMenu/render.lua. HOT-RELOAD SAFE: no engine call at load (the widget
-- builds lazily inside the tick, only after `show` + map open); the loop starts once behind a _G
-- flag, the handle lives in _G so CTRL+R can clean a stale one.
--
-- ACTIONS (bind in config.probes.readout.keys):
--   show = SAFE. Build the label + start the loop. Open the world map to see it track the cursor.
--   hide = SAFE. Remove the label and idle the loop.

local ipairs, tostring, type, string, math, tonumber, pcall, require, os =
      ipairs, tostring, type, string, math, tonumber, pcall, require, os
local rawget, rawset = rawget, rawset

-- baked world map -> world affine (portable; map space is fixed). Same constants ptele uses.
local MAPWORLD = { ax = -138.484464, cx = 227935.3681, ay = -131.972110, cy = -45186.9795 }
local RED_OVER_M = 600 -- show red when the jump is longer than this many metres (demo of the gate)
local H_KEY = "__ftaReadout"
local osclock = os and os.clock

return function(ctx)
    local log = ctx.makeLog("readout")
    local isValid, try = ctx.isValid, ctx.try
    local FindAllOf, fullName = ctx.FindAllOf, ctx.fullName
    local SFO, SCO = ctx.StaticFindObject, ctx.StaticConstructObject

    local okKit, kit = pcall(require, "kit")
    local async = (okKit and type(kit) == "table") and kit.async or nil

    local function now() return osclock and osclock() or 0 end

    -- ---- cached engine handles (the lag fix) ----
    local libCache = {}
    local function lib(p) -- StaticFindObject CDO: process-stable, cache hard
        local h = libCache[p]
        if isValid(h) then return h end
        h = SFO and try(function() return SFO(p) end) or nil
        if isValid(h) then libCache[p] = h end
        return h
    end
    local liveCache, nextScan = {}, {}
    local function firstLiveRaw(cls)
        local list = FindAllOf and try(function() return FindAllOf(cls) end) or nil
        if not list then return nil end
        for _, o in ipairs(list) do
            if isValid(o) and not (fullName(o) or ""):find("Default__", 1, true) then return o end
        end
        return nil
    end
    local function cachedLive(cls) -- revalidate cheap; re-scan only when invalid; throttle misses
        local h = liveCache[cls]
        if isValid(h) then return h end
        if (nextScan[cls] or 0) > now() then return nil end
        nextScan[cls] = now() + 0.5
        h = firstLiveRaw(cls)
        liveCache[cls] = h or nil
        return h
    end

    local function playerController() return cachedLive("GothicPlayerController") or cachedLive("PlayerController") end
    local function playerPawn() return cachedLive("GothicPlayerCharacter") end
    local function wll() return lib("/Script/UMG.Default__WidgetLayoutLibrary") end

    -- cursor + viewport in ONE pass (one pc + one WidgetLayoutLibrary resolve per tick). DESIGN
    -- space, matching SMM + engine_travel. Returns cx, cy, vw, vh, dpi or nil.
    local function screenParams()
        local pc, wl = playerController(), wll()
        if not (isValid(pc) and isValid(wl)) then return nil end
        local cx, cy, vw, vh, dpi
        try(function() local v = wl:GetMousePositionOnViewport(pc); cx, cy = v.X, v.Y end)
        try(function() local v = wl:GetViewportSize(pc); vw, vh = v.X, v.Y end)
        dpi = tonumber(try(function() return wl:GetViewportScale(pc) end))
        if type(cx) == "number" and type(vw) == "number" and dpi and dpi > 0 then return cx, cy, vw, vh, dpi end
        return nil
    end

    -- the open world map widget, or nil (the gate: only show the readout while it is up)
    local function openWorldMap()
        local mm = cachedLive("MapMain")
        if not mm then return nil end
        if try(function() return mm:IsInViewport() end) == false then return nil end
        local w = try(function() return mm.Map_World end)
        if not isValid(w) then return nil end
        if try(function() return w.m_IsWorldMap end) ~= true then return nil end
        if try(function() return w.m_IsEmpty end) ~= false then return nil end
        return w
    end
    local function uiCustomSize(w)
        local d = try(function() return w.m_ActiveMapData end) or try(function() return w.m_MapData end)
        local ux = isValid(d) and tonumber(try(function() return d.UICustomSize.X end)) or nil
        local uy = isValid(d) and tonumber(try(function() return d.UICustomSize.Y end)) or nil
        if ux and uy then return ux, uy end
        return 1600, 900
    end

    local function rootPos(actor)
        local rc = try(function() return actor.RootComponent end)
        if not isValid(rc) then return nil end
        local x, y, z
        local ok = try(function() local v = rc:K2_GetComponentLocation(); x, y, z = v.X, v.Y, v.Z; return true end)
        if ok and type(x) == "number" then return x, y, z end
        return nil
    end

    -- cursor world position over the open map from the pre-read screen params. Mirrors ptele.
    local function cursorWorld(w, cx, cy, vw, vh, dpi)
        local uw, uh = uiCustomSize(w)
        local mapX = (cx - (vw - uw * dpi) / 2) / dpi
        local mapY = (cy - (vh - uh * dpi) / 2) / dpi
        return MAPWORLD.ax * mapX + MAPWORLD.cx, MAPWORLD.ay * mapY + MAPWORLD.cy
    end

    -- ---- UMG label colours (sRGB hex -> linear, like render.lua) ----
    local function lin(c) if c <= 0.04045 then return c / 12.92 end return ((c + 0.055) / 1.055) ^ 2.4 end
    local WHITE = { R = lin(0.93), G = lin(0.93), B = lin(0.94), A = 1 }
    local RED   = { R = lin(0.85), G = lin(0.18), B = lin(0.18), A = 1 }

    local function toText(s)
        local kt = lib("/Script/Engine.Default__KismetTextLibrary")
        if not isValid(kt) then return nil end
        return try(function() return kt:Conv_StringToText(s) end)
    end

    -- build the widget + one TextBlock; returns a handle { widget, tb, slot } or nil. Game thread.
    local function buildLabel()
        local pc = playerController()
        local wlibObj = lib("/Script/UMG.Default__WidgetBlueprintLibrary")
        local uwC, cpC, tbC = lib("/Script/UMG.UserWidget"), lib("/Script/UMG.CanvasPanel"), lib("/Script/UMG.TextBlock")
        if not (isValid(pc) and isValid(wlibObj) and isValid(uwC) and isValid(cpC) and isValid(tbC)) then return nil end
        local widget = try(function() return wlibObj:Create(pc, uwC, pc) end)
        local tree = isValid(widget) and try(function() return widget.WidgetTree end) or nil
        if not isValid(tree) then return nil end
        local canvas = try(function() return SCO(cpC, tree) end)
        if not isValid(canvas) then return nil end
        pcall(function() tree.RootWidget = canvas end)
        local tb = try(function() return SCO(tbC, tree) end)
        if not isValid(tb) then return nil end
        local slot = try(function() return canvas:AddChildToCanvas(tb) end)
        if slot then pcall(function() slot:SetAutoSize(false); slot:SetSize({ X = 320, Y = 40 }) end) end
        pcall(function() local f = tb.Font; f.Size = 16; tb:SetFont(f) end)
        pcall(function() widget:AddToViewport(120) end) -- above the map UI (SMM uses 50)
        return { widget = widget, tb = tb, slot = slot }
    end

    local function hold()
        local h = rawget(_G, H_KEY)
        if not h then h = { on = false }; rawset(_G, H_KEY, h) end
        return h
    end

    local function removeLabel(h)
        if h.handle and isValid(h.handle.widget) then
            if not pcall(function() h.handle.widget:RemoveFromParent() end) then
                pcall(function() h.handle.widget:RemoveFromViewport() end)
            end
        end
        h.handle = nil
    end

    -- the per-cycle work, ON the game thread (kit.async fast path). Cheap; near-free when idle.
    local function tick()
        local h = hold()
        if not h.on then return end
        local w = openWorldMap()
        if not w then removeLabel(h); return end -- map closed: hide, wait for reopen
        if not h.handle then -- build lazily; back off on failure so we never hammer Create()
            if (h.nextBuild or 0) > now() then return end
            h.handle = buildLabel()
            if not h.handle then
                h.nextBuild = now() + 0.5
                if not h.warnedBuild then h.warnedBuild = true; log("label build failed (UMG create/class unavailable?); retrying") end
                return
            end
            h.warnedBuild = false
        end
        local cx, cy, vw, vh, dpi = screenParams()
        if not cx then return end
        local wx, wy = cursorWorld(w, cx, cy, vw, vh, dpi)
        local p = playerPawn()
        local px, py = isValid(p) and rootPos(p) or nil
        local distM = (wx and px) and ((((wx - px) ^ 2 + (wy - py) ^ 2) ^ 0.5) / 100) or nil
        local distTxt = distM and (distM >= 1000 and string.format("%.2f km", distM / 1000)
            or string.format("%.0f m", distM)) or "off map"
        local ft = toText(distTxt .. "  /  -- ore")
        if ft and isValid(h.handle.tb) then pcall(function() h.handle.tb:SetText(ft) end) end
        local color = (distM and distM > RED_OVER_M) and RED or WHITE
        pcall(function() h.handle.tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
        if h.handle.slot then pcall(function() h.handle.slot:SetPosition({ X = cx + 18, Y = cy + 18 }) end) end
    end

    -- refresh the tick closure on the persistent hold each load so the STABLE loop runs current code
    hold().tick = tick

    local function startLoop()
        if rawget(_G, H_KEY .. "_loop") then return end
        if not (async and async.gameLoop) then log("no kit.async.gameLoop on this build; cannot drive the readout"); return end
        rawset(_G, H_KEY .. "_loop", true)
        async.gameLoop(66, function()
            local hh = hold()
            if hh and hh.on and hh.tick then return hh.tick end
        end)
        log("readout loop started (66 ms, game-thread, cached handles)")
    end

    local function show()
        hold().on = true
        startLoop()
        log("readout ON: open the WORLD map; a label tracks the cursor (white, red over " .. RED_OVER_M .. " m)")
    end
    local function hide()
        local hh = hold()
        hh.on = false
        ctx.onGameThread(function() removeLabel(hh) end)
        log("readout OFF (label removed; loop idles)")
    end

    return {
        name = "readout",
        actions = {
            { id = "show", desc = "SHOW cursor-tracking distance label over the world map (SAFE)", fn = show },
            { id = "hide", desc = "HIDE the readout label (SAFE)", fn = hide },
        },
    }
end
