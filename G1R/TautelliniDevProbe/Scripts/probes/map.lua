-- probes/map.lua  --  cursor-to-world teleport via a one-time CALIBRATION.
--
-- Why calibration: on-screen Slate geometry is unreadable from Lua on this build
-- (every GetCachedGeometry/GetLocalSize returns 0, GetActorBounds out-params do not
-- marshal). So we cannot auto-convert a screen pixel into a position on the map image.
-- What we CAN read cleanly: the cursor in viewport pixels (GothicHUDBase.m_LastMousePos,
-- which both mouse and controller drive) and the player's true world position.
--
-- So we learn the cursor->world map empirically. The player aligns the cursor onto their
-- own marker at 3+ spread-out spots and records each; we least-squares fit an affine
-- transform from NORMALIZED cursor (cursor / viewport size, so it is resolution
-- independent) to world XY. Aligning to the drawn marker also folds in the map's
-- correction-texture distortion at the sample points. After that, the cursor maps to
-- world and we teleport via RootComponent:K2_SetWorldLocation. Calibrate once per map.
--
-- Map facts measured 2026-06-22 (kept for the eventual real mod):
--   Cursor:  GothicHUDBase.m_LastMousePos (raw px). viewport here 5120x1440.
--   Widgets: MapMain.Map_World (m_IsWorldMap), MapMain.Map_Area (cities), each a W_Map_C.
--   Boxes:   6x W_MapBoundingBox_C actors in MainMap.PersistentLevel define map regions
--            (origins logged by `read`); area MapData references one directly, world map
--            uses an AngelScript UIMapConfigWorldHuman whose box struct is opaque.
--
-- ACTIONS (bind in config.probes.map.keys):
--   read  = SAFE. Dump player pos, cursor, the map widgets, and the 6 box actors.
--   calib = SAFE. Align cursor to YOUR MARKER, then press. Records one point and refits.
--   tele  = DANGER, moves the player (throwaway save). Cursor -> world via the fit.
--   clear = SAFE. Drop all calibration points and start over.

local ipairs, tostring, type, string, math, table = ipairs, tostring, type, string, math, table
local io, debug, load, pcall, require, tonumber = io, debug, load, pcall, require, tonumber

-- Calibration is PERSISTED to <ModRoot>/map_calib.lua so it survives CTRL+R (which rebuilds
-- the Lua state), restart, and redeploy (deploy.ps1 only cleans Scripts/ and shared/, not the
-- mod root). _G holds it within a session; the file is the source of truth across sessions.
-- Once a good spread fit is captured it gets baked into Scripts/data/mapcalib.lua to ship.
_G.__mapcalib = _G.__mapcalib or { pts = {}, M = nil }

-- mod root, derived from this file's own path (.../<ModRoot>/Scripts/probes/map.lua)
local CALIB_PATH = (function()
    local s = (debug and debug.getinfo) and (debug.getinfo(1, "S").source or "") or ""
    local root = s:gsub("^@", ""):match("^(.*)[/\\]Scripts[/\\]")
    return root and (root .. "/map_calib.lua") or nil
end)()

