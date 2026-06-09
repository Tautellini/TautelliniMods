-- verify_livegraphs.lua  --  offline check that Scripts/data/livegraphs.lua,
-- WITH auto-calibrated pointers and the region fast-path, decodes the game's
-- .Cache into the same graphs the committed reference holds. Emits data lines in
-- extract_locks.py format for diffing against G1R/reference/lock-graphs.lua.
--
-- Usage (from repo root):
--   tools\luajit\luajit.exe tools\verify_livegraphs.lua > out.txt
--   then diff out.txt against the data lines of reference/lock-graphs.lua

package.path = "G1R/LockpickSettings/Scripts/?.lua;" .. package.path
local M = require("data.livegraphs")

local CACHE =
    [[C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache]]

local graphs, err = M.decode(CACHE)
if not graphs then
    io.stderr:write("decode failed: " .. tostring(err) .. "\n")
    os.exit(1)
end

local names = {}
for k in pairs(graphs) do names[#names + 1] = k end
table.sort(names)
for _, nm in ipairs(names) do
    local r = graphs[nm]
    if #r.pieces > 0 or #r.connections > 0 then
        local ps = {}
        for _, p in ipairs(r.pieces) do
            ps[#ps + 1] = string.format("{id=%d, rot=%d}", p.id, p.rot)
        end
        local cs = {}
        for _, c in ipairs(r.connections) do
            cs[#cs + 1] = string.format("{a=%d, b=%d, dir=%d}", c.a, c.b, c.dir)
        end
        io.write(string.format('  ["%s"] = { pieces = { %s }, connections = { %s } },\n',
            nm, table.concat(ps, ", "), table.concat(cs, ", ")))
    end
end
