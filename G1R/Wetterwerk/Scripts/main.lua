-- Wetterwerk for Gothic 1 Remake  --  thin orchestrator
--
-- Carries NO control logic: it self-adds the vendored shared kit, requires the mod
-- modules, builds the Control, and owns ALL registration (hotkeys, the ImGui tab,
-- the world-change backstop, the heartbeat poll). The work lives in the shared kit
-- and the mod's modules: core/engine_weather (the domain adapter), weather/
-- (presets parsing, the Control), ui/menu (the ImGui front-end), data/atmosphere
-- (the knob catalog). Same rules as LockpickSettings, see CONTRIBUTING.md.
--
-- WHAT IT DOES. Take command of the Ultra Dynamic Sky: cycle/set weather presets,
-- HOLD the weather (a watchdog re-asserts the chosen preset whenever the game
-- drifts off it), and optionally nudge atmosphere values. Pure UE4SS Lua, no pak.
-- The hotkeys work with the GUI off; the ImGui tab needs the UE4SS GUI console
-- (GuiConsoleEnabled = 1), which on this game can interact badly with Frame
-- Generation, so the menu is optional and the hotkeys are the floor.

-- UE4SS mods share one Lua state: another mod overwriting a standard global (seen:
-- ipairs replaced by a table) must not break us. Capture as locals.
local ipairs, pairs, tostring, tonumber = ipairs, pairs, tostring, tonumber
local type, pcall, print, require, next = type, pcall, print, require, next
local rawget, rawset, debug = rawget, rawset, debug
local math, table, string, os = math, table, string, os

local ModVersion = "0.1.0-alpha"

-- ---------------------------------------------------- vendored shared kit --
-- This mod ships its OWN copy of the kit under <Mod>/shared/kit/ (deploy.ps1
-- vendors it from the one repo source), so each build is self-contained. That
-- folder is not on UE4SS's default search path, so add it from this file's own
-- location (the BPModLoaderMod pattern).
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;"
        .. ModDir .. "/shared/?.lua;" .. package.path
end

-- --------------------------------------------------------- hot reload reset --
-- CTRL+R re-runs this chunk. nil EVERY module (the kit AND the mod's, by their
-- exact require names) in package.loaded, and FULL-SWEEP ue4ss_loaded_modules (it
-- is keyed by absolute path, so a bare-name nil there is a silent no-op). Do it
-- BEFORE the first require so edits to any file take effect.
local MODULES = {
    "kit", "config", "core.engine_weather", "weather.presets",
    "weather.control", "ui.menu", "data.atmosphere",
}
for _, m in ipairs(MODULES) do package.loaded[m] = nil end
do
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then
        for k in pairs(reg) do reg[k] = nil end
    end
end

-- Reload generation token. A permanent heartbeat LoopAsync and the ImGui tab
-- callback both ACCUMULATE across CTRL+R reloads (UE4SS does not tear down the old
-- ones). Each run bumps this token; the old closures see a newer token and
-- stop/skip, so only the latest reload's poll and render stay live. (Prefer a full
-- restart after deploy regardless; duplicate ImGui tabs still linger visually.)
local gen = (tonumber(rawget(_G, "__wetterwerk_gen")) or 0) + 1
rawset(_G, "__wetterwerk_gen", gen)

-- the shared kit is the foundation: without it the mod cannot run
local okKit, kit = pcall(require, "kit")
if not okKit or type(kit) ~= "table" then
    print("[Wetterwerk] FATAL: shared kit not found (" .. tostring(kit)
        .. "). Re-deploy; the kit vendors under <Mod>/shared/.\n")
    return
end
local log = kit.log.make("[Wetterwerk]")
local Num = kit.num

-- ----------------------------------------------------------------- modules --
local function tryRequire(name) return kit.boot.tryRequire(name, log) end

local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end

local Engine = tryRequire("core.engine_weather")
local Atmosphere = tryRequire("data.atmosphere")
local Control = tryRequire("weather.control")
local Menu = tryRequire("ui.menu")

if not (Engine and Control) then
    log("FATAL: the control layer failed to load (core.engine_weather / "
        .. "weather.control). Nothing to run. Re-deploy.")
    return
end

-- ----------------------------------------------------------------- config --
local WeatherNextHotkey = Config.weatherNextHotkey
local WeatherPrevHotkey = Config.weatherPrevHotkey
local HoldHotkey        = Config.holdHotkey
local PresetOnLoad      = Config.presetOnLoad
local HoldOnLoad        = Config.holdOnLoad == true
local PollMs            = tonumber(Config.pollMs) or 400
local EnableWrites      = Config.enableAtmosphereWrites == true
local Debug             = Config.debug == true

local atmoEntries = Atmosphere and Atmosphere.select(Config.atmosphereSliders) or {}

-- ----------------------------------------------- UE4SS registration globals --
-- captured defensively (shared-state safety). Registration lives ONLY here in the
-- tail, never in a required module.
local ExecuteInGameThread = rawget(_G, "ExecuteInGameThread")
local LoopAsync = rawget(_G, "LoopAsync")
local RegisterKeyBind = rawget(_G, "RegisterKeyBind")
local RegisterImGuiTab = rawget(_G, "RegisterImGuiTab")
local RegisterInitGameStatePostHook = rawget(_G, "RegisterInitGameStatePostHook")
local Key = rawget(_G, "Key")

