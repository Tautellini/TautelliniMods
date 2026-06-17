-- SharedModMenu/Scripts/main.lua  --  a standalone, OPTIONAL pure-Lua mod menu.
--
-- Any UE4SS Lua mod registers its settings into ONE shared in-game menu via
-- modmenu.register("ModName", spec). UE4SS runs every mod in an ISOLATED Lua state, so a
-- consumer's settings reach this mod only as DATA through UE4SS shared variables; the bridge
-- (Scripts/modmenu.lua) does the serialising. This mod is fully self-contained, and modmenu.lua
-- is the ONE file consumers vendor to integrate. main.lua boots
-- the renderer and binds the keys; without this mod installed a consumer's register() is a no-op.
--
-- The toggle hotkey is THIS mod's own setting (Scripts/config.lua). No shared config file.

local print, pcall, ipairs, pairs, tostring, type = print, pcall, ipairs, pairs, tostring, type
local rawget, rawset, os = rawget, rawset, os

local ModVersion = "1.2.2"
local function log(m) print("[SharedModMenu] " .. tostring(m) .. "\n") end

-- hot-reload reset: nil our modules before re-require, and full-sweep UE4SS's path cache. Every
-- module lives in Scripts/, which UE4SS already has on package.path, so no bootstrap is needed.
package.loaded["render"] = nil
package.loaded["viewmath"] = nil
package.loaded["config"] = nil
package.loaded["modmenu"] = nil
do local reg = rawget(_G, "ue4ss_loaded_modules"); if type(reg) == "table" then for k in pairs(reg) do reg[k] = nil end end end

local okR, menu = pcall(require, "render")
if not okR then log("FATAL: render module failed: " .. tostring(menu)); return end
-- the once-bound keybinds dispatch through this slot, refreshed each reload so a CTRL+R
-- always runs the newest handlers without re-binding.
rawset(_G, "__smmHandlers", menu)

-- the hotkeys are this mod's OWN config (no shared file)
local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then Config = {} end
local KEY = (type(Config.menuKey) == "string" and Config.menuKey ~= "") and Config.menuKey or "F2"
local Keys = type(Config.keys) == "table" and Config.keys or {}

-- ------------------------------------------------ registration (main.lua tail) --
local RegisterKeyBind     = rawget(_G, "RegisterKeyBind")
local Key                 = rawget(_G, "Key")
local ExecuteInGameThread = rawget(_G, "ExecuteInGameThread")
-- marshal handler work to the game thread; if the marshaller is absent we stay inert rather than
-- run UObject-touching render work on the event-loop thread (keys are gated on it below too).
local function onGameThread(fn) if ExecuteInGameThread then ExecuteInGameThread(fn) end end
local function dispatch(name, arg)
    local h = rawget(_G, "__smmHandlers"); local fn = h and h[name]
    if fn then pcall(fn, arg) end
end

if not rawget(_G, "__smmBound") and Key and type(RegisterKeyBind) == "function" and type(ExecuteInGameThread) == "function" then
    -- Serialize dispatches. Each keybind used to fire its own ExecuteInGameThread instantly, so a
    -- fast double-tap of F2 (or mashing keys) put two overlapping menu builds on UE4SS's deferred
    -- queue and hit the #1180 reentrancy (a UMG write-AV opening the menu). A per-key debounce
    -- (kills held-key repeat / double-tap) plus a short global cooldown keep at most one dispatch
    -- in flight. Time-based, so there is no flag that can get stuck.
    local lastFire, busyUntil = {}, 0
    local function bind(keyName, fn)
        if not Key[keyName] then return end
        pcall(RegisterKeyBind, Key[keyName], function()
            local now = os.clock()
            if now < busyUntil then return end
            if lastFire[keyName] and now - lastFire[keyName] < 0.15 then return end
            lastFire[keyName] = now
            busyUntil = now + 0.12
            onGameThread(fn)
        end)
    end
    -- the configured name for a nav action, or its default when unset / not a key this build knows
    local function navKey(field, default)
        local v = Keys[field]
        return (type(v) == "string" and v ~= "" and Key[v]) and v or default
    end
    bind(KEY,                            function() dispatch("toggle") end)
    bind("LEFT_MOUSE_BUTTON",            function() dispatch("onLMB") end)
    bind("LBUTTON",                      function() dispatch("onLMB") end)
    bind(navKey("itemPrev", "NUM_EIGHT"), function() dispatch("navItem", -1) end)
    bind(navKey("itemNext", "NUM_TWO"),   function() dispatch("navItem", 1) end)
    bind(navKey("valueDec", "NUM_FOUR"),  function() dispatch("adjust", -1) end)
    bind(navKey("valueInc", "NUM_SIX"),   function() dispatch("adjust", 1) end)
    bind(navKey("activate", "NUM_FIVE"),  function() dispatch("activate") end)
    bind(navKey("subPrev", "NUM_SEVEN"),  function() dispatch("navSub", -1) end)
    bind(navKey("subNext", "NUM_NINE"),   function() dispatch("navSub", 1) end)
    bind(navKey("tabPrev", "NUM_ONE"),    function() dispatch("navTab", -1) end)
    bind(navKey("tabNext", "NUM_THREE"),  function() dispatch("navTab", 1) end)
    rawset(_G, "__smmBound", true)
    log("keys bound: " .. KEY .. " = toggle; numpad 8/2 item, 4/6 value, 5 run, 7/9 sub-tab, 1/3 mod-tab, mouse.")
end

-- world-change backstop (bound once): on a save load the cached menu widget + PlayerController
-- may dangle, so drop them WITHOUT touching them; the next open rebuilds clean.
if not rawget(_G, "__smmWorldHook") then
    local RegisterInitGameStatePostHook = rawget(_G, "RegisterInitGameStatePostHook")
    if type(RegisterInitGameStatePostHook) == "function" then
        local ok = pcall(RegisterInitGameStatePostHook, function()
            local h = rawget(_G, "__smmHandlers")
            if h and h.resetState then pcall(h.resetState) end
        end)
        if ok then rawset(_G, "__smmWorldHook", true) end
    end
end

log("loaded v" .. ModVersion .. " (pure-Lua, cross-mod via UE4SS shared variables). "
    .. "Toggle = " .. KEY .. ". Open it in-game to see registered mods. "
    .. "Hotkey: this mod's Scripts/config.lua (menuKey).")
