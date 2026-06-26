-- Leak guard: the shared kit must hold NO mod-domain literal in CODE. This is
-- the control that keeps "generic" honest. Comments may mention the literals
-- (e.g. engine.lua's banned-ops note), so line comments are stripped first.
-- run from this dir (tests/run.ps1 sets the cwd); the kit files are one level up
package.path = "./?.lua;" .. package.path
local kitDir = ".."
local T = require("tinytest")

local BANNED = {
    "Lockpick", "Slot_", "HighlightColor", "GameplayAbility",
    "m_Lock", "MPC_", "PlayerState",
}
local FILES = { "kit", "version", "log", "num", "color", "engine", "boot", "async" }

T.add("shared kit holds no mod-domain literal in code", function()
    for _, f in ipairs(FILES) do
        local fh = io.open(kitDir .. "/" .. f .. ".lua", "r")
        T.ok(fh ~= nil, "cannot open " .. f .. ".lua")
        local text = fh:read("*a"); fh:close()
        local code = text:gsub("%-%-[^\n]*", "") -- strip line comments
        for _, lit in ipairs(BANNED) do
            T.ok(code:find(lit, 1, true) == nil,
                f .. ".lua leaks domain literal: " .. lit)
        end
    end
end)

os.exit(T.run())