return function(ctx)
    local log = ctx.makeLog("map")
    local isValid, try = ctx.isValid, ctx.try
    local firstLive, fullName, FindAllOf = ctx.firstLive, ctx.fullName, ctx.FindAllOf
    local classPath = ctx.classPath
    local SFO = ctx.StaticFindObject
    local CAL = _G.__mapcalib

    -- ----------------------------------------------------- persistence (disk) --
    local function serialize()
        local t = { "return {" }
        t[#t + 1] = "  M = " .. (CAL.M and string.format(
            "{ ax=%.12g, bx=%.12g, cx=%.12g, ay=%.12g, by=%.12g, cy=%.12g }",
            CAL.M.ax, CAL.M.bx, CAL.M.cx, CAL.M.ay, CAL.M.by, CAL.M.cy) or "nil") .. ","
        t[#t + 1] = "  pts = {"
        for _, p in ipairs(CAL.pts) do
            t[#t + 1] = string.format("    { nx=%.12g, ny=%.12g, wx=%.12g, wy=%.12g, dx=%s, dy=%s },",
                p.nx, p.ny, p.wx, p.wy,
                p.dx and string.format("%.12g", p.dx) or "nil", p.dy and string.format("%.12g", p.dy) or "nil")
        end
        t[#t + 1] = "  },\n}"
        return table.concat(t, "\n")
    end
    local function saveCalib()
        if not (CALIB_PATH and io and io.open) then return false end
        local f = io.open(CALIB_PATH, "w")
        if not f then return false end
        f:write(serialize()); f:close()
        return true
    end
    local function loadCalib()
        if not (CALIB_PATH and io and io.open) then return nil end
        local f = io.open(CALIB_PATH, "r")
        if not f then return nil end
        local txt = f:read("*a"); f:close()
        local chunk = load and load(txt, "mapcalib", "t", {})
        if not chunk then return nil end
        local ok, data = pcall(chunk)
        return (ok and type(data) == "table") and data or nil
    end
    -- restore across sessions: on-disk store first, then the baked-in source default
    if #CAL.pts == 0 and not CAL.M then
        local disk = loadCalib()
        if disk and disk.M then
            CAL.pts, CAL.M = disk.pts or {}, disk.M
        else
            local okReq, baked = pcall(require, "data.mapcalib")
            if okReq and type(baked) == "table" and baked.M then CAL.pts, CAL.M = baked.pts or {}, baked.M end
        end
    end

    -- ---------------------------------------------------------------- format --
    local function num(v) return type(v) == "number" and v or nil end
    -- render a value, handling 1/2/3-component vectors (FVector2D for map/box coords reads
    -- as 2-component; the old single 3-component path printed those as "<userdata>").
    local function fmt(v)
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
        if t == "nil" then return "nil" end
        if t == "userdata" then
            local x = tonumber(try(function() return v.X end))
            local y = tonumber(try(function() return v.Y end))
            local z = tonumber(try(function() return v.Z end))
            if x and y and z then return string.format("(%.1f, %.1f, %.1f)", x, y, z) end
            if x and y then return string.format("(%.1f, %.1f)", x, y) end
            if x then return string.format("(%.1f)", x) end
            local fn = try(function() return v:GetFullName() end)
            if fn then return "obj " .. fn end
        end
        return "<" .. t .. ">"
    end
    local function field(o, n) return fmt(try(function() return o[n] end)) end

    -- -------------------------------------------------------- engine handles --
    local function lib(p) return SFO and try(function() return SFO(p) end) or nil end
    -- the AngelScript actor library (AddActorWorldOffset) is the only reliable mover here:
    -- K2_Set* throw "Array failed invariants" on the FHitResult param. It can live in any of
    -- the script packages (mirrors TautelliniConsole's SCRIPT_PACKAGES), so try them all.
    local AS_PACKAGES = { "/Script/Angelscript.", "/Script/AngelscriptCode.", "/Script/G1R.", "/Script/Engine." }
    local function asActorLib()
        for _, pkg in ipairs(AS_PACKAGES) do
            local o = lib(pkg .. "Default__AngelscriptActorLibrary")
            if isValid(o) then return o end
        end
        return nil
    end
    local function playerController() return firstLive("GothicPlayerController") or firstLive("PlayerController") end
    local function hud() return firstLive("GothicHUDBase") or firstLive("GothicHUD") end
    local function playerPawn() return firstLive("GothicPlayerCharacter") end

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
    local function playerWorldPos()
        local p = playerPawn()
        if not isValid(p) then return nil end
        return rootPos(p)
    end

    -- raw-pixel cursor, device agnostic
    local function cursorRaw()
        local h = hud()
        if not isValid(h) then return nil end
        local x, y
        try(function() local v = h.m_LastMousePos; x, y = v.X, v.Y end)
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
    -- normalized 0..1 cursor (resolution independent)
    local function cursorNorm()
        local cx, cy = cursorRaw()
        local vw, vh = viewportSize()
        if not (cx and vw and vw > 0 and vh > 0) then return nil end
        return cx / vw, cy / vh
    end

    -- ------------------------------------------------------ affine fit (3x3) --
    local function solve3(M, r)
        local a = {
            { M[1][1], M[1][2], M[1][3], r[1] },
            { M[2][1], M[2][2], M[2][3], r[2] },
            { M[3][1], M[3][2], M[3][3], r[3] },
        }
        for col = 1, 3 do
            local piv = col
            for row = col + 1, 3 do
                if math.abs(a[row][col]) > math.abs(a[piv][col]) then piv = row end
            end
            a[col], a[piv] = a[piv], a[col]
            if math.abs(a[col][col]) < 1e-12 then return nil end
            for row = 1, 3 do
                if row ~= col then
                    local f = a[row][col] / a[col][col]
                    for k = col, 4 do a[row][k] = a[row][k] - f * a[col][k] end
                end
            end
        end
        return { a[1][4] / a[1][1], a[2][4] / a[2][2], a[3][4] / a[3][3] }
    end
    -- least-squares affine: norm(nx,ny) -> world(wx,wy)
    local function fit(pts)
        if #pts < 3 then return nil, "need 3+ points" end
        local S = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
        local rx, ry = { 0, 0, 0 }, { 0, 0, 0 }
        for _, p in ipairs(pts) do
            local b = { p.nx, p.ny, 1 }
            for i = 1, 3 do
                for j = 1, 3 do S[i][j] = S[i][j] + b[i] * b[j] end
                rx[i] = rx[i] + b[i] * p.wx
                ry[i] = ry[i] + b[i] * p.wy
            end
        end
        local cx, cy = solve3(S, rx), solve3(S, ry)
        if not (cx and cy) then return nil, "singular (points too collinear, spread them out)" end
        return { ax = cx[1], bx = cx[2], cx = cx[3], ay = cy[1], by = cy[2], cy = cy[3] }
    end
    local function applyFit(M, nx, ny)
        return M.ax * nx + M.bx * ny + M.cx, M.ay * nx + M.by * ny + M.cy
    end
    local function residual(M, pts)
        local maxr = 0
        for _, p in ipairs(pts) do
            local wx, wy = applyFit(M, p.nx, p.ny)
            local d = ((wx - p.wx) ^ 2 + (wy - p.wy) ^ 2) ^ 0.5
            if d > maxr then maxr = d end
        end
        return maxr
    end
    -- fit, iteratively dropping the worst outlier while it exceeds OUTLIER_TOL and 4+ points
    -- remain. One bad point (aiming on the wrong map, a misclick) otherwise wrecks the fit.
    local OUTLIER_TOL = 2000
    local function robustFit(pts)
        local kept = {}
        for _, p in ipairs(pts) do kept[#kept + 1] = p end
        local dropped = 0
        while #kept >= 4 do
            local M = fit(kept)
            if not M then break end
            local worst, worstD = nil, 0
            for i, p in ipairs(kept) do
                local wx, wy = applyFit(M, p.nx, p.ny)
                local d = ((wx - p.wx) ^ 2 + (wy - p.wy) ^ 2) ^ 0.5
                if d > worstD then worstD, worst = d, i end
            end
            if worstD > OUTLIER_TOL then table.remove(kept, worst); dropped = dropped + 1
            else break end
        end
        return fit(kept), kept, dropped
    end

    -- ----------------------------------------------------------------- read --
    local function mapWidgets()
        local out = {}
        local mm = firstLive("MapMain")
        if mm then
            local w = try(function() return mm.Map_World end); if isValid(w) then out[#out + 1] = { "Map_World", w } end
            local a = try(function() return mm.Map_Area end);  if isValid(a) then out[#out + 1] = { "Map_Area", a } end
        end
        return out, mm
    end

    local function readAll()
        log("=== MAP READ ===")
        local px, py, pz = playerWorldPos()
        log("player world: " .. ((px and py and pz) and string.format("(%.1f, %.1f, %.1f)", px, py, pz) or "??"))
        local cx, cy = cursorRaw()
        local nx, ny = cursorNorm()
        log("cursor: " .. (cx and string.format("raw(%.0f, %.0f)", cx, cy) or "??")
            .. (nx and string.format(" norm(%.4f, %.4f)", nx, ny) or ""))
        local widgets = mapWidgets()
        for _, e in ipairs(widgets) do
            log(string.format("[%s] isWorld=%s isEmpty=%s dotCorrected=%s",
                e[1], field(e[2], "m_IsWorldMap"), field(e[2], "m_IsEmpty"), field(e[2], "m_PlayerPosMapCorrected")))
        end
        local boxes = try(function() return FindAllOf("W_MapBoundingBox_C") end) or {}
        log("W_MapBoundingBox_C actors: " .. #boxes)
        for _, a in ipairs(boxes) do
            if isValid(a) then
                local ox, oy, oz = rootPos(a)
                log("    origin=" .. (ox and string.format("(%.0f, %.0f, %.0f)", ox, oy, oz) or "?")
                    .. "  " .. fullName(a))
            end
        end
        log(string.format("calibration: %d point(s), fitted=%s, store=%s",
            #CAL.pts, CAL.M and "yes" or "no", tostring(CALIB_PATH)))
        log("=== end read ===")
    end

    -- ----------------------------------------------------------------- hunt --
    -- Chase a DIRECT readable path (no calibration): the cursor in MAP space + the
    -- world<->map bounding box. The game must know both to draw the dot and drop markers.
    -- Drop a map marker at the cursor first, then press: that records the cursor's map
    -- position into m_CustomMarkers, and we retry the box harder.
    local BOX_FIELDS = { "Min", "Max", "m_Min", "m_Max", "TopLeft", "BottomRight",
        "m_TopLeft", "m_BottomRight", "Origin", "Extent", "m_Origin", "m_Extent",
        "BoxExtent", "Center", "Size", "m_Size", "MinX", "MinY", "MaxX", "MaxY",
        "Left", "Top", "Right", "Bottom" }
    -- exact field names from the offline dump (g1r-class-props.txt UIMapConfigDefinition).
    -- UICustomSize is likely the map coordinate-space size; reading these by EXACT name is
    -- the camera-mod pattern (StaticFindObject AS default + field by name), not guessing.
    local CONFIG_FIELDS = { "MapTag", "UICustomSize", "MapTexture", "MapOverlayedTexture",
        "MapOffsetTexture", "MapVersion", "IsPlayerInMap", "ColorArrayOffset", "MapPath", "MapName" }
    local CURSOR_FIELDS = { "m_CursorPosition", "CursorPosition", "m_CursorPos",
        "m_HoverPosition", "m_TargetPosition", "m_SelectedPosition", "m_CursorMapPosition",
        "m_AnalogCursorPosition", "m_MarkerSelectorPosition", "m_CurrentMapPosition",
        "m_PointerPosition", "m_LastCursorPosition", "m_MapCursorPosition", "m_MarkerPosition" }

    local function dumpFields(label, obj, names)
        local any = false
        for _, n in ipairs(names) do
            local v = try(function() return obj[n] end)
            if v ~= nil then log(string.format("    %s.%s = %s", label, n, fmt(v))); any = true end
        end
        if not any then log("    " .. label .. ": no candidate field read") end
    end

    local function dumpActorBox(a)
        local rc = try(function() return a.RootComponent end)
        if not isValid(rc) then log("      no root component"); return end
        log("      root = " .. (classPath(rc) or "?"))
        for _, n in ipairs({ "BoxExtent", "RelativeScale3D", "ComponentScale" }) do
            local v = try(function() return rc[n] end)
            if v ~= nil then log("      rc." .. n .. " = " .. fmt(v)) end
        end
        local bnd = try(function() return rc.Bounds end)
        if bnd ~= nil then
            log("      rc.Bounds.Origin=" .. fmt(try(function() return bnd.Origin end))
                .. " BoxExtent=" .. fmt(try(function() return bnd.BoxExtent end)))
        end
    end

    local function dumpMarkers(label, w)
        local arr = try(function() return w.m_CustomMarkers end)
        local n = try(function() return #arr end) or try(function() return arr:GetArrayNum() end)
        log("    " .. label .. ".m_CustomMarkers count = " .. tostring(n))
        if type(n) == "number" then
            for i = 1, n do
                local m = try(function() return arr[i] end)
                if m ~= nil then
                    log(string.format("      marker[%d] pos=%s tag=%s", i,
                        fmt(try(function() return m.m_MarkerPosition end)),
                        fmt(try(function() return m.m_MarkerTag end))))
                end
            end
        end
    end

    local function hunt()
        log("=== MAP HUNT (drop a marker at the cursor first) ===")
        local px, py = playerWorldPos()
        log("player world: " .. (px and string.format("(%.0f, %.0f)", px, py) or "??"))
        local widgets, mm = mapWidgets()
        if mm then dumpFields("MapMain", mm, CURSOR_FIELDS) end
        for _, e in ipairs(widgets) do
            local w = e[2]
            if try(function() return w.m_IsEmpty end) == false then
                log("[" .. e[1] .. "] dotCorrected=" .. field(w, "m_PlayerPosMapCorrected"))
                dumpFields(e[1], w, CURSOR_FIELDS)
                dumpMarkers(e[1], w)
                local d = try(function() return w.m_ActiveMapData end)
                if not isValid(d) then d = try(function() return w.m_MapData end) end
                if isValid(d) then
                    local b = try(function() return d.m_WorldMapBoundingBox end)
                    log("    MapData=" .. fullName(d) .. "  box=" .. fmt(b))
                    dumpFields("MapData", d, CONFIG_FIELDS)
                    if type(b) == "userdata" then
                        if try(function() return b:GetFullName() end) then
                            dumpActorBox(b)
                        else
                            log("    box tostring=" .. tostring(b)
                                .. "  get()=" .. fmt(try(function() return b:get() end))
                                .. "  [1]=" .. fmt(try(function() return b[1] end)))
                            log("    box.Min tostring=" .. tostring(try(function() return b.Min end)))
                            dumpFields("worldBox", b, BOX_FIELDS)
                        end
                    end
                end
            end
        end
        log("W_MapBoundingBox_C actor extents:")
        for _, a in ipairs(try(function() return FindAllOf("W_MapBoundingBox_C") end) or {}) do
            if isValid(a) then log("    " .. fullName(a)); dumpActorBox(a) end
        end
        log("=== end hunt ===")
    end

    -- --------------------------------------------------------------- calib --
    local function calib()
        local nx, ny = cursorNorm()
        local px, py = playerWorldPos()
        if not (nx and px) then log("calib: missing cursor or player position (be in-game, map open)"); return end
        -- also capture the map-space dot (m_PlayerPosMapCorrected). The cursor->world fit is
        -- specific to THIS aspect ratio; the map-space dot lets a resolution-independent
        -- map->world fit be built later (map space is a fixed 1600x900 for every player).
        local dx, dy, worldW
        for _, e in ipairs((mapWidgets())) do
            if try(function() return e[2].m_IsWorldMap end) == true then worldW = e[2] end
        end
        if worldW then
            dx = tonumber(try(function() return worldW.m_PlayerPosMapCorrected.X end))
            dy = tonumber(try(function() return worldW.m_PlayerPosMapCorrected.Y end))
        end
        CAL.pts[#CAL.pts + 1] = { nx = nx, ny = ny, wx = px, wy = py, dx = dx, dy = dy }
        log(string.format("calib point %d: norm(%.4f, %.4f) -> world(%.0f, %.0f) mapDot=%s",
            #CAL.pts, nx, ny, px, py, (dx and dy) and string.format("(%.1f, %.1f)", dx, dy) or "?"))
        for _, e in ipairs((mapWidgets())) do
            log(string.format("  %-9s empty=%s dot=%s", e[1], field(e[2], "m_IsEmpty"), field(e[2], "m_PlayerPosMapCorrected")))
        end
        local minx, maxx, miny, maxy = 1, 0, 1, 0
        for _, p in ipairs(CAL.pts) do
            minx, maxx = math.min(minx, p.nx), math.max(maxx, p.nx)
            miny, maxy = math.min(miny, p.ny), math.max(maxy, p.ny)
        end
        local spanx, spany = maxx - minx, maxy - miny
        local M, kept, dropped = robustFit(CAL.pts)
        if M then
            CAL.M = M
            if #kept == 3 then
                log("  EXACT fit (3 pts): residual 0 by definition. Add SPREAD points.")
            else
                log(string.format("  FIT over %d pts (dropped %d outlier%s), residual %.0f world units.",
                    #kept, dropped, dropped == 1 and "" or "s", residual(M, kept)))
            end
            log(string.format("  point spread: %.0f%% width, %.0f%% height%s", spanx * 100, spany * 100,
                (spanx < 0.3 or spany < 0.3) and "  <-- somewhat clustered" or ""))
            log("  tele is live (SHIFT+PAGE_DOWN).")
        else
            log("  need 3+ points (cursor on YOUR MARKER on the WORLD map, move to a NEW area, press again)")
        end
        log("  " .. (saveCalib() and ("saved to " .. tostring(CALIB_PATH)) or "NOT saved (disk write unavailable)"))
    end

    local function clearCalib()
        CAL.pts = {}; CAL.M = nil
        saveCalib()
        log("calibration cleared (and persisted). Record 3+ points (cursor on your marker, spread out).")
    end

    -- ----------------------------------------------------------------- move --
    -- Move the pawn to world (tx, ty), keeping current Z. The set call is the known
    -- sticking point (the FHitResult out-param), so we mirror TautelliniConsole: try the
    -- AngelScript world offset (the non-swept mover flight uses every frame), then the
    -- K2 set forms with the LIVE FVector (not a Lua table) both with and without the hit
    -- out-param, and VERIFY each by reading the position back. Returns the form that moved
    -- it, or nil. tol scales with distance.
    -- ground Z at world (x,y) via a downward line trace (LineTraceMod's proven pattern here:
    -- KismetSystemLibrary:LineTraceSingle with HitResult={} filled in place). nil if no hit.
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
    local GROUND_OFFSET = 120 -- lift above the trace hit so the capsule rests on the ground

    local function moveTo(pawn, tx, ty)
        local cx, cy, cz = rootPos(pawn)
        if not cx then return nil end
        local gz = groundZ(tx, ty)
        local tz = gz and (gz + GROUND_OFFSET) or cz
        log("  ground Z at target: " .. (gz and string.format("%.0f -> teleport Z %.0f", gz, tz) or "NO HIT, keeping current Z"))
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
            attempts[#attempts + 1] = { "rc:K2_SetWorldLocation(hit)",
                function() rc:K2_SetWorldLocation(liveVec(), false, {}, true) end }
            attempts[#attempts + 1] = { "rc:K2_SetWorldLocation(noHit)",
                function() rc:K2_SetWorldLocation(liveVec(), false, true) end }
            attempts[#attempts + 1] = { "pawn:K2_SetActorLocation(hit)",
                function() pawn:K2_SetActorLocation(liveVec(), false, {}, true) end }
        end
        local tol = math.max(50, ((tx - cx) ^ 2 + (ty - cy) ^ 2) ^ 0.5 * 0.02)
        for _, a in ipairs(attempts) do
            local ok, err = pcall(a[2])
            local nx, ny = rootPos(pawn)
            if nx and ((nx - tx) ^ 2 + (ny - ty) ^ 2) ^ 0.5 < tol then return a[1] end
            if not ok then log("  " .. a[1] .. " errored: " .. tostring(err)) end
        end
        return nil
    end

    -- world position of a UObject (SceneComponent or Actor)
    local function objWorld(o)
        if not isValid(o) then return nil end
        local x, y, z
        local ok = try(function() local v = o:K2_GetComponentLocation(); x, y, z = v.X, v.Y, v.Z; return true end)
        if ok and type(x) == "number" then return x, y, z end
        return rootPos(o)
    end

    -- ------------------------------------------------------------- validate --
    -- Test the ZERO-CALIBRATION pipeline. Put the cursor ON your player dot, then press.
    --  cursor -> map: contain-fit of UICustomSize centered in the viewport, vs the readable dot.
    --  map -> world: the box corner objects, vs your real world position.
    -- Small deltas on both = no calibration needed.
    local function validate()
        local Wx, Wy = playerWorldPos()
        local Cx, Cy = cursorRaw()
        local Vw, Vh = viewportSize()
        if not (Wx and Cx and Vw) then log("validate: missing player/cursor/viewport (be in-game, map open)"); return end
        local w
        for _, e in ipairs((mapWidgets())) do
            if try(function() return e[2].m_IsWorldMap end) == true then w = e[2] end
        end
        if not w then log("validate: open the WORLD map first"); return end
        local Dx = tonumber(try(function() return w.m_PlayerPosMapCorrected.X end))
        local Dy = tonumber(try(function() return w.m_PlayerPosMapCorrected.Y end))
        local d = try(function() return w.m_ActiveMapData end); if not isValid(d) then d = try(function() return w.m_MapData end) end
        local Ux = tonumber(try(function() return d.UICustomSize.X end))
        local Uy = tonumber(try(function() return d.UICustomSize.Y end))
        if not (Dx and Ux) then log("validate: could not read dot / UICustomSize"); return end
        log(string.format("validate: cursor(%.0f,%.0f) vp(%.0f,%.0f) dot(%.1f,%.1f) mapSize(%.0f,%.0f) world(%.0f,%.0f)",
            Cx, Cy, Vw, Vh, Dx, Dy, Ux, Uy, Wx, Wy))
        local scale = math.min(Vw / Ux, Vh / Uy)
        local rectL, rectT = (Vw - Ux * scale) / 2, (Vh - Uy * scale) / 2
        local mapX, mapY = (Cx - rectL) / scale, (Cy - rectT) / scale
        log(string.format("  cursor->map (contain-fit) = (%.1f, %.1f) vs dot (%.1f, %.1f)  dX=%.0f dY=%.0f",
            mapX, mapY, Dx, Dy, mapX - Dx, mapY - Dy))
        local b = try(function() return d.m_WorldMapBoundingBox end)
        local mnx, mny = objWorld(try(function() return b.Min end))
        local mxx, mxy = objWorld(try(function() return b.Max end))
        if mnx and mxx then
            log(string.format("  box.Min world=(%.0f, %.0f)  box.Max world=(%.0f, %.0f)", mnx, mny, mxx, mxy))
            local wx = mnx + (Dx / Ux) * (mxx - mnx)
            local wy = mny + (Dy / Uy) * (mxy - mny)
            log(string.format("  dot->world (box) = (%.0f, %.0f) vs real (%.0f, %.0f)  dX=%.0f dY=%.0f",
                wx, wy, Wx, Wy, wx - Wx, wy - Wy))
        else
            log("  box.Min/.Max world unreadable")
        end
    end

    -- ----------------------------------------------------------------- tele --
    local function teleportToCursor()
        if not CAL.M then log("tele: not calibrated. SHIFT+PAGE_UP on your marker at 3+ spread spots first."); return end
        local nx, ny = cursorNorm()
        if not nx then log("tele: no cursor"); return end
        local wx, wy = applyFit(CAL.M, nx, ny)
        local _, _, pz = playerWorldPos()
        log(string.format("tele: norm(%.4f, %.4f) -> world(%.0f, %.0f) keepZ=%s",
            nx, ny, wx, wy, pz and string.format("%.0f", pz) or "??"))
        local pawn = playerPawn()
        if not isValid(pawn) then log("tele: no player pawn"); return end
        local form = moveTo(pawn, wx, wy)
        log("tele: " .. (form and ("moved via " .. form) or "ALL move forms failed"))
    end

    -- ----------------------------------------------------------------- ptele --
    -- PORTABLE teleport, NO calibration. cursor->map computed from viewport + DPI scale
    -- (the map renders at UICustomSize * GetViewportScale, centered), then BAKED map->world
    -- (the world-map geography, identical for every player since map space is fixed).
    local MAPWORLD = { ax = -138.484464, cx = 227935.3681, ay = -131.972110, cy = -45186.9795 }
    local function viewportScale()
        local pc, wl = playerController(), lib("/Script/UMG.Default__WidgetLayoutLibrary")
        if not (isValid(pc) and isValid(wl)) then return nil end
        return tonumber(try(function() return wl:GetViewportScale(pc) end))
    end
    local function uiCustomSize()
        for _, e in ipairs((mapWidgets())) do
            if try(function() return e[2].m_IsWorldMap end) == true then
                local d = try(function() return e[2].m_ActiveMapData end) or try(function() return e[2].m_MapData end)
                local ux = isValid(d) and tonumber(try(function() return d.UICustomSize.X end)) or nil
                local uy = isValid(d) and tonumber(try(function() return d.UICustomSize.Y end)) or nil
                if ux and uy then return ux, uy end
            end
        end
        return 1600, 900
    end
    local function portableTele()
        local cx, cy = cursorRaw()
        local vw, vh = viewportSize()
        local dpi = viewportScale()
        local uw, uh = uiCustomSize()
        if not (cx and vw and dpi and dpi > 0) then log("ptele: missing cursor/viewport/DPI"); return end
        local mapX = (cx - (vw - uw * dpi) / 2) / dpi
        local mapY = (cy - (vh - uh * dpi) / 2) / dpi
        local wx = MAPWORLD.ax * mapX + MAPWORLD.cx
        local wy = MAPWORLD.ay * mapY + MAPWORLD.cy
        log(string.format("ptele: dpi=%.4f ui(%.0f,%.0f) cursor(%.0f,%.0f) -> map(%.1f,%.1f) -> world(%.0f,%.0f)",
            dpi, uw, uh, cx, cy, mapX, mapY, wx, wy))
        local pawn = playerPawn()
        if not isValid(pawn) then log("ptele: no pawn"); return end
        local form = moveTo(pawn, wx, wy)
        log("ptele: " .. (form and ("moved via " .. form) or "move failed"))
    end

    -- ------------------------------------------------------------- testmove --
    -- Move the player a fixed +1000,+1000 from current (a valid nearby spot, NO calibration)
    -- to isolate whether the move primitive works at all. Stops the movement component first
    -- (it can snap us back same-frame) and logs each form's actual displacement.
    local function testMove()
        local pawn = playerPawn()
        if not isValid(pawn) then log("testmove: no pawn"); return end
        local sx, sy, sz = rootPos(pawn)
        if not sx then log("testmove: no current pos"); return end
        local tx, ty = sx + 1000, sy + 1000
        local gz = groundZ(tx, ty)
        local tz = gz and (gz + GROUND_OFFSET) or sz
        log(string.format("testmove: start (%.0f, %.0f, %.0f) -> target (%.0f, %.0f, %.0f) [ground %s], expect ~1414 move",
            sx, sy, sz, tx, ty, tz, gz and string.format("%.0f", gz) or "no hit"))
        local rc = try(function() return pawn.RootComponent end)
        local mc = try(function() return pawn:GetGothicMovementComponent() end)
        local function stopMove() if isValid(mc) then pcall(function() mc:StopMovementImmediately() end) end end
        local function liveVec()
            local v = isValid(rc) and try(function() return rc:K2_GetComponentLocation() end) or nil
            if v then pcall(function() v.X, v.Y, v.Z = tx, ty, tz end) end
            return v
        end
        local aslib = asActorLib()
        local forms = {
            { "AS:AddActorWorldOffset", isValid(aslib), function() aslib:AddActorWorldOffset(pawn, { X = tx - sx, Y = ty - sy, Z = tz - sz }) end },
            { "rc:K2_SetWorldLocation(hit)", isValid(rc), function() rc:K2_SetWorldLocation(liveVec(), false, {}, true) end },
            { "rc:K2_SetWorldLocation(noHit)", isValid(rc), function() rc:K2_SetWorldLocation(liveVec(), false, true) end },
            { "pawn:K2_SetActorLocation(hit)", true, function() pawn:K2_SetActorLocation(liveVec(), false, {}, true) end },
            { "pawn:K2_TeleportTo", true, function() pawn:K2_TeleportTo({ X = tx, Y = ty, Z = tz }, { Pitch = 0, Yaw = 0, Roll = 0 }) end },
        }
        for _, f in ipairs(forms) do
            if not f[2] then log("  " .. f[1] .. ": skipped (handle missing)")
            else
                local bx, by = rootPos(pawn)
                stopMove()
                local ok, err = pcall(f[3])
                local ax, ay = rootPos(pawn)
                local d = (ax and bx) and ((ax - bx) ^ 2 + (ay - by) ^ 2) ^ 0.5 or -1
                log(string.format("  %-30s %s, moved %.0f (now %.0f, %.0f)", f[1],
                    ok and "ran" or ("THREW " .. tostring(err)), d, ax or -1, ay or -1))
            end
        end
        log("testmove done. A form that moved you ~1414 units is the one that works.")
    end

    -- ------------------------------------------------------------- jump --
    -- Teleport to the next W_MapBoundingBox_C actor origin (a real, spread-out world
    -- location), NO calibration needed. Cycle these to spread calibration points across
    -- the map: jump, record a calib point, jump, record, ...
    local function jumpPreset()
        local spots = {}
        for _, a in ipairs(try(function() return FindAllOf("W_MapBoundingBox_C") end) or {}) do
            if isValid(a) then
                local x, y = rootPos(a)
                if x then spots[#spots + 1] = { x = x, y = y } end
            end
        end
        if #spots == 0 then log("jump: no W_MapBoundingBox_C actors"); return end
        local i = ((tonumber(_G.__mapjump) or 0) % #spots) + 1
        _G.__mapjump = i
        local pawn = playerPawn()
        if not isValid(pawn) then log("jump: no pawn"); return end
        log(string.format("jump: preset %d/%d -> world(%.0f, %.0f)", i, #spots, spots[i].x, spots[i].y))
        local form = moveTo(pawn, spots[i].x, spots[i].y)
        log("jump: " .. (form and ("moved via " .. form) or "move failed"))
    end

    -- ------------------------------------------------- game map projection --
    -- THE CLEAN PATH (UFunction dump 2026-06-23): /Script/G1R.MapData exposes the game's OWN
    -- map<->world projection, which would drop the baked affine AND per-map calibration AND give city
    -- maps for free:
    --   GetNormalized2DPositionAndRotationFromActor(actor) -> the actor's 0..1 pos on the active map
    --   TeleportActorToNormalized2DPosition(actor, FVector2D norm) -> teleport there (game fast-travel)
    -- gread reads + verifies (SAFE, no move); gtele teleports to the cursor via the game func (MOVES).
    local function gameMapData()
        local cdo = lib("/Script/G1R.Default__MapData")
        if isValid(cdo) then
            local inst = try(function() return cdo:GetInstance() end)
            if isValid(inst) then return inst, "GetInstance" end
        end
        local mm = firstLive("MapMain")
        if mm then
            local md = try(function() return mm.m_MapData end)
            if isValid(md) then return md, "MapMain.m_MapData" end
        end
        local live = firstLive("MapData")
        if isValid(live) then return live, "firstLive" end
        return nil
    end

    -- the MapData of the CURRENTLY DISPLAYED map (area/city if that one is open, else world), so the
    -- teleport normalizes over THAT map and not the global world. Falls back to the global instance.
    local function activeMapData()
        local mm = firstLive("MapMain")
        if mm then
            for _, wn in ipairs({ "Map_Area", "Map_World" }) do
                local w = try(function() return mm[wn] end)
                if isValid(w) and try(function() return w.m_IsEmpty end) == false then
                    local md = try(function() return w.m_MapData end)
                    if isValid(md) then return md, wn .. ".m_MapData" end
                    md = try(function() return w.m_ActiveMapData end)
                    if isValid(md) then return md, wn .. ".m_ActiveMapData" end
                end
            end
        end
        return gameMapData()
    end

    local function classOrName(o)
        if not isValid(o) then return "nil" end
        return (fullName(o) or "?") .. "  [" .. (classPath(o) or "?") .. "]"
    end

    -- genum: with a map open, list every live MapData instance + the displayed widgets' data objects,
    -- so we can see whether a city map has its OWN MapData to teleport against. SAFE, no move.
    local function gameEnum()
        log("=== MAP DATA ENUM (open the map first) ===")
        local gi = gameMapData()
        log("GetInstance -> " .. classOrName(gi))
        local all = try(function() return FindAllOf("MapData") end) or {}
        log("FindAllOf('MapData'): " .. tostring(#all))
        for _, o in ipairs(all) do if isValid(o) then log("  " .. classOrName(o)) end end
        local mm = firstLive("MapMain")
        if mm then
            for _, wn in ipairs({ "Map_World", "Map_Area" }) do
                local w = try(function() return mm[wn] end)
                if isValid(w) then
                    log(string.format("%s isEmpty=%s", wn, tostring(try(function() return w.m_IsEmpty end))))
                    log("   m_MapData       = " .. classOrName(try(function() return w.m_MapData end)))
                    log("   m_ActiveMapData = " .. classOrName(try(function() return w.m_ActiveMapData end)))
                end
            end
        end
        log("=== end ===")
    end

    local function gameMapRead()
        log("=== GAME MAP API (read, SAFE) ===")
        local md, how = gameMapData()
        log("MapData instance: " .. (md and (fullName(md) .. " via " .. how) or "NOT FOUND"))
        if not md then log("=== end ==="); return end
        local pawn = playerPawn()
        if not isValid(pawn) then log("no player pawn"); log("=== end ==="); return end
        -- the func wants 3 params: (actor, outPos, outRot). Pass placeholders and read BOTH the
        -- return values and the in-place tables. Try a few rotation types until one does not throw.
        local forms = {
            { "pos{X,Y}, rot 0", function() local p = { X = 0, Y = 0 }
                return p, table.pack(md:GetNormalized2DPositionAndRotationFromActor(pawn, p, 0)) end },
            { "pos{X,Y}, rot{}", function() local p = { X = 0, Y = 0 }
                return p, table.pack(md:GetNormalized2DPositionAndRotationFromActor(pawn, p, {})) end },
            { "pos{}, rot{}", function() local p = {}
                return p, table.pack(md:GetNormalized2DPositionAndRotationFromActor(pawn, p, {})) end },
            { "pos{X,Y}, rot{Pitch,Yaw,Roll}", function() local p = { X = 0, Y = 0 }
                return p, table.pack(md:GetNormalized2DPositionAndRotationFromActor(pawn, p, { Pitch = 0, Yaw = 0, Roll = 0 })) end },
        }
        for _, f in ipairs(forms) do
            local ok, p, packed = pcall(f[2])
            if ok then
                log("GetNormalized OK [" .. f[1] .. "]  pos in-place = ("
                    .. tostring(p and p.X) .. ", " .. tostring(p and p.Y) .. ")")
                for i = 1, (packed and packed.n or 0) do
                    log(string.format("  ret[%d] %s = %s", i, type(packed[i]), fmt(packed[i])))
                end
                break
            else
                log("GetNormalized [" .. f[1] .. "] threw: " .. tostring(p))
            end
        end
        -- the readable dot / UICustomSize is our cursor-normalize basis; compare it to the game value
        local w
        for _, e in ipairs((mapWidgets())) do
            if try(function() return e[2].m_IsWorldMap end) == true then w = e[2] end
        end
        if w then
            local dx = tonumber(try(function() return w.m_PlayerPosMapCorrected.X end))
            local dy = tonumber(try(function() return w.m_PlayerPosMapCorrected.Y end))
            local uw, uh = uiCustomSize()
            if dx and uw then
                log(string.format("  player dot/UICustomSize = (%.4f, %.4f)  (compare to GetNormalized above)",
                    dx / uw, dy / uh))
            end
        end
        log("=== end ===")
    end

    local function gameTele()
        local md, how = activeMapData()
        if not md then log("gtele: MapData instance not found"); return end
        log("gtele: using " .. how .. " -> " .. classOrName(md))
        local pawn = playerPawn()
        if not isValid(pawn) then log("gtele: no pawn"); return end
        -- cursor -> normalized (0..1) via the DPI math, no calibration (same basis as the dot above)
        local cx, cy = cursorRaw()
        local vw, vh = viewportSize()
        local dpi = viewportScale()
        local uw, uh = uiCustomSize()
        if not (cx and vw and dpi and dpi > 0 and uw) then log("gtele: missing cursor/viewport/DPI/ui"); return end
        local mapX = (cx - (vw - uw * dpi) / 2) / dpi
        local mapY = (cy - (vh - uh * dpi) / 2) / dpi
        local nx, ny = mapX / uw, mapY / uh
        local bx, by, bz = playerWorldPos()
        log(string.format("gtele: cursor(%.0f,%.0f) -> norm(%.4f, %.4f) via %s; from (%.0f,%.0f,%.0f)",
            cx, cy, nx, ny, how, bx or -1, by or -1, bz or -1))
        local ok, err = pcall(function() md:TeleportActorToNormalized2DPosition(pawn, { X = nx, Y = ny }) end)
        if not ok then log("gtele: CALL THREW " .. tostring(err)) end
        local ax, ay, az = playerWorldPos()
        local moved = (ax and bx) and ((ax - bx) ^ 2 + (ay - by) ^ 2) ^ 0.5 or -1
        log(string.format("gtele: now (%.0f, %.0f, %.0f), moved %.0f units%s",
            ax or -1, ay or -1, az or -1, moved, ok and "" or " (call threw, see above)"))
    end

    -- gcal: cycle-teleport to KNOWN normalized points and read where we land in WORLD, to nail down
    -- the basis TeleportActorToNormalized2DPosition uses (its norm->world transform). World is read
    -- immediately and is reliable (the dots lag a frame, so they are not used here). Press repeatedly
    -- (paced, throwaway save): each press jumps to the next point and logs (norm -> world).
    local GCAL_PTS = { { 0.25, 0.25 }, { 0.75, 0.25 }, { 0.25, 0.75 }, { 0.75, 0.75 }, { 0.50, 0.50 } }
    local function gameCal()
        local md = gameMapData()
        if not md then log("gcal: no MapData"); return end
        local pawn = playerPawn()
        if not isValid(pawn) then log("gcal: no pawn"); return end
        local i = ((tonumber(_G.__gcal) or 0) % #GCAL_PTS) + 1
        _G.__gcal = i
        local nx, ny = GCAL_PTS[i][1], GCAL_PTS[i][2]
        local ok, err = pcall(function() md:TeleportActorToNormalized2DPosition(pawn, { X = nx, Y = ny }) end)
        local wx, wy, wz = playerWorldPos()
        log(string.format("gcal %d/%d: norm(%.3f, %.3f) -> world(%.0f, %.0f, %.0f)%s",
            i, #GCAL_PTS, nx, ny, wx or -1, wy or -1, wz or -1, ok and "" or (" THREW " .. tostring(err))))
    end

    return {
        name = "map",
        actions = {
            { id = "read",  desc = "READ player/cursor/widgets/box actors + calib status", fn = readAll },
            { id = "calib", desc = "RECORD a calibration point (cursor on your marker)",    fn = calib },
            { id = "tele",  desc = "DANGER: teleport player to cursor (throwaway save)",     fn = teleportToCursor },
            { id = "clear", desc = "CLEAR calibration points",                              fn = clearCalib },
            { id = "hunt",  desc = "HUNT direct cursor-in-map + bounding box (marker first)", fn = hunt },
            { id = "testmove", desc = "TEST move: shift player +1000,+1000 (no calibration)",   fn = testMove },
            { id = "validate", desc = "VALIDATE zero-cal pipeline (cursor on your dot)",         fn = validate },
            { id = "jump",     desc = "JUMP to next map-region preset (spread, no calibration)", fn = jumpPreset },
            { id = "ptele",    desc = "PORTABLE teleport: DPI-computed cursor + baked map->world (NO calib)", fn = portableTele },
            { id = "gread",    desc = "READ game MapData + player's normalized map pos (SAFE, no move)", fn = gameMapRead },
            { id = "gtele",    desc = "DANGER: teleport to cursor via game MapData func (throwaway save)", fn = gameTele },
            { id = "gcal",     desc = "CALIBRATE: cycle-teleport known norm points, log world (throwaway save)", fn = gameCal },
            { id = "genum",    desc = "ENUM live MapData instances + the open widgets' data (SAFE)", fn = gameEnum },
        },
    }
end
