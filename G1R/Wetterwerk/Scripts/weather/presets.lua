-- presets.lua  --  preset NAME parsing (pure module)
--
-- The current preset is a UDS_Weather_Settings asset on the weather actor
-- (weatherActor.Weather). Its GetFullName() looks like
--   "UDS_Weather_Settings_C /Game/.../Gothic_Pressets/.../Gothic_Forest_Sunny.Gothic_Forest_Sunny"
-- This turns that into a leaf asset name and a tidy display label.
--
-- PURE: names ZERO engine globals (only string ops), so it loads under bare LuaJIT
-- and is unit-tested. The engine read lives in core/engine_weather.lua; this only
-- shapes the resulting string.

local string = string

local presets = {}

-- The bare asset name, e.g. "Gothic_Forest_Sunny". Tolerates the several shapes a
-- full name can take (with or without the leading "Class " prefix, with or without
-- the "Outer.Name" duplication, with or without a trailing "_C"). Idempotent: a
-- value that is already a leaf passes through unchanged. Returns nil for nil/empty.
function presets.leaf(fullName)
    if type(fullName) ~= "string" or fullName == "" then return nil end
    local s = fullName
    -- drop a leading "ClassName " prefix (everything up to the first space)
    local afterSpace = s:match("%s(%S+)$")
    if afterSpace then s = afterSpace end
    -- take the path leaf (after the last slash), if any
    local afterSlash = s:match("([^/\\]+)$")
    if afterSlash then s = afterSlash end
    -- the "Outer.Name" form repeats the name after a dot: keep the first half
    local beforeDot = s:match("^([^%.]+)")
    if beforeDot then s = beforeDot end
    -- strip a trailing Blueprint "_C" suffix
    s = s:gsub("_C$", "")
    if s == "" then return nil end
    return s
end

-- A tidy display label from a full name (or a leaf): the leaf with a redundant
-- leading "Gothic_" dropped and underscores turned into spaces, e.g.
-- "Gothic_Forest_Sunny" -> "Forest Sunny". Returns nil when there is no leaf.
function presets.label(fullName)
    local leaf = presets.leaf(fullName)
    if not leaf then return nil end
    local s = leaf:gsub("^[Gg]othic_", "")
    s = s:gsub("_", " ")
    return s
end

return presets
