-- TautelliniDevProbe  --  one mod, all the dev probes, one enabled.txt, one deploy.
--
-- Replaces the per-probe mods (ArcheryProbe, ASReadProbe, CanvasProbe, ...). Each
-- probe is a module in probes/ that returns `function(ctx) ... return spec end`,
-- where spec = { name, keys = { {key, mod, desc, fn} }, hooks = { {path, tag, cb} },
-- events = { {name, cb} }, notifies = { {path, cb} }, inits = { fn, ... } }.
-- main.lua loads them and registers each key, hook, custom event, notify and a single
-- shared init-post hook ONCE (tracked in a persistent global so CTRL+R never
-- double-registers), dispatching through tables refreshed every load so edits hot-
-- reload. It also detects key conflicts and logs the full keymap. Adding a probe =
-- drop a file in probes/ and list it below.
--
-- HOT-RELOAD SAFE: no risky native op at load; all UObject derefs go through the
-- shared kit guard. Probes that can crash (asread) gate their danger behind explicit
-- keys and never auto-run.

local print, pcall, ipairs, pairs, tostring, type, string, debug =
      print, pcall, ipairs, pairs, tostring, type, string, debug
local rawget, rawset = rawget, rawset

-- the probe modules to load (order = key-assignment priority on conflict)
-- canvas (S2 HUD draw) + menucap (S0 ImGui) retired. 'menu' (the UMG menu skeleton)
-- GRADUATED into the standalone SharedModMenu mod, so it is no longer loaded here: it bound
-- F2 + numpad + LMB, which now clash with that shipped menu. probes/menu.lua stays as a
-- reference. New probes go HERE as a probes/*.lua module, never as a separate mod.
-- 'gamepad' is SHELVED (file kept): UE4SS on this build cannot marshal an FKey parameter into
-- IsInputKeyDown/GetInputAnalogKeyState (real OR constructed FKey -> "Array failed invariants"),
-- so polling controller input from Lua is a dead end. Re-add it only to resume that hunt.
-- Which probes load, and the hotkey for each of their actions, live in config.lua under `probes`
-- (an enabled flag + per-action key strings). A probe is armed only when its config entry has
-- enabled = true, and an action binds only if config gives it a non-empty key. This file no longer
-- hardcodes a probe list or any hotkey. Probe files in probes/ with no config entry (archery,
-- asread, cheats, lockbuild, sleep, tickfind, gamepad, menu) stay as references and do not load.

-- ---- bootstrap the vendored kit + hot-reload reset (the mod main.lua pattern) ----
local here   = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;" .. ModDir .. "/shared/?.lua;" .. package.path
end
do  -- nil the kit, config + every loaded probe module before re-requiring; full-sweep path cache
    package.loaded["kit"] = nil
    package.loaded["config"] = nil
    for name in pairs(package.loaded) do
        if type(name) == "string" and name:sub(1, 7) == "probes." then package.loaded[name] = nil end
    end
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then for k in pairs(reg) do reg[k] = nil end end
end

local function root(m) print("[DevProbe] " .. tostring(m) .. "\n") end

local guard, isValid, try
do
    local ok, kit = pcall(require, "kit")
    if ok and kit and kit.engine and kit.engine.guard then
        guard, isValid, try = kit.engine.guard, kit.engine.isValid, kit.engine.try
    else
        isValid = function(o) if o == nil then return false end local k, v = pcall(function() return o:IsValid() end) return (k and v) and true or false end
        guard   = function(o, fn) if not isValid(o) then return nil end local k, r = pcall(fn, o) if k then return r end return nil end
        try     = function(fn) local k, r = pcall(fn) if k then return r end return nil end
    end
end

-- ---- shared, non-logging primitives handed to every probe via ctx ----
local function fullName(o) return guard(o, function(x) return x:GetFullName() end) or "<?>" end
local function classPath(o) return guard(o, function(x) return x:GetClass():GetFullName() end) or "<?>" end
local function onGameThread(fn)
    local g = rawget(_G, "ExecuteInGameThread")
    if g then g(fn) else fn() end
end

local FindAllOf = rawget(_G, "FindAllOf")

local function firstLive(cls)
    local list = try(function() return FindAllOf(cls) end)
    if not list then return nil end
    for _, o in ipairs(list) do
        if isValid(o) and not string.find(fullName(o), "Default__", 1, true) then return o end
    end
    return nil
end

local function firstPlayer(cls)
    local list = try(function() return FindAllOf(cls) end)
    if not list then return nil end
    local fallback
    for _, o in ipairs(list) do
        if isValid(o) then
            local fn = fullName(o)
            if not string.find(fn, "Default__", 1, true) then
                if string.find(fn, "PlayerState", 1, true) or string.find(fn, "PlayerCharacter", 1, true) then
                    return o, fn, true
                end
                fallback = fallback or o
            end
        end
    end
    if fallback then return fallback, fullName(fallback), false end
    return nil
end

local function resolve(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "nil" then return "nil" end
    local cur = try(function() return v.CurrentValue end)
    if type(cur) == "number" then
        local base = try(function() return v.BaseValue end)
        return string.format("cur=%s base=%s", tostring(cur), tostring(base))
    end
    local n = try(function() return v:GetFullName() end)
    if n then return n end
    return "<" .. t .. ">"
end

local function pstr(a)
    local t = type(a)
    if t == "number" or t == "boolean" or t == "string" then return tostring(a) end
    if t == "nil" then return "nil" end
    local g = try(function() return a:get() end)
    if g ~= nil then
        local tg = type(g)
        if tg == "number" or tg == "boolean" or tg == "string" then return tostring(g) end
        if tg == "userdata" then return try(function() return g:GetFullName() end) or "<obj>" end
        return "<" .. tg .. ">"
    end
    local n = try(function() return a:GetFullName() end)
    if n then return n end
    return "<" .. t .. ">"
end

local ctx = {
    makeLog   = function(sub) return function(m) print("[DevProbe:" .. sub .. "] " .. tostring(m) .. "\n") end end,
    guard     = guard, isValid = isValid, try = try,
    fullName  = fullName, classPath = classPath, firstLive = firstLive,
    firstPlayer = firstPlayer, resolve = resolve, pstr = pstr, onGameThread = onGameThread,
    FindAllOf = FindAllOf,
    StaticFindObject     = rawget(_G, "StaticFindObject"),
    StaticConstructObject = rawget(_G, "StaticConstructObject"),
    RegisterHook         = rawget(_G, "RegisterHook"),
    ExecuteWithDelay     = rawget(_G, "ExecuteWithDelay"),
    LoopAsync            = rawget(_G, "LoopAsync"),
}

-- ---- persistent registration state (survives CTRL+R) ----
local Key             = rawget(_G, "Key")
local ModifierKey     = rawget(_G, "ModifierKey")
local RegisterKeyBind = rawget(_G, "RegisterKeyBind")
local RegisterHook    = rawget(_G, "RegisterHook")
local RegisterCustomEvent          = rawget(_G, "RegisterCustomEvent")
local NotifyOnNewObject            = rawget(_G, "NotifyOnNewObject")
local RegisterInitGameStatePostHook = rawget(_G, "RegisterInitGameStatePostHook")

local P = rawget(_G, "__devprobe")
if not P then P = {}; rawset(_G, "__devprobe", P) end
P.keys     = P.keys     or {}   -- label -> true (keybind already registered)
P.hooks    = P.hooks    or {}   -- path  -> true (hook already armed)
P.events   = P.events   or {}   -- name  -> true (custom event already armed)
P.notifies = P.notifies or {}   -- path  -> true (notify already armed)
P.fn       = {}                 -- LABEL -> current key handler (refreshed each load). Keyed by
                                -- label (not module:key) so a key changing owner across a hot
                                -- reload still dispatches the new handler instead of going dead.
P.hookcb   = {}                 -- path -> current hook callback (refreshed each load)
P.evtcb    = {}                 -- name -> current custom-event callback (refreshed each load)
P.notifycb = {}                 -- path -> current notify callback (refreshed each load)
P.initcb   = {}                 -- list of current init callbacks (refreshed each load)

local function bindKey(keyName, mod, label)
    if P.keys[label] then return true end
    if not (Key and Key[keyName] and RegisterKeyBind) then return false end
    local fire = function() onGameThread(function() local f = P.fn[label]; if f then f() end end) end
    local ok
    if mod then
        if not (ModifierKey and ModifierKey[mod]) then return false end
        ok = pcall(RegisterKeyBind, Key[keyName], { ModifierKey[mod] }, fire)
    else
        ok = pcall(RegisterKeyBind, Key[keyName], fire)
    end
    if ok then P.keys[label] = true end
    return ok
end

local function armHook(path, tag)
    if P.hooks[path] then return end
    if type(RegisterHook) ~= "function" then return end
    local ok, err = pcall(RegisterHook, path, function(self, ...)
        local cb = P.hookcb[path]; if cb then pcall(cb, self, ...) end
    end)
    if ok then P.hooks[path] = true; root("hook armed: " .. tag)
    else root("hook NOT armed: " .. tag .. "  (" .. tostring(err) .. ")") end
end

local function armEvent(name)
    if P.events[name] then return end
    if type(RegisterCustomEvent) ~= "function" then return end
    local ok, err = pcall(RegisterCustomEvent, name, function(self, ...)
        local cb = P.evtcb[name]; if cb then pcall(cb, self, ...) end
    end)
    if ok then P.events[name] = true; root("event armed: " .. name)
    else root("event NOT armed: " .. name .. "  (" .. tostring(err) .. ")") end
end

local function armNotify(path)
    if P.notifies[path] then return end
    if type(NotifyOnNewObject) ~= "function" then return end
    local ok, err = pcall(NotifyOnNewObject, path, function(obj, ...)
        local cb = P.notifycb[path]; if cb then pcall(cb, obj, ...) end
    end)
    if ok then P.notifies[path] = true; root("notify armed: " .. path)
    else root("notify NOT armed: " .. path .. "  (" .. tostring(err) .. ")") end
end

-- one central init-post hook; its dispatcher iterates the per-load init list
local function armInit()
    if P.initArmed then return end
    if type(RegisterInitGameStatePostHook) ~= "function" then return end
    local ok, err = pcall(RegisterInitGameStatePostHook, function(...)
        for _, fn in ipairs(P.initcb) do pcall(fn, ...) end
    end)
    if ok then P.initArmed = true; root("init-post hook armed")
    else root("init-post hook NOT armed  (" .. tostring(err) .. ")") end
end

-- ---- opt-in gate: DevProbe is inert unless config.active is true ----
-- P.fn was reset to {} above, so when inactive any keys bound in a PRIOR active session fire into
-- nothing (CTRL+R makes them no-ops; a full restart drops the bindings entirely).
local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then Config = {} end
if not Config.active then
    root("INACTIVE (config.active = false): no hotkeys bound, no probes armed. "
        .. "Set active = true in Scripts/config.lua and reload (CTRL+R) for a probe session.")
    return
end

-- ---- load every ENABLED probe and register centrally ----
-- A probe declares actions = {{ id, desc, fn }}; the hotkey for each action comes from
-- config.probes[name].keys[id] ("" = unbound). Key format: "F3", "HOME", or "MOD+KEY"
-- (e.g. "SHIFT+F10"). Key assignment lives in config, never hardcoded in a probe file.
local function parseKey(s)
    local mod, key = s:match("^(%w+)%s*%+%s*(.+)$") -- "SHIFT+F10" -> "SHIFT","F10"
    if key then return mod, key end
    return nil, s
end

local keymap = {}   -- "MOD+KEY" combo -> owner string, for conflict detection + the keymap log
for probeName, pcfg in pairs(Config.probes or {}) do
    if type(pcfg) == "table" and pcfg.enabled then
        local okReq, modFn = pcall(require, "probes." .. probeName)
        if not okReq or type(modFn) ~= "function" then
            root("probe '" .. probeName .. "' failed to load: " .. tostring(modFn))
        else
            local okSetup, spec = pcall(modFn, ctx)
            if not okSetup or type(spec) ~= "table" then
                root("probe '" .. probeName .. "' setup error: " .. tostring(spec))
            else
                local keys = (type(pcfg.keys) == "table") and pcfg.keys or {}
                if spec.keys and not spec.actions then
                    root("probe '" .. probeName .. "' uses legacy keys=; convert it to "
                        .. "actions = {{ id, desc, fn }} and bind via config (nothing bound)")
                end
                for _, a in ipairs(spec.actions or {}) do
                    local keyStr = keys[a.id]
                    if type(keyStr) ~= "string" or keyStr == "" then
                        root("  " .. probeName .. "/" .. tostring(a.id) .. " UNBOUND (set config.probes."
                            .. probeName .. ".keys." .. tostring(a.id) .. ")")
                    else
                        local mod, key = parseKey(keyStr)
                        local combo = (mod and (mod .. "+") or "") .. key
                        if keymap[combo] then
                            root("KEY CONFLICT " .. combo .. ": " .. keymap[combo] .. " vs "
                                .. probeName .. "/" .. a.id .. " (skipped)")
                        else
                            local label = probeName .. ":" .. a.id
                            P.fn[label] = a.fn
                            if bindKey(key, mod, label) then
                                keymap[combo] = probeName .. "/" .. a.id .. " (" .. tostring(a.desc) .. ")"
                            else
                                root("  " .. probeName .. "/" .. a.id .. ": could not bind '"
                                    .. keyStr .. "' (unknown key or modifier)")
                            end
                        end
                    end
                end
                for _, h in ipairs(spec.hooks or {}) do P.hookcb[h.path] = h.cb; armHook(h.path, h.tag) end
                for _, e in ipairs(spec.events or {}) do P.evtcb[e.name] = e.cb; armEvent(e.name) end
                for _, n in ipairs(spec.notifies or {}) do P.notifycb[n.path] = n.cb; armNotify(n.path) end
                for _, fn in ipairs(spec.inits or {}) do P.initcb[#P.initcb + 1] = fn end
                if #(spec.inits or {}) > 0 then armInit() end
                if type(spec.autorun) == "function" then pcall(spec.autorun) end
            end
        end
    end
end

root("loaded. keymap:")
do
    -- stable-ish ordering by label for readability
    local labels = {}
    for label in pairs(keymap) do labels[#labels + 1] = label end
    table.sort(labels)
    for _, label in ipairs(labels) do root("  " .. label .. " = " .. keymap[label]) end
end
root("DEV-ONLY. Some probe actions mutate live gameplay (e.g. lockopen call tests); use a throwaway save.")
