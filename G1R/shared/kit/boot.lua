-- require-and-degrade: require a module, returning it (a table) or nil plus one
-- log line, so a broken module never takes the whole mod down. Used by a mod's
-- main.lua to load its own modules after the hot-reload reset.
local pcall = pcall
local require = require
local type = type
local tostring = tostring

local boot = {}

function boot.tryRequire(name, log)
    local ok, mod = pcall(require, name)
    if not ok or type(mod) ~= "table" then
        if log then log("ERROR in " .. name .. " (" .. tostring(mod) .. ")") end
        return nil
    end
    return mod
end

return boot
