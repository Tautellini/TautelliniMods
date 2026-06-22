-- CameraSettings for Gothic 1 Remake -- live camera tuning published to the SharedModMenu.
--
-- Mechanism: the GothicCameraManager applies the AngelScript DefaultCamera config every
-- frame, so we set that config ONCE per change and it sticks, no per-tick reapply. The
-- adapter (core/engine_camera) is the only file that touches the engine; the catalog
-- (camera/surface) and persistence (core/settings) are pure. See plans/camera-settings.md
-- and the [[g1r-camera-control]] memory.

local ipairs, pairs, tostring, tonumber = ipairs, pairs, tostring, tonumber
local type, pcall, print, require, next = type, pcall, print, require, next
local rawget, debug = rawget, debug

local ModVersion = "0.1.0-alpha"

-- vendored kit lives at <Mod>/shared/; add it from this file's own location.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;" .. ModDir .. "/shared/?.lua;" .. package.path
end

-- hot reload: nil every module before re-requiring, and full-sweep the path cache.
local MODULES = { "kit", "config", "camera.surface", "core.engine_camera", "core.settings" }
for _, m in ipairs(MODULES) do package.loaded[m] = nil end
do
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then for k in pairs(reg) do reg[k] = nil end end
end

local okKit, kit = pcall(require, "kit")
if not okKit or type(kit) ~= "table" then
    print("[CameraSettings] FATAL: shared kit not found (" .. tostring(kit)
        .. "). Re-deploy; the kit vendors under <Mod>/shared/.\n")
    return
end
local log = kit.log.make("[CameraSettings]")

local function tryRequire(name) return kit.boot.tryRequire(name, log) end

local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end

local Surface  = tryRequire("camera.surface")
local Engine   = tryRequire("core.engine_camera")
local Settings = tryRequire("core.settings")
if not (Surface and Engine) then
    log("FATAL: a core module failed to load; CameraSettings disabled")
    return
end

-- ----------------------------------------------------------------- state --
local SavedPath   = ModDir and (ModDir .. "/saved_settings.lua") or nil
local VanillaPath = ModDir and (ModDir .. "/vanilla_snapshot.lua") or nil

-- every tunable key (master flag + every control), for the merge and the save
local SAVED_KEYS = { "overridesEnabled" }
local controlByKey = {}
for _, sec in ipairs(Surface.sections) do
    for _, c in ipairs(sec.controls) do
        SAVED_KEYS[#SAVED_KEYS + 1] = c.key
        controlByKey[c.key] = c
    end
end

-- saved_settings.lua overrides config defaults
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

-- vanilla snapshot: load it, else capture from the live config the FIRST time the config is
-- reachable (always before our first write, so it is the true game default), and persist.
local Vanilla = (Settings and VanillaPath) and Settings.load(VanillaPath) or {}
local function ensureVanilla()
    if Vanilla.__captured then return true end
    if not Engine.available() then return false end
    local snap = { __captured = true }
    for _, sec in ipairs(Surface.sections) do
        for _, c in ipairs(sec.controls) do
            local v = Engine.readControl(c)
            if type(v) ~= "number" then return false end -- partial read; try again later
            snap[c.key] = v
        end
    end
    Vanilla = snap
    if Settings and VanillaPath then Settings.save(VanillaPath, Vanilla) end
    log("captured vanilla camera defaults")
    return true
end

local function clamp(c, v)
    v = tonumber(v); if not v then return nil end
    if v < c.min then v = c.min elseif v > c.max then v = c.max end
    return v
end

-- write either the saved values (overrides ON) or the vanilla values (OFF) to the config.
-- ensureVanilla first so the very first thing we do with the config is read the true default.
local function applyAll()
    if not ensureVanilla() then return false end
    local useVanilla = Config.overridesEnabled ~= true
    local n = 0
    for _, sec in ipairs(Surface.sections) do
        for _, c in ipairs(sec.controls) do
            local v = useVanilla and Vanilla[c.key] or Config[c.key]
            if type(v) == "number" and Engine.applyControl(c, v) then n = n + 1 end
        end
    end
    return n > 0
end

-- ------------------------------------------------------------ apply hooks --
-- Apply on load (no-op if the AS config is not reachable yet) and whenever a world loads,
-- with a couple of delayed retries to cover the config appearing shortly after startup.
pcall(applyAll)
pcall(RegisterInitGameStatePostHook, function() pcall(applyAll) end)
do
    local delay = rawget(_G, "ExecuteWithDelay")
    if delay then
        delay(3000, function() pcall(applyAll) end)
        delay(8000, function() pcall(applyAll) end)
    end
end

-- ------------------------------------------------- shared mod menu (optional) --
if kit.menu and kit.menu.register then
    local sections = {}

    sections[#sections + 1] = { title = "Camera", items = {
        { name = "Camera Overrides", kind = "bool",
          get = function() return Config.overridesEnabled == true end,
          set = function(v)
              Config.overridesEnabled = v and true or false
              log("Camera overrides " .. (Config.overridesEnabled and "ON" or "OFF"))
              pcall(applyAll)
              saveSettings()
          end },
    } }

    for _, sec in ipairs(Surface.sections) do
        local items = {}
        for _, control in ipairs(sec.controls) do
            items[#items + 1] = {
                name = control.name, kind = "num",
                min = control.min, max = control.max, step = control.step,
                get = function() return Config[control.key] end,
                set = function(v)
                    v = clamp(control, v); if not v then return end
                    Config[control.key] = v
                    if Config.overridesEnabled == true then
                        ensureVanilla()
                        pcall(function() Engine.applyControl(control, v) end)
                    end
                    saveSettings()
                end,
            }
        end
        items[#items + 1] = {
            name = "Reset " .. sec.title, kind = "action",
            set = function()
                if not ensureVanilla() then
                    log("reset: vanilla not captured yet (be in-game first)")
                    return
                end
                for _, control in ipairs(sec.controls) do
                    local vv = Vanilla[control.key]
                    if type(vv) == "number" then
                        Config[control.key] = vv
                        if Config.overridesEnabled == true then
                            pcall(function() Engine.applyControl(control, vv) end)
                        end
                    end
                end
                log("reset " .. sec.title .. " to vanilla")
                saveSettings()
            end,
        }
        sections[#sections + 1] = { title = sec.title, items = items }
    end

    pcall(kit.menu.register, "CameraSettings", sections)
    log("SharedModMenu: registered " .. #sections .. " section(s) (a tab appears if "
        .. "the SharedModMenu mod is installed)")
end

-- ----------------------------------------------------------------- banner --
log("Loaded " .. ModVersion .. " (kit " .. tostring(kit.version) .. "): overrides "
    .. (Config.overridesEnabled == true and "on" or "off") .. ", config "
    .. (Engine.available() and "reachable" or "not reachable yet (applies on world load)"))
