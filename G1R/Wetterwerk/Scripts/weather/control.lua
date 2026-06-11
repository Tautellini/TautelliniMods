-- control.lua  --  the live weather Control (stateful class)
--
-- One instance owns the weather control session: it caches the live actor handles,
-- the current preset index, a lazily-learned index->name map, the Hold state, and
-- the atmosphere overrides. It is the DURABLE control layer: the ImGui menu (v1)
-- and a future SharedModMenu page (v2) are interchangeable front-ends that only
-- read control.state and call control:request*.
--
-- Names ZERO UE4SS globals: the engine adapter, the logger, the game-thread
-- scheduler and num are INJECTED (CONTRIBUTING.md purity + composition rules). So
-- main.lua owns all registration and ExecuteInGameThread; this class is pure logic
-- over its injected collaborators and is reload-safe (main evicts and recreates it
-- on a world change).
--
-- THREADING: every apply* method touches the engine and MUST run on the game
-- thread; the request* methods are the thread-safe entry points (they marshal via
-- the injected schedule). tick() is the game-thread heartbeat that refreshes the
-- cached readout and runs the Hold watchdog. The menu renders only from the cache.

local setmetatable = setmetatable
local ipairs, pairs, next = ipairs, pairs, next
local type, tostring = type, tostring

local presets = require("weather.presets")

local Control = {}
Control.__index = Control

-- deps: engine (the weather adapter), log, schedule (fn -> runs fn on the game
-- thread, immediate), num (unused for now but injected for parity), atmoEntries
-- (selected catalog entries), and the resolved config knobs (presetCountFallback,
-- enableWrites, resumeCycleOnRelease, debug).
function Control.new(deps)
    local self = setmetatable({}, Control)
    self.engine = deps.engine
    self.log = deps.log
    self.schedule = deps.schedule
    self.num = deps.num
    self.atmoEntries = deps.atmoEntries or {}
    self.presetCountFallback = deps.presetCountFallback or 10
    self.enableWrites = deps.enableWrites == true
    self.resumeCycleOnRelease = deps.resumeCycleOnRelease ~= false
    self.debug = deps.debug == true

    -- live handles, refreshed by ensureHandles on the game thread
    self.controller = nil
    self.weatherActor = nil
    self.skyActor = nil

    -- the cached snapshot the menu renders from (never an engine object). FRESH
    -- per-instance tables (never a shared class default).
    self.state = {
        ready = false,        -- is the controller found and readable
        index = nil,          -- current weather index
        leaf = nil,           -- current preset leaf asset name
        count = nil,          -- number of presets, once read
        hold = false,         -- is Hold engaged
        lockedIndex = nil,    -- the index Hold pins to
        names = {},           -- index -> display label, learned as visited
        atmo = {},            -- key -> current live value (readout)
        renderedAt = 0,       -- os.clock of the last menu render (liveness ping)
    }
    -- atmosphere override targets, key -> value, re-asserted while Hold is on
    self.overrides = {}
    -- one-shot default application (presetOnLoad / holdOnLoad) per world
    self.appliedDefaults = false
    return self
end

local function dbg(self, msg)
    if self.debug then self.log(msg) end
end

-- ensure the cached handles point at live actors; re-find any that are missing or
-- stale. Returns true if at least the controller is available. Game thread.
function Control:ensureHandles()
    local e = self.engine
    if not e.isValid(self.controller) then self.controller = e.findController() end
    if not e.isValid(self.weatherActor) then self.weatherActor = e.findWeatherActor() end
    if not e.isValid(self.skyActor) then self.skyActor = e.findSkyActor() end
    return self.controller ~= nil
end

