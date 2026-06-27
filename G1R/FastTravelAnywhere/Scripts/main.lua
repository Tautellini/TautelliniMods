-- FastTravelAnywhere for Gothic 1 Remake -- point the world map and press the hotkey to teleport
-- there, plus a curated quick-travel list in the SharedModMenu.
--
-- Mechanism (see [[map-teleport-mod]]): the on-screen map placement is computed live from the DPI
-- scale (so it is resolution/aspect independent, no per-player calibration), the map->world
-- geography is the baked affine in data/mapcalib, and the move is AngelScript AddActorWorldOffset
-- with a ground line-trace. The engine adapter (core/engine_travel) is the only file that touches
-- the engine; the cursor->map->world math (travel/pipeline) and the data are pure.

local ipairs, pairs, tostring, type = ipairs, pairs, tostring, type
local pcall, require, os, string = pcall, require, os, string
local rawget, rawset, debug, math = rawget, rawset, debug, math

local ModVersion = "0.3.0"

-- vendored kit lives at <Mod>/shared/; add it from this file's own location.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;" .. ModDir .. "/shared/?.lua;" .. package.path
end

-- hot reload: nil every module before re-requiring, and full-sweep the path cache.
local MODULES = { "kit", "config", "core.engine_travel", "travel.pipeline", "travel.cost",
    "data.mapcalib", "data.locations", "core.settings" }
for _, m in ipairs(MODULES) do package.loaded[m] = nil end
do
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then for k in pairs(reg) do reg[k] = nil end end
end

local okKit, kit = pcall(require, "kit")
if not okKit or type(kit) ~= "table" then
    print("[FastTravelAnywhere] FATAL: shared kit not found (" .. tostring(kit)
        .. "). Re-deploy; the kit vendors under <Mod>/shared/.\n")
    return
end
local log = kit.log.make("[FastTravelAnywhere]")
local function tryRequire(name) return kit.boot.tryRequire(name, log) end

local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = { onMapTeleport = true, hotkey = "T", debug = false,
        immersiveMode = false, oreCostPer100m = 3, oreCostMin = 3, oreCostMax = 50,
        currencyItem = "ItMi_Orenugget", advanceTime = true, timeMinutesPer100m = 20, maxTimeAdvanceMin = 180,
        timeSkipDelaySec = 2.0 }
end

local Engine    = tryRequire("core.engine_travel")
local Pipeline  = tryRequire("travel.pipeline")
local Cost      = tryRequire("travel.cost")
local MapCalib  = tryRequire("data.mapcalib")
local Locations = tryRequire("data.locations")
local Settings  = tryRequire("core.settings")
if not (Engine and Pipeline and MapCalib) then
    log("FATAL: a core module failed to load; FastTravelAnywhere disabled")
    return
end
if type(Locations) ~= "table" then Locations = {} end

-- ----------------------------------------------------------- persistence --
local SavedPath = ModDir and (ModDir .. "/saved_settings.lua") or nil
local SAVED_KEYS = { "onMapTeleport",
    "immersiveMode", "advanceTime", "oreCostPer100m", "oreCostMin", "oreCostMax", "timeMinutesPer100m" }
if Settings and SavedPath then
    local saved = Settings.load(SavedPath)
    for _, key in ipairs(SAVED_KEYS) do
        if saved[key] ~= nil then Config[key] = saved[key] end
    end
end
local function saveSettings()
    if not (Settings and SavedPath) then return end
    local out = {}
    for _, key in ipairs(SAVED_KEYS) do out[key] = Config[key] end
    Settings.save(SavedPath, out)
end

-- ------------------------------------------------------------- teleport --
-- Every teleport goes through run(): it marshals the work onto the game thread but dispatches only
-- ONE ExecuteInGameThread at a time (the `busy` guard) and paces dispatches. That is what guards
-- UE4SS's reentrant deferred-queue heap corruption (#1180): the crash came from per-press
-- ExecuteInGameThread stacking up under rapid use. No continuous loop -- this mod has no ongoing
-- work, so we only touch the game thread when the player actually triggers a teleport.
local ExecuteInGameThread = rawget(_G, "ExecuteInGameThread")
local busy, lastRun = false, 0
local function run(fn)
    if busy then return end -- a game-thread pass is already in flight
    local now = os.clock()
    local cd = type(Config.teleportCooldown) == "number" and Config.teleportCooldown or 1.0
    if now - lastRun < cd then return end -- pace presses; a teleport + area load takes a moment
    lastRun = now
    busy = true
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(function() pcall(fn); busy = false end)
    else
        pcall(fn); busy = false
    end