-- run fn on the game thread (immediate). The Control's request* methods marshal
-- through this, so they are safe to call from a hotkey or the ImGui render thread.
local function schedule(fn)
    if ExecuteInGameThread then ExecuteInGameThread(fn) else fn() end
end

-- ------------------------------------------------------------- the control --
local control = Control.new({
    engine = Engine,
    log = log,
    schedule = schedule,
    num = Num,
    atmoEntries = atmoEntries,
    presetCountFallback = tonumber(Config.presetCountFallback) or 10,
    enableWrites = EnableWrites,
    resumeCycleOnRelease = Config.resumeCycleOnRelease ~= false,
    debug = Debug,
})

-- ----------------------------------------------------------------- hotkeys --
-- debounced binder: rapid repeats and duplicate registrations after a hot reload
-- once piled up tasks until UE4SS aborted, so collapse them. The action only
-- enqueues a request (which marshals to the game thread); no engine work here.
local function bindKey(name, label, fn)
    if type(name) ~= "string" or name == "" then return nil end
    if not (Key and Key[name]) then
        log("ERROR: unknown hotkey '" .. tostring(name) .. "' for " .. label
            .. ", disabled")
        return nil
    end
    if type(RegisterKeyBind) ~= "function" then return nil end
    local last = 0
    local ok = pcall(RegisterKeyBind, Key[name], function()
        local now = os.clock()
        if now - last < 0.3 then return end
        last = now
        pcall(fn)
    end)
    if not ok then
        log("ERROR: could not register the " .. label .. " hotkey")
        return nil
    end
    return name
end

local nextBound = bindKey(WeatherNextHotkey, "cycle-next",
    function() control:requestCycle(1) end)
local prevBound = bindKey(WeatherPrevHotkey, "cycle-previous",
    function() control:requestCycle(-1) end)
local holdBound = bindKey(HoldHotkey, "hold-toggle",
    function() control:requestToggleHold() end)

-- ----------------------------------------------------------- the ImGui tab --
-- Only the latest reload's closure renders (the generation gate), so stale tabs
-- after a CTRL+R go inert instead of double-driving the control.
local guiTab = false
if Menu and Menu.available() and type(RegisterImGuiTab) == "function" then
    guiTab = pcall(RegisterImGuiTab, "Wetterwerk", function()
        if rawget(_G, "__wetterwerk_gen") ~= gen then return end
        pcall(Menu.render, control, Config)
    end)
    if not guiTab then
        log("ImGui tab registration failed; the hotkeys still work")
    end
elseif Menu and not Menu.available() then
    log("ImGui not exposed by this UE4SS build; menu off, hotkeys still work")
elseif type(RegisterImGuiTab) ~= "function" then
    log("RegisterImGuiTab not available; menu off, hotkeys still work (enable the "
        .. "UE4SS GUI console to get the tab)")
end

-- --------------------------------------------------- world-change backstop --
-- on a save load, drop the cached actor handles WITHOUT touching them (they may
-- dangle after the GC purge); the next poll re-finds the new world's controller.
if type(RegisterInitGameStatePostHook) == "function" then
    pcall(RegisterInitGameStatePostHook, function()
        pcall(function() control:onWorldChange() end)
    end)
end

-- --------------------------------------------------------- the heartbeat poll --
-- Wakes every PollMs on an async worker; does the game-thread work (tick: refresh
-- the cached readout + run the Hold watchdog, then apply on-load defaults once)
-- via ExecuteInGameThread. A re-entrancy guard skips a wake if the previous tick
-- is still running, so ticks never backlog. The generation gate stops the old
-- loop after a reload.
if type(LoopAsync) == "function" then
    LoopAsync(PollMs, function()
        if rawget(_G, "__wetterwerk_gen") ~= gen then return true end
        if control.ticking then return false end
        control.ticking = true
        local function work()
            local ok, err = pcall(function()
                control:tick()
                control:applyDefaultsOnce(PresetOnLoad, HoldOnLoad)
            end)
            control.ticking = false
            if not ok then log("poll tick error: " .. tostring(err)) end
        end
        if ExecuteInGameThread then ExecuteInGameThread(work) else work() end
        return false
    end)
else
    log("LoopAsync not available; the live readout and Hold watchdog are off "
        .. "(direct preset sets via the hotkeys still work)")
end

-- ------------------------------------------------------------------- banner --
local keyParts = {}
if nextBound then keyParts[#keyParts + 1] = nextBound .. " next" end
if prevBound then keyParts[#keyParts + 1] = prevBound .. " prev" end
if holdBound then keyParts[#keyParts + 1] = holdBound .. " hold" end
local keyInfo = (#keyParts > 0) and table.concat(keyParts, ", ") or "none configured"

local atmoInfo
if #atmoEntries == 0 then
    atmoInfo = "no atmosphere knobs shown"
else
    atmoInfo = #atmoEntries .. " atmosphere knob(s) "
        .. (EnableWrites and "(live sliders, while Hold is on)" or "(read-only)")
end

log("Loaded " .. ModVersion .. " (kit " .. tostring(kit.version) .. "): hotkeys "
    .. keyInfo .. ", menu " .. (guiTab and "on (UE4SS GUI tab \"Wetterwerk\")" or "off")
    .. ", " .. atmoInfo .. ". Be in-game; the controller is found at the first poll.")
