-- test_settings.lua  --  the SharedModMenu/hotkey persistence (core/settings.lua).
-- Round-trips the saved-settings table through a temp file and checks the serializer
-- handles bools, numbers, and the nested extraTries table, plus graceful no-file.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local Settings = require("core.settings")

local TMP = DIR .. "/_settings_tmp.lua"
local function cleanup() os.remove(TMP) end

T.add("missing file loads as empty table", function()
    cleanup()
    local t = Settings.load(TMP)
    T.eq(type(t), "table")
    T.eq(next(t), nil, "no keys")
end)

T.add("save then load round-trips all value kinds", function()
    cleanup()
    local original = {
        showNextMove = true,
        showConnections = false,
        autoSolveEvery = true,
        autoSolveAnimationSpeed = 250,
        autoSolveTickMs = 100,
        extraTries = { untrained = 5, trained = 10, master = 20 },
    }
    T.ok(Settings.save(TMP, original), "save succeeds")
    local back = Settings.load(TMP)
    T.eq(back.showNextMove, true)
    T.eq(back.showConnections, false)
    T.eq(back.autoSolveEvery, true)
    T.eq(back.autoSolveAnimationSpeed, 250)
    T.eq(back.autoSolveTickMs, 100)
    T.eq(back.extraTries.untrained, 5)
    T.eq(back.extraTries.trained, 10)
    T.eq(back.extraTries.master, 20)
    cleanup()
end)

T.add("a corrupt file loads as empty table (no crash)", function()
    local fh = assert(io.open(TMP, "w"))
    fh:write("this is not valid lua ===")
    fh:close()
    local t = Settings.load(TMP)
    T.eq(type(t), "table")
    T.eq(next(t), nil)
    cleanup()
end)

os.exit(T.run())
