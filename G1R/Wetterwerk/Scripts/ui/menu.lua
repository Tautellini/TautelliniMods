-- menu.lua  --  the UE4SS ImGui tab (v1 front-end)
--
-- Draws the Wetterwerk tab from control.state and calls control:request* on input.
-- This is the SWAPPABLE front-end: v2 replaces it with a SharedModMenu page that
-- renders with the game's own UMG (no GUI console, no Frame-Generation present-hook
-- caveat); the Control underneath is unchanged.
--
-- THE ONE GLOBAL EXCEPTION. ImGui is a UE4SS global, captured here defensively at
-- load. This is the single file allowed to name it (the engine adapter mediates
-- GAME access; ImGui is UE4SS's own overlay, not the game). Under bare LuaJIT
-- ImGui is nil, so the module still loads and returns a table; render() and
-- available() simply no-op. main.lua owns the RegisterImGuiTab registration.
--
-- ImGui drawing only: it reads the cached snapshot (never an engine object) and
-- marshals every action through the Control's request* methods (game thread). The
-- slider working-values live in `edit` below, because ImGui is immediate-mode and
-- the value must be fed back each frame for a smooth drag; this is throwaway UI
-- state, gone with the v2 swap.

local rawget = rawget
local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring
local string = string
local os = os
local math = math

local ImGui = rawget(_G, "ImGui")

local Menu = {}

-- per-key in-progress slider values (immediate-mode working state)
local edit = {}

function Menu.available()
    return ImGui ~= nil
end

-- a small guarded ImGui call: returns the call's results, or nothing if ImGui is
-- missing the function or it errors (some builds expose a subset). Keeps a missing
-- widget from taking the whole tab down.
local function call(fnName, ...)
    local fn = ImGui and ImGui[fnName]
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return a, b
end

local function text(s) call("Text", s) end
local function separator() call("Separator") end
local function sameLine() call("SameLine") end

-- a button that survives ImGui returning either a single bool or nothing.
local function button(label)
    local pressed = call("Button", label)
    return pressed == true
end

-- read a slider, tolerant of UE4SS returning (changed, value) OR (value, changed).
-- Returns the numeric value (or nil if unavailable). We pick whichever return is a
-- number as the value.
local function sliderFloat(label, value, lo, hi)
    local a, b = call("SliderFloat", label, value, lo, hi)
    if type(a) == "number" then return a end
    if type(b) == "number" then return b end
    return nil
end

local function presetName(s, i)
    return s.names[i] or ("Preset " .. i)
end

-- render the whole tab body. control is the live Control; config is the resolved
-- config table. Called every frame the tab is open.
function Menu.render(control, config)
    if not ImGui then return end
    local s = control.state
    s.renderedAt = os.clock() -- liveness ping the poll can read

    text("Wetterwerk  -  weather control")
    separator()

    if not s.ready then
        text("Waiting for the world. Be in-game; the weather controller is not")
        text("found yet (load a save or enter the world).")
        return
    end

    -- current weather
    local idx = s.index
    if idx ~= nil then
        text("Current: " .. presetName(s, idx) .. "   (#" .. tostring(idx) .. ")")
    else
        text("Current: unknown")
    end
    if s.leaf then text("Asset: " .. s.leaf) end
    separator()

    -- cycle + hold
    if button("< Previous") then control:requestCycle(-1) end
    sameLine()
    if button("Next >") then control:requestCycle(1) end
    sameLine()
    if button(s.hold and "Hold: ON  (release)" or "Hold: OFF  (engage)") then
        control:requestToggleHold()
    end
    if s.hold then
        local pinned = (s.lockedIndex ~= nil) and presetName(s, s.lockedIndex) or "current"
        text("Held at " .. pinned .. ". The game will not change the weather.")
    end
    separator()

    -- preset grid
    text("Presets:")
    local count = s.count or config.presetCountFallback or 10
    for i = 0, count - 1 do
        if button(presetName(s, i) .. "##wp" .. i) then control:requestSetPreset(i) end
        if ((i + 1) % 3) ~= 0 and i < count - 1 then sameLine() end
    end
    separator()

    -- atmosphere
    Menu.renderAtmosphere(control, config, s)
end

function Menu.renderAtmosphere(control, config, s)
    local entries = control.atmoEntries
    if not entries or #entries == 0 then return end
    text("Atmosphere:")
    local writable = control.enableWrites and s.hold
    if control.enableWrites and not s.hold then
        text("(engage Hold to set custom atmosphere; readout only while unheld)")
    elseif not control.enableWrites then
        text("(readout only; enable atmosphere writes in config.lua to adjust)")
    end
    for _, e in ipairs(entries) do
        local cur = s.atmo[e.key]
        if writable then
            -- seed the working value from the live readout once, then keep feeding
            -- the slider its own value so the drag is smooth
            if edit[e.key] == nil then edit[e.key] = cur or e.min end
            local v = sliderFloat(e.label .. "##wa" .. e.key, edit[e.key], e.min, e.max)
            if type(v) == "number" then
                edit[e.key] = v
                if math.abs(v - (cur or v)) > 0.0001 then
                    control:requestAtmo(e.key, v)
                end
            end
        else
            edit[e.key] = nil -- forget any stale working value when not editing
            local shown = (type(cur) == "number") and string.format("%.2f", cur) or "n/a"
            text(e.label .. ": " .. shown)
        end
    end
end

return Menu