end

-- the readout's per-session cache (see readoutTick). Set when the map opens, dropped on close or
-- right after a teleport. It holds everything that stays constant while the map is up (player
-- position, ore, map + viewport metrics) so the per-frame readout never re-reads those from the
-- engine -- only the cursor is read each frame.
local readoutSess = nil
-- timestamps gating WHEN the readout may draw. The menu never touches UI except in a stable state, so
-- neither do we: stay hidden for PORT_DEBOUNCE s after a teleport (the area is streaming) and for
-- SETTLE s after the map opens (its UI is still building). os.clock is seconds, monotonic enough here.
local readoutPortAt = -100
local readoutMapSince = nil

-- ----------------------------------------------------------- immersive --
-- With Immersive Mode on, a teleport costs ore (Erzbrocken) by distance and optionally advances the
-- clock. Cost + affordability use the pure travel.cost math and the engine economy reads. The gate
-- is fail-OPEN: if the ore count cannot be read we do not block travel.
local function immersive() return Config.immersiveMode == true and Cost ~= nil end

-- ore cost and distance (world units) of a jump to world (tx, ty), or nil when immersive mode is
-- off or the player position is unknown.
local function costFor(tx, ty)
    if not immersive() then return nil end
    local px, py = Engine.playerPos()
    if not px then return nil end
    local d = Cost.distance(px, py, tx, ty)
    return Cost.ore(d, { per100m = Config.oreCostPer100m, minCost = Config.oreCostMin, maxCost = Config.oreCostMax }), d
end

-- gate before a teleport: true if affordable (or immersive off / ore unreadable). Logs when too poor.
local function canAfford(cost)
    if not cost then return true end
    local have = Engine.itemCount(Config.currencyItem)
    if have == nil then return true end -- ore unreadable: fail-open, never block on a read failure
    if have < cost then log(string.format("Not enough ore: need %d, have %d.", cost, have)); return false end
    return true
end

-- defer the time skip until the teleported-into area has streamed in. SkipTime runs world catch-up
-- on worker threads, and doing it immediately raced the area streaming and crashed the game. Rapid
-- teleports accumulate and only ONE skip runs once the player settles for the delay (a token
-- supersedes earlier schedules), so a skip never overlaps a still-streaming area.
local function scheduleTimeSkip(mins)
    if not (mins and mins > 0) then return end
    rawset(_G, "__ftw_pendMins", (rawget(_G, "__ftw_pendMins") or 0) + mins)
    local token = (rawget(_G, "__ftw_skipTok") or 0) + 1
    rawset(_G, "__ftw_skipTok", token)
    local fire = function()
        if rawget(_G, "__ftw_skipTok") ~= token then return end -- a newer teleport superseded this
        local total = rawget(_G, "__ftw_pendMins") or 0
        rawset(_G, "__ftw_pendMins", 0)
        if total > 0 then Engine.advanceTime(total * 60) end
    end
    local delaySec = type(Config.timeSkipDelaySec) == "number" and Config.timeSkipDelaySec or 2.0
    local delayMs = math.max(250, delaySec * 1000)
    if kit.async and kit.async.gameDelay then kit.async.gameDelay(delayMs, fire) else fire() end
end

-- after a CONFIRMED teleport: deduct the ore now and schedule the time skip for after the area loads.
local function settle(cost, dist)
    if not (immersive() and cost) then return end
    Engine.spendItem(Config.currencyItem, cost)
    local mins = (Config.advanceTime ~= false)
        and (Cost.travelMinutes(dist, { minutesPer100m = Config.timeMinutesPer100m, max = Config.maxTimeAdvanceMin }) or 0)
        or 0
    if mins > 0 then scheduleTimeSkip(mins) end
    log(string.format("Travelled for %d ore%s.", cost,
        mins > 0 and (", +" .. math.floor(mins) .. " min after loading") or ""))
