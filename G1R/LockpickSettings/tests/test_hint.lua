-- test_hint.lua  --  Next-Move feature: the hint color mapping is pure.
local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local hint = require("nextmove.hint")

local palette = { hintLeft = "L", hintRight = "R", hintNeutral = "N" }

T.add("no next move yields the neutral color", function()
    T.eq(hint.color({ nextMove = nil }, palette), "N")
end)

T.add("a measured input-to-axis mapping decides left/right", function()
    -- axisDir = dir*sign; pressRight = axisDir*inputToAxis > 0
    T.eq(hint.color({ nextMove = { dir = 1 }, sign = 1, inputToAxis = 1 }, palette), "R")
    T.eq(hint.color({ nextMove = { dir = 1 }, sign = 1, inputToAxis = -1 }, palette), "L")
    T.eq(hint.color({ nextMove = { dir = -1 }, sign = 1, inputToAxis = 1 }, palette), "L")
end)

T.add("the stage screenRight decides when no input mapping is known", function()
    T.eq(hint.color({ nextMove = { dir = 1 }, sign = 1, screenRight = 1 }, palette), "R")
    T.eq(hint.color({ nextMove = { dir = 1 }, sign = 1, screenRight = -1 }, palette), "L")
end)

T.add("neutral when neither mapping is known (never gamble a direction)", function()
    T.eq(hint.color({ nextMove = { dir = 1 }, sign = 1 }, palette), "N")
end)

os.exit(T.run())