-- the actors that might carry the lock flags (the spec is unsure which does).
function Control:flagActors()
    local out = {}
    if self.controller then out[#out + 1] = self.controller end
    if self.weatherActor then out[#out + 1] = self.weatherActor end
    return out
end

-- the heartbeat: refresh the cached readout and run the Hold watchdog. Game
-- thread, called from main.lua's poll. Cheap: one cached controller handle and a
-- handful of reflected reads, FindAllOf only when a handle went stale.
function Control:tick()
    local e = self.engine
    local s = self.state
    if not self:ensureHandles() then
        if s.ready then dbg(self, "controller lost (left the world?), control idle") end
        s.ready = false
        self.appliedDefaults = false
        return
    end
    if not s.ready then dbg(self, "controller found, weather control ready") end
    s.ready = true

    if s.count == nil then s.count = e.presetCount(self.controller) end

    local idx = e.getCurrentWeather(self.controller)
    if idx ~= nil then
        s.index = idx
        local full = e.presetName(self.weatherActor)
        if full then
            s.leaf = presets.leaf(full)
            local label = presets.label(full)
            if label then s.names[idx] = label end
        end
    end

    -- atmosphere readout
    if self.weatherActor then
        for _, entry in ipairs(self.atmoEntries) do
            s.atmo[entry.key] = e.readNumber(self.weatherActor, entry.prop)
        end
    end

    -- Hold watchdog: re-assert the pinned preset whenever the game has drifted off
    -- it, then re-assert any atmosphere overrides so the lerp settles on our
    -- values. Re-asserting the preset ONLY on drift (not every tick) keeps the sky
    -- from restarting its transition needlessly.
    if s.hold and s.lockedIndex ~= nil then
        if s.index ~= nil and s.index ~= s.lockedIndex then
            if e.setWeather(self.controller, s.lockedIndex) then
                dbg(self, "Hold: game drifted to " .. tostring(s.index)
                    .. ", re-asserted preset " .. tostring(s.lockedIndex))
            end
        end
        self:reassertOverrides()
    end
end

-- write a single atmosphere override now (intended target first so the lerp aims
-- at our value, then the raw value for an immediate nudge). Game thread.
function Control:writeAtmo(entry, value)
    local w = self.weatherActor
    if not w then return end
    if entry.intended then self.engine.writeNumber(w, entry.intended, value) end
    self.engine.writeNumber(w, entry.prop, value)
end

function Control:reassertOverrides()
    if not next(self.overrides) then return end
    for _, entry in ipairs(self.atmoEntries) do
        local v = self.overrides[entry.key]
        if v ~= nil then self:writeAtmo(entry, v) end
    end
end

-- clamp/derive a valid preset count for cycling.
function Control:effectiveCount()
    local c = self.state.count
    if type(c) == "number" and c > 0 then return c end
    return self.presetCountFallback
end

-- ------------------------------------------------------- apply (game thread) --

function Control:applySetPreset(index)
    if not self:ensureHandles() then return end
    if self.engine.setWeather(self.controller, index) then
        self.state.index = index
        if self.state.hold then self.state.lockedIndex = index end
        dbg(self, "set preset " .. tostring(index)
            .. (self.state.hold and " (held)" or ""))
    else
        self.log("could not set preset " .. tostring(index) .. " (controller not ready?)")
    end
end

function Control:applyCycle(delta)
    if not self:ensureHandles() then return end
    local count = self:effectiveCount()
    local cur = self.state.index
    if type(cur) ~= "number" then cur = self.engine.getCurrentWeather(self.controller) or 0 end
    local target = (cur + delta) % count
    if target < 0 then target = target + count end
    self:applySetPreset(target)
end

function Control:applySetHold(on)
    if not self:ensureHandles() then return end
    local s = self.state
    s.hold = on == true
    if s.hold then
        -- pin to whatever is current right now
        local cur = self.engine.getCurrentWeather(self.controller)
        s.lockedIndex = (type(cur) == "number") and cur or s.index
        -- ask the game to stop its own cycle (best effort; the watchdog is the
        -- guarantee). Randomize off, logic off.
        self.engine.setRandomizeWeather(self:flagActors(), false)
        self.engine.setEnableLogic(self:flagActors(), false)
        self:reassertOverrides()
        self.log("Hold ON: weather pinned to " .. tostring(s.lockedIndex))
    else
        s.lockedIndex = nil
        if self.resumeCycleOnRelease then
            -- resume the game's own weather cycle
            self.engine.setRandomizeWeather(self:flagActors(), true)
            self.engine.setEnableLogic(self:flagActors(), true)
        end
        self.log("Hold OFF" .. (self.resumeCycleOnRelease and " (game cycle resumed)" or ""))
    end
end

-- set or clear an atmosphere override. value nil clears it. Only honored while
-- writes are enabled; a clear is always honored. Game thread.
function Control:applyAtmo(key, value)
    if value ~= nil and not self.enableWrites then return end
    self.overrides[key] = value
    if value == nil then return end
    local entry
    for _, e in ipairs(self.atmoEntries) do if e.key == key then entry = e end end
    if entry then
        self:ensureHandles()
        self:writeAtmo(entry, value)
        dbg(self, "atmosphere " .. key .. " -> " .. tostring(value))
    end
end

-- --------------------------------------------- request (any thread, marshaled) --

function Control:requestSetPreset(index)
    self.schedule(function() self:applySetPreset(index) end)
end

function Control:requestCycle(delta)
    self.schedule(function() self:applyCycle(delta) end)
end

function Control:requestSetHold(on)
    self.schedule(function() self:applySetHold(on) end)
end

function Control:requestToggleHold()
    self.schedule(function() self:applySetHold(not self.state.hold) end)
end

function Control:requestAtmo(key, value)
    self.schedule(function() self:applyAtmo(key, value) end)
end

-- apply the configured on-load defaults exactly once per world (called by the poll
-- once the controller is ready). Game thread.
function Control:applyDefaultsOnce(presetOnLoad, holdOnLoad)
    if self.appliedDefaults or not self.state.ready then return end
    self.appliedDefaults = true
    if type(presetOnLoad) == "number" then self:applySetPreset(presetOnLoad) end
    if holdOnLoad == true then self:applySetHold(true) end
end

-- world change backstop: drop the cached handles and mark not-ready WITHOUT
-- touching the (possibly dangling) object wrappers. main calls this from the
-- InitGameState hook.
function Control:onWorldChange()
    self.controller = nil
    self.weatherActor = nil
    self.skyActor = nil
    self.state.ready = false
    self.appliedDefaults = false
end

return Control