end

-- cursor on the open world map -> world target (worldX, worldY, cursorX, cursorY), or nil if the
-- cursor is off the map or the map is closed. Shared by the teleport and the readout so they agree.
local function mapTarget()
    local cdx, cdy, dw, dh = Engine.screenParams()
    local uw, uh = Engine.worldMapSize()
    if not cdx or not uw then return nil end
    local mapX, mapY = Pipeline.cursorToMap(cdx, cdy, dw, dh, uw, uh)
    if not Pipeline.inMap(mapX, mapY, uw, uh, 0) then return nil end
    local M = MapCalib.world and MapCalib.world.M
    if not M then return nil end
    local off = (MapCalib.world and MapCalib.world.cursorOffset) or { x = 0, y = 0 }
    local wx, wy = Pipeline.mapToWorld(M, mapX + (off.x or 0), mapY + (off.y or 0))
    return wx, wy, cdx, cdy
end

-- press: teleport to the cursor on the open world map. Runs on the game thread (via run).
local function doMapTeleport()
    local wx, wy = mapTarget()
    if not wx then if Config.debug then log("t: cursor not on the open world map") end return end
    local cost, dist = costFor(wx, wy)
    if not canAfford(cost) then return end
    Engine.closeMap() -- close the map FIRST (stable state) so it never lingers stale or streams open
    local form, reason = Engine.teleport(wx, wy)
    if form then
        settle(cost, dist)
        readoutSess = nil; readoutPortAt = (os.clock and os.clock()) or readoutPortAt -- hide readout while the area streams
        if Config.debug then log(string.format("t: -> world(%.0f, %.0f) via %s", wx, wy, form)) end
    elseif Config.debug then
        log(string.format("t: -> world(%.0f, %.0f) FAILED (%s)", wx, wy, tostring(reason)))
    end
end

