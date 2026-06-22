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

local ipairs, tonumber, type, pcall, math = ipairs, tonumber, type, pcall, math

local kit = require("kit")
local isValid, try = kit.engine.isValid, kit.engine.try

-- engine ACCESS globals (registration globals stay in main.lua's tail)
local FindAllOf = rawget(_G, "FindAllOf")
local StaticFindObject = rawget(_G, "StaticFindObject")

local engine = {}

local GROUND_OFFSET = 120 -- lift above the trace hit so the capsule rests on the ground
local AS_PACKAGES = { "/Script/Angelscript.", "/Script/AngelscriptCode.", "/Script/G1R.", "/Script/Engine." }

local function lib(p) return StaticFindObject and try(function() return StaticFindObject(p) end) or nil end
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

local function playerPawn() return firstLive("GothicPlayerCharacter") end
local function playerController() return firstLive("GothicPlayerController") or firstLive("PlayerController") end
local function hud() return firstLive("GothicHUDBase") or firstLive("GothicHUD") end

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

-- the live world map widget when it is OPEN (on screen), else nil. Gate so the hotkey cannot
-- teleport from a stale cursor during normal play: the map screen must be in the viewport, and the
-- world map widget populated. IsInViewport is the strong signal; m_IsEmpty is the fallback.
local function openWorldMap()
    local mm = firstLive("MapMain")
    if not mm then return nil end
    if try(function() return mm:IsInViewport() end) == false then return nil end
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

-- ------------------------------------------------------------ ground + move --
local function groundZ(x, y)
    local ksl = lib("/Script/Engine.Default__KismetSystemLibrary")
    local pawn = playerPawn()
    if not (isValid(ksl) and isValid(pawn)) then return nil end
    local hit = {}
    local ok, wasHit = pcall(function()
        return ksl:LineTraceSingle(pawn, { X = x, Y = y, Z = 60000 }, { X = x, Y = y, Z = -60000 },
            0, false, {}, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
    end)
    if not (ok and wasHit) then return nil end
    return tonumber(try(function() return hit.Location.Z end))
        or tonumber(try(function() return hit.ImpactPoint.Z end))
end

local function asActorLib()
    for _, pkg in ipairs(AS_PACKAGES) do
        local o = lib(pkg .. "Default__AngelscriptActorLibrary")
        if isValid(o) then return o end
    end
    return nil
end

-- move the pawn to world (tx,ty). With an explicit tz (a captured standing height) the mod uses it
-- directly, which is reliable; otherwise it ground-traces and lifts by the capsule offset. The move
-- itself uses AddActorWorldOffset (K2_Set* throw on the FHitResult param); the K2 forms are
-- fallbacks, each VERIFIED by reading the position back. Returns the form that moved it, or nil.
function engine.teleport(tx, ty, tz)
    local pawn = playerPawn()
    if not isValid(pawn) then return nil end
    local cx, cy, cz = rootPos(pawn)
    if not cx then return nil end
    if type(tz) ~= "number" then
        local gz = groundZ(tx, ty)
        tz = gz and (gz + GROUND_OFFSET) or cz
    end
    local rc = try(function() return pawn.RootComponent end)
    local function liveVec()
        if not isValid(rc) then return nil end
        local v = try(function() return rc:K2_GetComponentLocation() end)
        if v then pcall(function() v.X, v.Y, v.Z = tx, ty, tz end) end
        return v
    end
    local attempts = {}
    local aslib = asActorLib()
    if isValid(aslib) then
        attempts[#attempts + 1] = { "AS:AddActorWorldOffset",
            function() aslib:AddActorWorldOffset(pawn, { X = tx - cx, Y = ty - cy, Z = tz - cz }) end }
    end
    if isValid(rc) then
        attempts[#attempts + 1] = { "rc:K2_SetWorldLocation",
            function() rc:K2_SetWorldLocation(liveVec(), false, {}, true) end }
        attempts[#attempts + 1] = { "pawn:K2_SetActorLocation",
            function() pawn:K2_SetActorLocation(liveVec(), false, {}, true) end }
    end
    local tol = math.max(50, ((tx - cx) ^ 2 + (ty - cy) ^ 2) ^ 0.5 * 0.02)
    for _, a in ipairs(attempts) do
        pcall(a[2])
        local nx, ny = rootPos(pawn)
        if nx and ((nx - tx) ^ 2 + (ny - ty) ^ 2) ^ 0.5 < tol then return a[1] end
    end
    return nil
end

return engine
