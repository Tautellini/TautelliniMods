-- atmosphere.lua  --  the weather "atmosphere knob" CATALOG (pure data + helpers)
--
-- The Ultra Dynamic Weather actor exposes many reflected NUMBER properties whose
-- Blueprint names carry spaces, so they are read as actor["Cloud Coverage"]. This
-- module is the shipped catalog of the knobs Wetterwerk surfaces: each entry names
-- the knob, its live property, the matching "Intended ..." lerp-target property
-- where one is confirmed, a label and a display range.
--
-- PURE: it names ZERO engine globals and holds only plain data, so the identical
-- file loads under bare LuaJIT and is unit-tested. The engine reads/writes these
-- by name in core/engine_weather.lua; config.lua picks which keys to show.
--
-- THE LERP NOTE. The live actor interpolates the raw value toward the active
-- preset's intended value, so a one-shot raw write is pulled back. A durable
-- override therefore writes the INTENDED property (the lerp then settles on our
-- value) AND is re-asserted by the Control's Hold watchdog each poll. `intended`
-- is set ONLY where the property name is confirmed (Cloud Coverage, from the
-- WeatherProbe spec); the rest are raw-only until probed. A wrong/absent intended
-- write simply pcall-fails and is a no-op, so adding more later is safe: confirm
-- the exact BP name in-game, then set `intended` on that entry.

local ipairs = ipairs
local type = type

local atmosphere = {}

-- Ordered catalog. min/max are DISPLAY ranges for the slider; most UDS values are
-- normalized 0..1, wind direction is degrees. They are best-effort and clamp only
-- the slider, never a programmatic write. Add or retune entries here, in one place.
atmosphere.list = {
    { key = "cloud",   prop = "Cloud Coverage", intended = "Intended Cloud Coverage",
      label = "Cloud coverage", min = 0.0, max = 1.0 },
    { key = "fog",     prop = "Fog",            label = "Fog",            min = 0.0, max = 1.0 },
    { key = "fogbase", prop = "Base Fog Density", label = "Base fog density", min = 0.0, max = 1.0 },
    { key = "rain",    prop = "Rain",           label = "Rain",           min = 0.0, max = 1.0 },
    { key = "snow",    prop = "Snow",           label = "Snow",           min = 0.0, max = 1.0 },
    { key = "thunder", prop = "Thunder/Lightning", label = "Thunder / lightning", min = 0.0, max = 1.0 },
    { key = "dust",    prop = "Dust",           label = "Dust",           min = 0.0, max = 1.0 },
    { key = "wind",    prop = "Wind Intensity", label = "Wind intensity", min = 0.0, max = 1.0 },
    { key = "winddir", prop = "Wind Direction", label = "Wind direction", min = 0.0, max = 360.0 },
    { key = "wetness", prop = "Material Wetness", label = "Material wetness", min = 0.0, max = 1.0 },
}

-- key -> entry, built once at load.
atmosphere.byKey = {}
for _, e in ipairs(atmosphere.list) do atmosphere.byKey[e.key] = e end

-- Resolve a configured list of keys into catalog entries, IN CATALOG ORDER (so the
-- menu layout is stable regardless of how the user lists them), silently skipping
-- any unknown key. Returns a fresh array. `keys` nil means an empty selection.
function atmosphere.select(keys)
    local want = {}
    if type(keys) == "table" then
        for _, k in ipairs(keys) do want[k] = true end
    end
    local out = {}
    for _, e in ipairs(atmosphere.list) do
        if want[e.key] then out[#out + 1] = e end
    end
    return out
end

return atmosphere
