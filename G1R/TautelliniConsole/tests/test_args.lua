-- test_args.lua  --  util/args is pure (no engine), so it tests directly under
-- bare LuaJIT: the toggle-word parse and the absolute clock parse + validation.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local args = require("util.args")

T.add("toggleVerb maps on/off words and a bare nil to toggle", function()
    T.eq(args.toggleVerb(nil), "toggle")
    T.eq(args.toggleVerb("on"), "on")
    T.eq(args.toggleVerb("ON"), "on")
    T.eq(args.toggleVerb("1"), "on")
    T.eq(args.toggleVerb("enable"), "on")
    T.eq(args.toggleVerb("off"), "off")
    T.eq(args.toggleVerb("0"), "off")
    T.eq(args.toggleVerb("disable"), "off")
end)

T.add("toggleVerb returns nil for an unrecognized word", function()
    T.eq(args.toggleVerb("banana"), nil)
end)

T.add("parseClock reads HH:MM", function()
    local h, m = args.parseClock("8:30")
    T.eq(h, 8); T.eq(m, 30)
    h, m = args.parseClock("23:59")
    T.eq(h, 23); T.eq(m, 59)
    h, m = args.parseClock("0:00")
    T.eq(h, 0); T.eq(m, 0)
end)

T.add("parseClock reads a bare hour as HH:00", function()
    local h, m = args.parseClock("8")
    T.eq(h, 8); T.eq(m, 0)
end)

T.add("parseClock rejects out-of-range and malformed tokens", function()
    T.eq(args.parseClock("24:00"), nil, "hour 24 is out of range")
    T.eq(args.parseClock("8:60"), nil, "minute 60 is out of range")
    T.eq(args.parseClock("-1:00"), nil, "negative is malformed")
    T.eq(args.parseClock("8:"), nil, "trailing colon is malformed")
    T.eq(args.parseClock("morning"), nil, "non-numeric is rejected")
    T.eq(args.parseClock(""), nil, "empty is rejected")
    T.eq(args.parseClock(nil), nil, "nil is rejected")
end)

os.exit(T.run())