-- readout driver tick. While immersive + on-map teleport are on and the world map is the active
-- screen, a tooltip panel follows the cursor with distance, ore cost (red when unaffordable) and
-- travel time. The cursor is the ONLY input that changes while the map is open, so the constants
-- (player position, ore, map + viewport metrics) are read ONCE per map session into readoutSess and
-- only the cursor is read each frame. This keeps the heavy game reads -- the inventory walk and the
-- pawn read, which crashed when called every frame on a transiently freed object -- out of the
-- per-frame path. Handles are re-resolved fresh on each open (clearTravelCaches), so a save-load
-- between map sessions cannot leave a stale handle behind.
local SETTLE, PORT_DEBOUNCE = 1.0, 1.0
local function readoutTick()
    local now = (os.clock and os.clock()) or 0
    if not (immersive() and Config.onMapTeleport == true) then
        readoutSess = nil; readoutMapSince = nil; Engine.readoutHide(); return
    end
    if not Engine.mapActive() then
        -- off the map: pre-build the panel + warm the handles during calm gameplay, but NOT during the
        -- post-port window (re-resolving pawn/controller while the area streams could hit a transient).
        -- mapActive itself is safe now: it reads the NotifyOnNewObject-captured MapMain, never scans.
        readoutSess = nil; readoutMapSince = nil
        Engine.readoutHide()
        if (now - readoutPortAt) >= PORT_DEBOUNCE then Engine.readoutBuild(); Engine.warmTravel() end
        return
    end
    if readoutMapSince == nil then readoutMapSince = now end
    -- draw ONLY in a stable state: a beat after the map opens, and well clear of a teleport. Touching
    -- UI in those two windows is what crashed; the menu only ever draws when stable, so we match it.
    if (now - readoutMapSince) < SETTLE or (now - readoutPortAt) < PORT_DEBOUNCE then
        Engine.readoutHide(); return
    end
    if readoutSess == nil then
        local px, py = Engine.playerPos()
        if not px then return end -- pawn not ready yet; retry next tick
        local _, _, dw, dh, dpi = Engine.screenParams()
        local uw, uh = Engine.worldMapSize()
        if not (dw and uw and dpi and dpi > 0) then return end -- metrics not ready yet; retry next tick
        readoutSess = { px = px, py = py, dw = dw, dh = dh, uw = uw, uh = uh, dpi = dpi,
            ore = Engine.itemCount(Config.currencyItem) }
    end
    local s = readoutSess
    local rx, ry = Engine.cursorHud()
    if not rx then Engine.readoutHide() return end
    local cdx, cdy = rx / s.dpi, ry / s.dpi -- HUD px -> design space (timer-safe property read)
    local mapX, mapY = Pipeline.cursorToMap(cdx, cdy, s.dw, s.dh, s.uw, s.uh)
    if not Pipeline.inMap(mapX, mapY, s.uw, s.uh, 0) then Engine.readoutHide() return end
    local M = MapCalib.world and MapCalib.world.M
    if not M then Engine.readoutHide() return end
    local off = (MapCalib.world and MapCalib.world.cursorOffset) or { x = 0, y = 0 }
    local wx, wy = Pipeline.mapToWorld(M, mapX + (off.x or 0), mapY + (off.y or 0))
    local d = Cost.distance(s.px, s.py, wx, wy)
    local c = Cost.ore(d, { per100m = Config.oreCostPer100m, minCost = Config.oreCostMin, maxCost = Config.oreCostMax })
    local affordable = (s.ore == nil) or (s.ore >= c)
    local line2
    if affordable then
        line2 = "This will cost " .. c .. " ore" .. (s.ore ~= nil and (" (have " .. s.ore .. ")") or "")
    else
        line2 = "Not enough ore: need " .. c .. (s.ore ~= nil and (", have " .. s.ore) or "")
    end
    local line3
    if Config.advanceTime ~= false then
        local mins = Cost.travelMinutes(d, { minutesPer100m = Config.timeMinutesPer100m, max = Config.maxTimeAdvanceMin })
        if mins and mins >= 1 then line3 = "Travel time: " .. Cost.formatMinutes(mins) end
    end
    -- fixed panel: its top-right corner sits INSIDE the map's upper-right (design space), inset left +
    -- down so it clears the map frame, and stays put while the cursor moves -- only the numbers change.
    local anchorX = (s.dw + s.uw) / 2 - 50
    local anchorY = (s.dh - s.uh) / 2 + 60
    local hk = (type(Config.hotkey) == "string" and Config.hotkey ~= "") and Config.hotkey or nil
    local header = hk and ("[" .. hk .. "] for Travel") or "Fast Travel"
    Engine.readoutUpdate(header, "You will travel " .. Cost.formatDistance(d), line2, line3, not affordable, anchorX, anchorY)
end

-- log the current position as a ready-to-paste locations.lua entry. Game-thread, via the driver.
local function doCapture()
    local x, y, z = Engine.playerPos()
    if x then
        log(string.format("CAPTURE  { name = \"?\", x = %.0f, y = %.0f, z = %.0f },", x, y, z or 0))
    else
        log("CAPTURE: no player position (be in-game on a save)")
    end
end

-- teleport to a curated location. Game-thread, via the driver.
local function doQuickTravel(loc)
    local cost, dist = costFor(loc.x, loc.y)
    if not canAfford(cost) then return end
    local form = Engine.teleport(loc.x, loc.y)
    if form then
        settle(cost, dist)
        readoutSess = nil; readoutPortAt = (os.clock and os.clock()) or readoutPortAt -- hide readout while the area streams
        log("Travel to " .. tostring(loc.name) .. (cost and (" (" .. cost .. " ore)") or ""))
    else
        log("Travel to " .. tostring(loc.name) .. " FAILED (be in-game on a valid save)")
    end
end

