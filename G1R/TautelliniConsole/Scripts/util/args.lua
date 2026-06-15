-- util/args.lua  --  argument parsing helpers. PURE: names zero UE4SS globals,
-- so it loads and unit-tests under bare LuaJIT.

local type, tostring, tonumber = type, tostring, tonumber

local args = {}

-- lower-case a token, passing nil through unchanged.
function args.lower(s)
    if type(s) ~= "string" then return s end
    return s:lower()
end

-- a toggle word: "on" / "off" / "toggle" (for a bare command), or nil if the
-- token is present but unrecognized.
function args.toggleVerb(token)
    if token == nil then return "toggle" end
    local t = tostring(token):lower()
    if t == "on" or t == "1" or t == "true" or t == "enable" then return "on" end
    if t == "off" or t == "0" or t == "false" or t == "disable" then return "off" end
    return nil
end

-- parse a clock token, "8:30" or "8", into integer hour, minute. Returns nil on
-- a bad shape or out-of-range value (hour 0..23, minute 0..59).
function args.parseClock(token)
    if type(token) ~= "string" then return nil end
    local h, m = token:match("^(%d+):(%d+)$")
    if not h then
        h = token:match("^(%d+)$")
        m = "0"
    end
    if not h then return nil end
    h, m = tonumber(h), tonumber(m)
    if not h or not m then return nil end
    if h < 0 or h > 23 or m < 0 or m > 59 then return nil end
    return h, m
end

return args
