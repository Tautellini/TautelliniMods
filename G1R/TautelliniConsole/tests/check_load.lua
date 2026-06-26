-- check_load.lua  --  smoke check: the shared kit and every shipped mod module
-- loads under bare LuaJIT (dotted names) and returns a table. Catches syntax
-- errors, missing trailing returns, dotted-require breakage, and engine globals
-- referenced (and CALLED) at LOAD time. main.lua is excluded: it self-injects
-- paths and registers handlers, it only runs inside UE4SS.
--
-- Run from this directory:  ..\..\..\tools\luajit\luajit.exe check_load.lua

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
-- mod modules resolve dotted under ../Scripts; the kit resolves folder-named
-- under ../../shared (the single repo source, the same shape deploy vendors).
package.path = DIR .. "/../Scripts/?.lua;"
    .. DIR .. "/../../shared/?/?.lua;" .. package.path

local MODULES = {
    "kit", "config",
    "core.engine", "core.registry", "core.output", "core.menu", "util.args",
    "cheats.resources", "cheats.stats", "cheats.items", "cheats.skills",
    "cheats.lockpicking", "cheats.movement", "cheats.time", "cheats.world",
    "cheats.generic",
}

local fail, absent = 0, 0
for _, m in ipairs(MODULES) do
    local ok, v = pcall(require, m)
    if ok then
        if type(v) == "table" then
            print("  ok      " .. m .. " -> table")
        else
            print("  BAD     " .. m .. " returned " .. type(v) .. " (missing trailing return?)")
            fail = fail + 1
        end
    elseif tostring(v):find("not found", 1, true) then
        print("  absent  " .. m .. " (not created yet)")
        absent = absent + 1
    else
        print("  FAIL    " .. m .. ": " .. tostring(v))
        fail = fail + 1
    end
end
print(string.format("%d load failures, %d absent", fail, absent))
os.exit(fail)