-- ----------------------------------------------- shared mod menu (optional) --
-- Sections render in the order listed here: the quick-travel list first, then the on-map teleport
-- options below it.
if kit.menu and kit.menu.register then
    local sections = {}

    local quick = {}
    for _, loc in ipairs(Locations) do
        if type(loc) == "table" and loc.name and loc.x and loc.y then
            quick[#quick + 1] = { name = loc.name, kind = "action", set = function() run(function() doQuickTravel(loc) end) end }
        end
    end
    if #quick > 0 then sections[#sections + 1] = { title = "Quick Travel", items = quick } end

    sections[#sections + 1] = { title = "Immersive Mode", items = {
        { name = "Immersive Mode", kind = "bool",
          get = function() return Config.immersiveMode == true end,
          set = function(v)
              Config.immersiveMode = v and true or false
              log("Immersive mode " .. (Config.immersiveMode and "ON (travel costs ore)" or "OFF (free travel)"))
              if not Config.immersiveMode then -- loop will idle; collapse any lingering readout once
                  readoutSess = nil
                  local g = rawget(_G, "ExecuteInGameThread")
                  if g then g(function() Engine.readoutHide() end) else Engine.readoutHide() end
              end
              saveSettings()
          end },
        { name = "Advance Time", kind = "bool",
          get = function() return Config.advanceTime ~= false end,
          set = function(v)
              Config.advanceTime = v and true or false
              log("Advance time on travel " .. (Config.advanceTime and "ON" or "OFF"))
              saveSettings()
          end },
        { name = "Ore Cost / 100m", kind = "num", min = 0, max = 100, step = 1,
          get = function() return Config.oreCostPer100m or 0 end,
          set = function(v)
              Config.oreCostPer100m = math.max(0, math.floor((v or 0) + 0.5))
              saveSettings()
          end },
        { name = "Min Ore Cost", kind = "num", min = 0, max = 100, step = 1,
          get = function() return Config.oreCostMin or 0 end,
          set = function(v) Config.oreCostMin = math.max(0, math.floor((v or 0) + 0.5)); saveSettings() end },
        { name = "Max Ore Cost", kind = "num", min = 0, max = 1000, step = 10,
          get = function() return Config.oreCostMax or 0 end,
          set = function(v) Config.oreCostMax = math.max(0, math.floor((v or 0) + 0.5)); saveSettings() end },
        { name = "Time / 100m (min)", kind = "num", min = 0, max = 120, step = 5,
          get = function() return Config.timeMinutesPer100m or 0 end,
          set = function(v) Config.timeMinutesPer100m = math.max(0, math.floor((v or 0) + 0.5)); saveSettings() end },
    } }

    sections[#sections + 1] = { title = "World Map Options", items = {
        { name = "On-Map Teleport", kind = "bool",
          get = function() return Config.onMapTeleport == true end,
          set = function(v)
              Config.onMapTeleport = v and true or false
              log("On-map teleport " .. (Config.onMapTeleport and "ON" or "OFF"))
              saveSettings()
          end },
    } }

    pcall(kit.menu.register, "FastTravelAnywhere", sections)
    log("SharedModMenu: registered " .. #sections .. " section(s) (a tab appears if the "
        .. "SharedModMenu mod is installed)")
end

-- ------------------------------------------------------ on-map hotkey (tail) --
-- Register the raw keybind ONCE (UE4SS keeps it across CTRL+R) and dispatch through a _G trampoline
-- that every load refreshes, so edits take effect on reload without double-binding. run() handles
-- the cooldown + single-in-flight guard. Changing the hotkey itself needs a full restart.
local Key = rawget(_G, "Key")
local RegisterKeyBind = rawget(_G, "RegisterKeyBind")
local HotkeyName = type(Config.hotkey) == "string" and Config.hotkey or ""

local ModifierKey = rawget(_G, "ModifierKey")
rawset(_G, "__ftw_handler", function()
    if Config.onMapTeleport ~= true then return end
    run(doMapTeleport)
end)
-- Shift+hotkey trampoline (capture current coords); the handler gates on captureCoords.
rawset(_G, "__ftw_coords_handler", function()
    if Config.captureCoords ~= true then return end
    run(doCapture)
end)

if not rawget(_G, "__ftw_bound") then
    if HotkeyName ~= "" and Key and Key[HotkeyName] and RegisterKeyBind then
        local ok = pcall(RegisterKeyBind, Key[HotkeyName], function()
            local f = rawget(_G, "__ftw_handler"); if f then f() end
        end)
        if ok then rawset(_G, "__ftw_bound", HotkeyName)
        else log("ERROR: could not bind on-map teleport hotkey '" .. HotkeyName .. "'") end
    elseif HotkeyName ~= "" then
        log("ERROR: unknown hotkey '" .. HotkeyName .. "'; on-map teleport key not bound")
    end
