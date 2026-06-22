-- core/settings.lua -- tiny persistence: load/save a Lua table to a file so menu changes survive a
-- restart. stdlib only, no UE4SS globals; main supplies the absolute path.

local io, loadfile = io, loadfile
local pairs, type, tostring = pairs, type, tostring
local table, string = table, string

local M = {}

function M.load(path)
    local ok, t = pcall(function()
        local chunk = loadfile(path)
        return chunk and chunk()
    end)
    return (ok and type(t) == "table") and t or {}
end

local function ser(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            local key = type(k) == "string" and (k .. " = ") or ""
            parts[#parts + 1] = key .. ser(val)
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "nil"
end

function M.save(path, tbl)
    return (pcall(function()
        local fh = io.open(path, "w")
        if not fh then return end
        fh:write("-- Saved FastTravelAnywhere data. Overrides config.lua; delete to reset.\n")
        fh:write("return " .. ser(tbl) .. "\n")
        fh:close()
    end))
end

return M
