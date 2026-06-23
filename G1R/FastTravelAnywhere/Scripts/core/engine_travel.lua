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

-- move the pawn to world (tx,ty). opts (map-click path only): { safeLanding, cancelIfUnsafe, dbg }.
-- With an explicit tz (a captured quick-travel height) the mod uses it directly. Otherwise, with
-- safeLanding, it looks for flat ground at and just around the click. If only steep ground is near
-- and cancelIfUnsafe is set, it does NOT move you and returns nil, "unsafe". The move itself uses
-- AddActorWorldOffset (K2_Set* throw on the FHitResult param); the K2 forms are fallbacks, each
-- VERIFIED by reading the position back. Returns (form, nil) on success, or (nil, reason).
function engine.teleport(tx, ty, tz, opts)
    opts = opts or {}
    local safeLanding, cancelIfUnsafe, dbg = opts.safeLanding, opts.cancelIfUnsafe, opts.dbg
    local pawn = playerPawn()
    if not isValid(pawn) then return nil, "nopawn" end
    local cx, cy, cz = rootPos(pawn)
    if not cx then return nil, "nopos" end
    if type(tz) ~= "number" then
        if dbg then diagHit(tx, ty, dbg) end
        if safeLanding then
            local sx, sy, sz, status = safeSpot(tx, ty, dbg, {
                expand = opts.expandSearch, maxRange = opts.maxSearchRange,
                minNz = opts.minFlatness, maxZDelta = opts.maxElevationDelta })
            if status == "ok" then
                tx, ty, tz = sx, sy, sz + GROUND_OFFSET
            elseif cancelIfUnsafe then
                if dbg then dbg("  no safe ground near the cursor (" .. tostring(status) .. "); teleport cancelled") end
                return nil, "unsafe"
            elseif sx then
                tx, ty, tz = sx, sy, sz + GROUND_OFFSET -- cancel off: use the nearest ground anyway
            end
        end
        if type(tz) ~= "number" then
            local gz = groundZ(tx, ty)
            tz = gz and (gz + GROUND_OFFSET) or cz
        end
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
    return nil, "failed"
end

return engine
