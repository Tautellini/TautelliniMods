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
local rawget, rawset, debug = rawget, rawset, debug

local ModVersion = "0.1.0"

-- vendored kit lives at <Mod>/shared/; add it from this file's own location.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;" .. ModDir .. "/shared/?.lua;" .. package.path
end

-- hot reload: nil every module before re-requiring, and full-sweep the path cache.
local MODULES = { "kit", "config", "core.engine_travel", "travel.pipeline",
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
    Config = { onMapTeleport = true, hotkey = "T", debug = false }
end

local Engine    = tryRequire("core.engine_travel")
local Pipeline  = tryRequire("travel.pipeline")
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
local SAVED_KEYS = { "onMapTeleport" }
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

-- cursor on the open world map -> world -> move. Runs on the game thread (via run).
local function doMapTeleport()
    local cdx, cdy, dw, dh, dpi = Engine.screenParams()
    local uw, uh = Engine.worldMapSize()
    if Config.debug then
        log(string.format("t: cursor=%s designVP=%s dpi=%s mapSize=%s",
            cdx and string.format("(%.0f,%.0f)", cdx, cdy) or "nil",
            dw and string.format("(%.0f,%.0f)", dw, dh) or "nil",
            dpi and string.format("%.4f", dpi) or "nil",
            uw and string.format("(%.0f,%.0f)", uw, uh) or "nil (world map not open)"))
    end
    if not cdx or not uw then return end
    local mapX, mapY = Pipeline.cursorToMap(cdx, cdy, dw, dh, uw, uh)
    local on = Pipeline.inMap(mapX, mapY, uw, uh, 0)
    if Config.debug then
        log(string.format("t: -> map(%.1f, %.1f) inMap=%s", mapX or -1, mapY or -1, tostring(on)))
    end
    if not on then return end
    local M = MapCalib.world and MapCalib.world.M
    if not M then return end
    local off = (MapCalib.world and MapCalib.world.cursorOffset) or { x = 0, y = 0 }
    local wx, wy = Pipeline.mapToWorld(M, mapX + (off.x or 0), mapY + (off.y or 0))
    local form = Engine.teleport(wx, wy)
    if Config.debug then
        log(string.format("t: -> world(%.0f, %.0f) %s", wx, wy, form and ("via " .. form) or "FAILED"))
    end
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
    local form = Engine.teleport(loc.x, loc.y, loc.z)
    log("Travel to " .. tostring(loc.name) .. (form and "" or " FAILED (be in-game on a valid save)"))
end

-- ----------------------------------------------- shared mod menu (optional) --
if kit.menu and kit.menu.register then
    local sections = {}
    sections[#sections + 1] = { title = "Fast Travel", items = {
        { name = "On-Map Teleport", kind = "bool",
          get = function() return Config.onMapTeleport == true end,
          set = function(v)
              Config.onMapTeleport = v and true or false
              log("On-map teleport " .. (Config.onMapTeleport and "ON" or "OFF"))
              saveSettings()
          end },
    } }
    local quick = {}
    for _, loc in ipairs(Locations) do
        if type(loc) == "table" and loc.name and loc.x and loc.y then
            quick[#quick + 1] = { name = loc.name, kind = "action", set = function() run(function() doQuickTravel(loc) end) end }
        end
    end
    if #quick > 0 then sections[#sections + 1] = { title = "Quick Travel", items = quick } end
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

-- ----------------------------------------------------------------- banner --
log("Loaded " .. ModVersion .. " (kit " .. tostring(kit.version) .. "): on-map teleport "
    .. (Config.onMapTeleport and "on" or "off") .. " (key " .. (rawget(_G, "__ftw_bound") or HotkeyName)
    .. "), " .. #Locations .. " quick-travel location(s)")
