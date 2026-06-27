-- core/engine_travel.lua -- the ONLY file that touches the engine for FastTravelAnywhere. It reads
-- the cursor + screen metrics, finds the world map, ground-traces, and moves the player. Every call
-- is pcall-guarded via the kit; the cursor->map->world math lives in the pure travel/pipeline.
--
-- Proven seams (from the dev map probe, see [[map-teleport-mod]]):
--   cursor  = GothicHUDBase.m_LastMousePos (raw px, device agnostic)
--   viewport= WidgetLayoutLibrary:GetViewportSize ; DPI = :GetViewportScale
--   map     = MapMain.Map_World (m_IsWorldMap), its MapData.UICustomSize, m_IsEmpty = open?
--   move    = AngelscriptActorLibrary:AddActorWorldOffset (K2_Set* throw "Array failed invariants")
--   ground  = KismetSystemLibrary:LineTraceSingle (HitResult={} filled in place)

local ipairs, tonumber, type, pcall, math, string = ipairs, tonumber, type, pcall, math, string

local kit = require("kit")
local isValid, try = kit.engine.isValid, kit.engine.try

-- engine ACCESS globals (registration globals stay in main.lua's tail)
local FindAllOf = rawget(_G, "FindAllOf")
local StaticFindObject = rawget(_G, "StaticFindObject")
local StaticConstructObject = rawget(_G, "StaticConstructObject")
local rawget, rawset, os = rawget, rawset, os

local engine = {}

local GROUND_OFFSET = 120 -- lift above the trace hit so the capsule rests on the ground
local AS_PACKAGES = { "/Script/Angelscript.", "/Script/AngelscriptCode.", "/Script/G1R.", "/Script/Engine." }

-- the game's own fast-travel (MapData:TeleportActorToNormalized2DPosition) normalized <-> world rect,
-- measured dev-side (linear, global, axis-aligned): normX = (x0 - worldX)/xk, normY = (y0 - worldY)/yk.
local GAME_FUNC = { x0 = 116876, xk = 110788, y0 = -104711, yk = 59388 }

-- MapMain is CAPTURED by main's NotifyOnNewObject into this _G slot, NOT scanned with FindAllOf. The
-- map widget is destroyed on close and rebuilt on open, and scanning for it mid-build grabbed a
-- half-constructed object and crashed ("at 20% map loaded"). We just revalidate the captured handle;
-- isValid is false while the map is closed/destroyed, and bIsActive is true only once it is built.
local MapMainKey = "__ftw_mapMain"
local function mapMain() local mm = rawget(_G, MapMainKey); return isValid(mm) and mm or nil end
function engine.setMapMain(obj) if isValid(obj) then rawset(_G, MapMainKey, obj) end end

local libCache = {}
local function lib(p)
    local h = libCache[p]
    if isValid(h) then return h end
    h = StaticFindObject and try(function() return StaticFindObject(p) end) or nil
    if isValid(h) then libCache[p] = h end
    return h
end
local function firstLive(cls)
    local list = FindAllOf and try(function() return FindAllOf(cls) end) or nil
    if not list then return nil end
    for _, o in ipairs(list) do
        if isValid(o) then
            local fn = try(function() return o:GetFullName() end)
            if not (fn and fn:find("Default__", 1, true)) then return o end
        end
    end
    return nil
end

-- cache live actor handles (FindAllOf is the per-tick hitch source for the readout driver; revalidate
-- cheaply with isValid, re-scan only when invalid, throttle misses so a closed map stays cheap).
local liveCache, nextScan = {}, {}
local function cachedLive(cls)
    local h = liveCache[cls]
    if isValid(h) then return h end
    local now = (os and os.clock) and os.clock() or 0
    if (nextScan[cls] or 0) > now then return nil end
    nextScan[cls] = now + 0.5
    h = firstLive(cls)
    liveCache[cls] = h or nil
    return h
end

-- resolve the pawn / controller ONCE and reuse via isValid (re-resolve only when invalid), so the
-- readout driver never re-queries a possibly-missing class every tick. Without this, a class that is
-- not the live one (e.g. GothicPlayerController vs PlayerController) is never cached, so cachedLive
-- re-runs FindAllOf for it every 0.5 s on the game thread -- the micro-stutter.
local pawnCache, pcCache
local function playerPawn()
    if isValid(pawnCache) then return pawnCache end
    pawnCache = cachedLive("GothicPlayerCharacter")
    return pawnCache
end
local function playerController()
    if isValid(pcCache) then return pcCache end
    pcCache = cachedLive("GothicPlayerController") or cachedLive("PlayerController")
    return pcCache
end
local function hud() return cachedLive("GothicHUDBase") or cachedLive("GothicHUD") end

-- world location through the ROOT COMPONENT, never actor-level K2_GetActorLocation
local function rootPos(actor)
    local rc = try(function() return actor.RootComponent end)
    if not isValid(rc) then return nil end
    local x, y, z
    local ok = try(function() local v = rc:K2_GetComponentLocation(); x, y, z = v.X, v.Y, v.Z; return true end)
    if ok and type(x) == "number" then return x, y, z end
    ok = try(function() local v = rc.RelativeLocation; x, y, z = v.X, v.Y, v.Z; return true end)
    if ok and type(x) == "number" then return x, y, z end
    return nil
end

function engine.available() return isValid(playerPawn()) end

-- current player world position (x, y, z) or nil
function engine.playerPos()
    local p = playerPawn()
    if not isValid(p) then return nil end
    return rootPos(p)
end

-- ------------------------------------------------------- cursor + screen --
-- cursor in DESIGN (DPI-scaled, viewport-relative) space. GetMousePositionOnViewport returns this
-- directly, unlike GothicHUDBase.m_LastMousePos which reports physical desktop pixels (so it only
-- matched at the native resolution). This makes the on-map teleport resolution independent.
local function cursorViewport()
    local pc, wl = playerController(), lib("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (isValid(pc) and isValid(wl)) then return nil end
    local x, y
    try(function() local v = wl:GetMousePositionOnViewport(pc); x, y = v.X, v.Y end)
    if type(x) == "number" then return x, y end
    return nil
end
local function viewportSize()
    local pc, wl = playerController(), lib("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (isValid(pc) and isValid(wl)) then return nil end
    local x, y
    try(function() local v = wl:GetViewportSize(pc); x, y = v.X, v.Y end)
    if type(x) == "number" then return x, y end
    return nil
end
local function viewportScale()
    local pc, wl = playerController(), lib("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (isValid(pc) and isValid(wl)) then return nil end
    return tonumber(try(function() return wl:GetViewportScale(pc) end))
end

-- design-space cursor + DESIGN viewport size (physical / DPI) + DPI, or nil if unavailable. The map
-- widget is laid out at UICustomSize design units centered in the design viewport, so the whole
-- cursor->map step stays in one space and needs no physical-pixel math.
function engine.screenParams()
    local cdx, cdy = cursorViewport()
    local vw, vh = viewportSize()
    local dpi = viewportScale()
    if not (cdx and vw and dpi and dpi > 0) then return nil end
    return cdx, cdy, vw / dpi, vh / dpi, dpi
end

-- design-space cursor ONLY -- the one input that changes while the map is open. The readout reads
-- this every frame; the rest (player pos, ore, map + viewport metrics) is read once per map session.
function engine.cursorXY()
    return cursorViewport()
end

-- raw cursor px from the HUD's m_LastMousePos -- a PROPERTY read, safe from a timer, unlike the
-- viewport/PC slate QUERY in cursorViewport (the one per-tick call the menu never makes from a loop).
-- Physical px; the caller divides by the session-cached DPI to reach design space.
function engine.cursorHud()
    local h = hud()
    if not isValid(h) then return nil end
    local x, y
    if try(function() local v = h.m_LastMousePos; x, y = v.X, v.Y; return true end) and type(x) == "number" then
        return x, y
    end
    return nil
end

-- the live world map widget when it is OPEN (on screen), else nil. Gate so the hotkey cannot
-- teleport from a stale cursor during normal play: the map screen must be in the viewport, and the
-- world map widget populated. IsInViewport is the strong signal; m_IsEmpty is the fallback.
-- the world map widget when its SCREEN is the active one. MapMain is a CommonActivatableWidget; its
-- bIsActive bool flips true ONLY while the map screen is on top (measured: true on the map, false in
-- gameplay / the inventory / the pause menu). It reads cleanly where every Slate visibility method
-- returns nil, so it gates the readout AND the teleport WITHOUT a hook (the OpenMapMenu hook crashed)
-- and WITHOUT a per-tick FindAllOf (mm is the cached handle).
local function openWorldMap()
    local mm = mapMain()
    if not mm then return nil end
    if try(function() return mm.bIsActive end) ~= true then return nil end
    local w = try(function() return mm.Map_World end)
    if not isValid(w) then return nil end
    if try(function() return w.m_IsWorldMap end) ~= true then return nil end
    if try(function() return w.m_IsEmpty end) ~= false then return nil end -- not populated = not open
    return w
end

-- UICustomSize (map coordinate space) of the open world map, or nil if the map is not open.
function engine.worldMapSize()
    local w = openWorldMap()
    if not w then return nil end
    local d = try(function() return w.m_ActiveMapData end)
    if not isValid(d) then d = try(function() return w.m_MapData end) end
    if not isValid(d) then return nil end
    local uw = tonumber(try(function() return d.UICustomSize.X end))
    local uh = tonumber(try(function() return d.UICustomSize.Y end))
    if uw and uh and uw > 0 and uh > 0 then return uw, uh end
    return nil
end

-- is the world map the ACTIVE screen? Reads MapMain.bIsActive (a CommonActivatableWidget bool, true
-- only while the map is on top). MapMain is persistent on the game instance, so this handle never goes
-- stale across map sessions -- cheap and safe to call every frame to gate the readout.
function engine.mapActive()
    local mm = mapMain()
    return mm ~= nil and (try(function() return mm.bIsActive end) == true)
end

-- close the open world map: the game's own fast-travel closes it, our direct teleport does not.
-- MapMain:CloseWidgetBP is the map widget's OWN close (found in the hook-candidate dump; DeactivateWidget
-- only flips it inactive without popping it). Closing it means the player reopens the map later,
-- post-stream, never mid-stream -- which is where the crash lived. No-op if the map is not open.
function engine.closeMap()
    local mm = mapMain()
    if not isValid(mm) then return false end
    return (try(function() mm:CloseWidgetBP(); return true end) == true)
end

-- ------------------------------------------------------------ ground + move --
local function kslAndPawn()
    local ksl = lib("/Script/Engine.Default__KismetSystemLibrary")
    local pawn = playerPawn()
    if isValid(ksl) and isValid(pawn) then return ksl, pawn end
    return nil
end

-- downward line trace at world (x,y): returns (groundZ, normalZ) or nil if nothing was hit. Both
-- Location.Z and ImpactNormal.Z are confirmed readable on this build (verified via diag): normalZ is
-- cos(slope), so 1 = flat ground and lower = steeper (a measured cliff face read ~0.33).
local function traceDown(ksl, pawn, x, y)
    local hit = {}
    local ok, wasHit = pcall(function()
        return ksl:LineTraceSingle(pawn, { X = x, Y = y, Z = 60000 }, { X = x, Y = y, Z = -60000 },
            0, false, {}, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
    end)
    if not (ok and wasHit) then return nil end
    local z = tonumber(try(function() return hit.Location.Z end))
        or tonumber(try(function() return hit.ImpactPoint.Z end))
    if not z then return nil end
    local nz = tonumber(try(function() return hit.ImpactNormal.Z end))
        or tonumber(try(function() return hit.Normal.Z end))
    return z, nz
end

-- plain ground Z at (x,y) via a single downward trace, or nil. The unconditional fallback.
local function groundZ(x, y)
    local ksl, pawn = kslAndPawn()
    if not ksl then return nil end
    return (traceDown(ksl, pawn, x, y))
end

-- One-shot diagnostic: trace the cursor target and log which HitResult fields actually read on this
-- build. This is how we fact-check ImpactNormal, the hit component, and the penetration flags before
-- trusting any of them. Only runs when a debug logger is passed in.
local function diagHit(tx, ty, dbg)
    local ksl, pawn = kslAndPawn()
    if not (ksl and dbg) then return end
    local hit = {}
    local ok, wasHit = pcall(function()
        return ksl:LineTraceSingle(pawn, { X = tx, Y = ty, Z = 60000 }, { X = tx, Y = ty, Z = -60000 },
            0, false, {}, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
    end)
    dbg(string.format("diag: trace ok=%s hit=%s", tostring(ok), tostring(wasHit)))
    if not ok then return end
    local function num(f) local v = tonumber(try(f)); return v and string.format("%.2f", v) or "nil" end
    dbg("  Location.Z=" .. num(function() return hit.Location.Z end)
        .. " ImpactPoint.Z=" .. num(function() return hit.ImpactPoint.Z end)
        .. " Distance=" .. num(function() return hit.Distance end))
    dbg("  ImpactNormal=(" .. num(function() return hit.ImpactNormal.X end) .. ", "
        .. num(function() return hit.ImpactNormal.Y end) .. ", "
        .. num(function() return hit.ImpactNormal.Z end) .. ")  Normal.Z="
        .. num(function() return hit.Normal.Z end))
    dbg("  bBlockingHit=" .. tostring(try(function() return hit.bBlockingHit end))
        .. " bStartPenetrating=" .. tostring(try(function() return hit.bStartPenetrating end)))
    local compName = try(function() return hit.Component:GetClass():GetFName():ToString() end)
        or try(function() return hit.Component:GetFullName() end)
    dbg("  hit component=" .. tostring(compName))
end

-- A spot is "broad" if the ground around it stays at a similar height, i.e. it is an open clearing and
-- not a lone ledge or rock top wedged between cliffs. Traces four points NEIGH_D out and requires most
-- of them to be within NEIGH_MAX_DZ in height. This is what rejects the "flat but inside rocks" spots.
local NEIGH_D, NEIGH_MAX_DZ = 200, 300 -- cm
local function broadFlat(ksl, pawn, x, y, z)
    local agree = 0
    local offs = { { NEIGH_D, 0 }, { -NEIGH_D, 0 }, { 0, NEIGH_D }, { 0, -NEIGH_D } }
    for _, o in ipairs(offs) do
        local gz = traceDown(ksl, pawn, x + o[1], y + o[2])
        if gz and math.abs(gz - z) <= NEIGH_MAX_DZ then agree = agree + 1 end
    end
    return agree >= 3
end

-- Safe-landing search, cursor-first and staged. The exact click is checked first; if it is flat we
-- land there and never move you off the cursor. Otherwise we search rings of growing radius and take
-- the flattest spot in the CLOSEST ring that qualifies. A spot qualifies only if it is (1) flat
-- enough (normalZ), (2) near the clicked elevation (within maxZDelta, so we never drop you into a
-- canyon far below the click), and (3) broad (open ground, not a ledge). The close rings (1.5 m, 3 m)
-- are always searched; with expand on it widens out to maxRange. Returns (x, y, groundZ, status):
-- "ok" a good spot was found; "steep" only bad ground exists (x,y,z is the nearest); "noground"/
-- "noengine" otherwise.
local CLOSE_RINGS = { 150, 300 }                     -- cm, always searched
local WIDE_RINGS  = { 600, 1000, 1500, 2200, 3000 }  -- cm, only when expand is on, capped at maxRange
local DEFAULT_MIN_NZ, DEFAULT_MAX_RANGE, DEFAULT_MAX_ZDELTA = 0.85, 3000, 1500
local function safeSpot(tx, ty, dbg, cfg)
    local ksl, pawn = kslAndPawn()
    if not ksl then return nil, "noengine" end
    local minNz = cfg.minNz or DEFAULT_MIN_NZ
    local maxZD = cfg.maxZDelta or DEFAULT_MAX_ZDELTA
    local radii = { 0 }
    for _, r in ipairs(CLOSE_RINGS) do radii[#radii + 1] = r end
    if cfg.expand then
        local maxR = cfg.maxRange or DEFAULT_MAX_RANGE
        for _, r in ipairs(WIDE_RINGS) do if r <= maxR then radii[#radii + 1] = r end end
    end
    local refZ, nearest -- refZ = the clicked elevation (or first ground found); nearest = closest hit
    for _, r in ipairs(radii) do
        local best, bestNz
        local n = (r == 0) and 1 or 8
        for k = 0, n - 1 do
            local a = k * (math.pi / 4)
            local x = (r == 0) and tx or (tx + r * math.cos(a))
            local y = (r == 0) and ty or (ty + r * math.sin(a))
            local z, nz = traceDown(ksl, pawn, x, y)
            if z then
                if not refZ then refZ = z end
                if not nearest then nearest = { x, y, z } end
                local nzv = nz or 1 -- normal unreadable: treat as flat (does not happen on this build)
                local flat, near = nzv >= minNz, math.abs(z - refZ) <= maxZD
                local broad = flat and near and broadFlat(ksl, pawn, x, y, z)
                local ok = flat and near and broad
                if dbg then
                    dbg(string.format("  cand r=%.0f z=%.0f dz=%.0f normalZ=%s -> %s", r, z, z - refZ,
                        nz and string.format("%.2f", nz) or "nil",
                        ok and "OK" or (not flat and "steep" or (not near and "far-z" or "narrow"))))
                end
                if ok and (not bestNz or nzv > bestNz) then best, bestNz = { x, y, z }, nzv end
            end
        end
        if best then
            if dbg and r > 0 then dbg(string.format("  relocated %.0f cm from the click (normalZ=%.2f)", r, bestNz)) end
            return best[1], best[2], best[3], "ok"
        end
    end
    if nearest then return nearest[1], nearest[2], nearest[3], "steep" end
    return nil, "noground"
end

local function asActorLib()
    for _, pkg in ipairs(AS_PACKAGES) do
        local o = lib(pkg .. "Default__AngelscriptActorLibrary")
        if isValid(o) then return o end
    end
    return nil
end

-- the game's MapData singleton (carries TeleportActorToNormalized2DPosition). GetInstance off the
-- CDO, else a live instance. Cached; the singleton lives for the session.
local mapDataInst
local function gameMapData()
    if isValid(mapDataInst) then return mapDataInst end
    local cdo = lib("/Script/G1R.Default__MapData")
    if isValid(cdo) then mapDataInst = try(function() return cdo:GetInstance() end) end
    if not isValid(mapDataInst) then mapDataInst = cachedLive("MapData") end
    return mapDataInst
end

-- move the player to world (tx, ty) using the GAME's own fast-travel: it streams the destination
-- area in and places the player on valid ground. The normalized coord is the dev-measured global,
-- linear inverse of the world target. We build on the game function -- there is NO manual-move
-- fallback. Returns "game" on success, or (nil, reason).
function engine.teleport(tx, ty)
    local pawn = playerPawn()
    if not isValid(pawn) then return nil, "nopawn" end
    local md = gameMapData()
    if not isValid(md) then return nil, "nomapdata" end
    local bx, by = rootPos(pawn)
    local nx = (GAME_FUNC.x0 - tx) / GAME_FUNC.xk
    local ny = (GAME_FUNC.y0 - ty) / GAME_FUNC.yk
    if not try(function() md:TeleportActorToNormalized2DPosition(pawn, { X = nx, Y = ny }); return true end) then
        return nil, "failed"
    end
    local ax, ay = rootPos(pawn)
    if bx and ax and ((ax - bx) ^ 2 + (ay - by) ^ 2) ^ 0.5 < 50 then return nil, "nomove" end
    engine.clearTravelCaches() -- fast-travel may respawn the pawn / stream the area; drop now-stale handles
    return "game"
end

-- ------------------------------------------------------------- economy --
-- Ore (Erzbrocken) read + deduct + time advance, ported from TautelliniConsole's proven seams and
-- confirmed live (CountItemsOfClass returned the HUD ore total). The currency item is
-- ItMi_Orenugget, an AngelScript class. We only ever call these KNOWN-good UFunctions with KNOWN
-- args; never batter-test names (a guessed UFunction call native-AVs and pcall cannot catch it).
local libCdoCache = {}
local function libCDO(className)
    local hit = libCdoCache[className]
    if isValid(hit) then return hit end
    libCdoCache[className] = nil
    for _, pkg in ipairs(AS_PACKAGES) do
        local cdo = lib(pkg .. "Default__" .. className)
        if isValid(cdo) then libCdoCache[className] = cdo; return cdo end
    end
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
            local c = lib(pkg .. form)
            if isValid(c) then found = c; break end
        end
        if not found then local c = lib(form); if isValid(c) then found = c end end
        if found then break end
    end
    itemClassCache[name] = found or false
    return found or nil
end

local function playerState()
    local pawn = playerPawn()
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

-- current count of the item class id (e.g. "ItMi_Orenugget"), or nil if it cannot be read.
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

-- advance the in-game clock by `seconds` via GameTimeSubsystem:SkipTime -- the game's REAL time skip,
-- so NPCs catch up to the new time. It runs world catch-up on worker threads, so the caller (main's
-- scheduleTimeSkip) DEFERS it until the teleported-into area has streamed in; doing it immediately
-- raced the area streaming and crashed the game. True on success.
function engine.advanceTime(seconds)
    if not (seconds and seconds > 0) then return true end
    local clock = cachedLive("GameTimeSubsystem")
    if not isValid(clock) then return false end
    return (try(function() clock:SkipTime({ TotalSeconds = seconds }); return true end) == true)
end

-- ------------------------------------------------------------- readout --
-- The Immersive-Mode readout: a small SharedModMenu-styled panel (dark surface, gold top accent,
-- hairline frame) that follows the cursor over the open world map with two lines, the distance and
-- the ore cost (cost line turns red when you cannot afford it). Built ONCE and shown/hidden by
-- attaching/detaching; the handle is KEPT in a _G slot (never nil'd) so a stale widget is never
-- orphaned. UMG plumbing lives here (the adapter); main.lua's driver computes the lines + position.
local function lin(c) if c <= 0.04045 then return c / 12.92 end return ((c + 0.055) / 1.055) ^ 2.4 end
local function rgb(r, g, b, a) return { R = lin(r / 255), G = lin(g / 255), B = lin(b / 255), A = a or 1 } end
local PANEL_BG = rgb(0x0a, 0x0a, 0x0c, 0.95)  -- near-black surface (Aurum palette, like render.lua)
local FRAME    = rgb(0x3a, 0x3a, 0x46, 0.95)  -- hairline frame
local ACCENT   = rgb(0xd4, 0xb0, 0x6a, 1.00)  -- gold
local INK0     = rgb(0xec, 0xec, 0xef, 1.00)  -- primary text
local INK1     = rgb(0xa6, 0xa6, 0xb0, 1.00)  -- secondary text (the time line)
local ALERT    = rgb(0xd9, 0x4a, 0x3a, 1.00)  -- unaffordable red
local ReadoutKey = "__ftw_readoutWidget"
-- bump to force a one-time rebuild after a panel-structure change (the kept widget survives reload)
local READOUT_SHAPE = 3

local function toText(s)
    local kt = lib("/Script/Engine.Default__KismetTextLibrary")
    if not isValid(kt) then return nil end
    return try(function() return kt:Conv_StringToText(s) end)
end

local function buildReadout()
    local pc = playerController()
    local wlibObj = lib("/Script/UMG.Default__WidgetBlueprintLibrary")
    local uwC, cpC = lib("/Script/UMG.UserWidget"), lib("/Script/UMG.CanvasPanel")
    local brC, tbC = lib("/Script/UMG.Border"), lib("/Script/UMG.TextBlock")
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

-- build the panel ONCE (left DETACHED = hidden), then keep the handle. This is the SharedModMenu
-- model exactly: build once, SHOW/HIDE by AddToViewport / RemoveFromParent, update in place, and never
-- reconstruct or touch it from a fast loop. Returns the live handle, or nil if UMG is not ready yet.
local function ensureReadout()
    local h = rawget(_G, ReadoutKey)
    if h and isValid(h.widget) and h.l1 and h.shape == READOUT_SHAPE then return h end
    if h and isValid(h.widget) then pcall(function() h.widget:RemoveFromParent() end) end
    h = buildReadout()
    if not h then return nil end
    pcall(function() h.widget:SetVisibility(3) end) -- HitTestInvisible (once): never eats the map cursor
    h.shown = false
    rawset(_G, ReadoutKey, h)
    return h
end

-- pre-build the panel during normal gameplay (the off-map poll calls this), so opening the map never
-- constructs a widget mid-transition. No-op once built.
function engine.readoutBuild()
    return ensureReadout() ~= nil
end

local function placeSlot(slot, x, y, w, h)
    if slot then pcall(function() slot:SetPosition({ X = x, Y = y }); slot:SetSize({ X = w, Y = h }) end) end
end
local function layoutReadout(h, x, y, pw, ph)
    placeSlot(h.bg, x, y, pw, ph)
    placeSlot(h.accent, x, y, pw, 2)                       -- gold top accent
    placeSlot(h.bottom, x, y + ph - 1, pw, 1)
    placeSlot(h.left, x, y, 1, ph)
    placeSlot(h.right, x + pw - 1, y, 1, ph)
    if h.header then placeSlot(h.header.slot, x + 14, y + 9, pw - 22, 18) end
    placeSlot(h.divider, x + 12, y + 31, pw - 24, 1)       -- hairline under the [key] header
    if h.l1 then placeSlot(h.l1.slot, x + 14, y + 39, pw - 22, 20) end
    if h.l2 then placeSlot(h.l2.slot, x + 14, y + 60, pw - 22, 20) end
    if h.l3 and ph > 90 then placeSlot(h.l3.slot, x + 14, y + 82, pw - 22, 18) end
end

local function setText(t, s) if t and isValid(t.tb) then local ft = toText(s or ""); if ft then pcall(function() t.tb:SetText(ft) end) end end end

-- the box is sized to the longest line. Rendered text width is unreadable here (the Slate-geometry
-- wall), so it is estimated from the character count; ~10 px per char at this font keeps the text
-- inside the box. Clamped to a sensible min/max.
local function widthFor(a, b, c, d)
    local function len(s) return type(s) == "string" and #s or 0 end
    local n = len(a); if len(b) > n then n = len(b) end; if len(c) > n then n = len(c) end; if len(d) > n then n = len(d) end
    local w = 28 + n * 10
    if w < 160 then w = 160 elseif w > 420 then w = 420 end
    return w
end

-- show/update the panel (header + divider + 3 info lines) with its TOP-RIGHT corner at the design-space
-- anchor (x, y) -- the map's top-right corner, so it stays put while the cursor moves and only the
-- numbers change. header is the "[T] for Travel" hint; line2 is red when isRed; line3 (travel time) is
-- optional and grows the panel. Width follows the longest line.
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
    local pw = widthFor(line1, line2, line3, header)
    local ph = (line3 ~= nil and line3 ~= "") and 110 or 88
    local ox, oy = (x or 0) - pw, (y or 0)  -- the panel's top-right corner sits at the anchor
    if ox < 8 then ox = 8 end               -- never run off the left edge on a narrow map
    if h.lastX ~= ox or h.lastY ~= oy or h.lastW ~= pw or h.lastH ~= ph then
        layoutReadout(h, ox, oy, pw, ph)
        h.lastX, h.lastY, h.lastW, h.lastH = ox, oy, pw, ph
    end
    if not h.shown then pcall(function() h.widget:AddToViewport(120) end); h.shown = true end -- show last
    return true
end

-- hide the panel by DETACHING it (RemoveFromParent), the menu's hide path -- it actually removes the
-- window, and re-showing is a plain AddToViewport with no rebuild. Idempotent and cheap.
function engine.readoutHide()
    local h = rawget(_G, ReadoutKey)
    if h and h.shown and isValid(h.widget) then
        if not pcall(function() h.widget:RemoveFromParent() end) then pcall(function() h.widget:RemoveFromViewport() end) end
        h.shown = false
    end
end

-- drop cached LIVE GAME handles (pawn, controller, MapData, ...) so the next access re-resolves
-- fresh. Called right AFTER a teleport: the game's fast-travel respawns the pawn / streams the area,
-- freeing the old pawn / controller / inventory while a stale handle still passes isValid(), and the
-- next per-frame UFunction call on the freed object crashes UE4SS. Clearing ONLY after a teleport
-- keeps the handles cached the rest of the time (no per-open FindAllOf). The readout WIDGET is left
-- alone -- it is a viewport-level object that survives the teleport, and the readout loop removes it
-- cleanly when it next sees the map closed (removing it here mid-transition orphaned it on screen).
function engine.clearTravelCaches()
    pawnCache, pcCache, mapDataInst = nil, nil, nil
    liveCache, nextScan = {}, {}
end

-- resolve the pawn + controller into the cache NOW (cheap if already warm). The off-map poll calls
-- this during gameplay so the map-open session read is all cache hits, never a FindAllOf burst in the
-- transition. After a teleport (which clears the cache) the next off-map polls re-warm it.
function engine.warmTravel()
    playerPawn(); playerController()
end

return engine
