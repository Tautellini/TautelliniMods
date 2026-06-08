-- check_load.lua  --  smoke check: every shipped module loads under bare
-- LuaJIT and returns a table. Catches syntax errors, missing trailing
-- returns, and engine globals referenced at LOAD time (which would crash
-- here). main.lua is excluded: it registers hooks/keybinds at load and only
-- runs inside UE4SS. Modules not yet created are reported as absent, so this
-- is usable mid-refactor.
--
-- Run from this directory:  ..\..\..\tools\luajit\luajit.exe check_load.lua

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. package.path

local MODULES = {
    "config", "lockgraphs", "num", "colors", "engine", "boost",
    "solver", "geometry", "tinter", "session",
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