elseif rawget(_G, "__ftw_bound") ~= HotkeyName then
    log("hotkey change to '" .. HotkeyName .. "' needs a full game restart (was '"
        .. tostring(rawget(_G, "__ftw_bound")) .. "')")
end

-- Shift + hotkey for coordinate capture (always bound; the handler no-ops unless captureCoords).
if not rawget(_G, "__ftw_coords_bound") then
    if HotkeyName ~= "" and Key and Key[HotkeyName] and RegisterKeyBind and ModifierKey and ModifierKey.SHIFT then
        local ok = pcall(RegisterKeyBind, Key[HotkeyName], { ModifierKey.SHIFT }, function()
            local f = rawget(_G, "__ftw_coords_handler"); if f then f() end
        end)
        if ok then rawset(_G, "__ftw_coords_bound", true) end
    end
end

-- ----------------------------------------------- map capture (tail) --
-- Capture the MapMain widget the moment the game CONSTRUCTS it (NotifyOnNewObject), instead of the
-- readout scanning for it with FindAllOf every tick. The map widget is destroyed on close and rebuilt
-- on open, and a scan that ran while it was mid-build grabbed a half-constructed object and crashed.
-- NotifyOnNewObject hands us the handle post-construction; engine.mapActive just revalidates it.
-- Registered ONCE behind a _G flag; a _G trampoline refreshed each load runs the current code.
local NotifyOnNewObject = rawget(_G, "NotifyOnNewObject")
rawset(_G, "__ftw_mapNotify", function(obj) pcall(function() Engine.setMapMain(obj) end) end)
if type(NotifyOnNewObject) == "function" and not rawget(_G, "__ftw_mapNotifyReg") then
    -- NotifyOnNewObject needs the FULL class path (unlike FindAllOf, which takes the short name).
    local ok = pcall(NotifyOnNewObject, "/Script/G1R.MapMain", function(obj)
        local f = rawget(_G, "__ftw_mapNotify"); if f then f(obj) end
    end)
    if ok then rawset(_G, "__ftw_mapNotifyReg", true); log("readout: capturing MapMain via NotifyOnNewObject (no per-tick scan)")
    else log("readout: NotifyOnNewObject(MapMain) FAILED; the live readout will not detect the map") end
end

-- ----------------------------------------------------- readout driver (tail) --
-- Driver is a game-thread timer (kit.async). RegisterHook on a per-frame UFunction is a DEAD END here:
-- Actor:ReceiveTick and UserWidget:Tick both ARM but NEVER fire (Blueprint-event dispatch bypasses
-- UE4SS's UFunction hook on this build), and PlayerTick is not registrable. The timer is the only
-- per-frame mechanism that reaches the open map. To make it safe we removed the one per-tick call the
-- menu never makes from a loop -- the slate cursor QUERY -- and read the cursor from a HUD PROPERTY
-- instead (engine.cursorHud), so per-tick is property reads + our own stable widget. Idles when
-- immersive is off; started once behind a _G flag; a _G decision refreshed each load.
local readoutWork = function() pcall(readoutTick) end
rawset(_G, "__ftw_readoutDecide", function()
    if Config.immersiveMode ~= true or Config.onMapTeleport ~= true then return nil end
    return readoutWork
end)
if kit.async and kit.async.gameLoop and not rawget(_G, "__ftw_readoutLoop") then
    rawset(_G, "__ftw_readoutLoop", true)
    kit.async.gameLoop(150, function()
        local d = rawget(_G, "__ftw_readoutDecide")
        return d and d() or nil
    end)
end

-- ----------------------------------------------------------------- banner --
log("Loaded " .. ModVersion .. " (kit " .. tostring(kit.version) .. "): on-map teleport "
    .. (Config.onMapTeleport and "on" or "off") .. " (key " .. (rawget(_G, "__ftw_bound") or HotkeyName)
    .. "), immersive " .. (Config.immersiveMode and ("ON (" .. (Config.oreCostPer100m or 0) .. " ore/100m"
        .. (Config.advanceTime ~= false and " +time" or "") .. ")") or "off")
    .. ", " .. #Locations .. " quick-travel location(s)")
