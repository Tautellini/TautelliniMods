-- time_inflate.lua  --  measure per-lock policy inflate cost (the lock-open lag).
-- Run: tools/lua54/lua.exe tools/time_inflate.lua
package.path = "G1R/LockpickSettings/Scripts/?.lua;" .. package.path
local Inflate = require("util.inflate")
local Index = assert(loadfile(
    "G1R/LockpickSettings/Scripts/data/lockpolicies_index.lua"))()
local fh = assert(io.open("G1R/LockpickSettings/Scripts/data/lockpolicies.bin", "rb"))
local bin = fh:read("*a"); fh:close()
local function readBlob(off, len) return bin:sub(off + 1, off + len) end

-- one representative lock per piece count, plus the worst by raw size
local bySize = {}
local biggest = { name = nil, n = 0, comp = 0 }
for name, e in pairs(Index) do
    bySize[e.n] = bySize[e.n] or name
    local c = e.v[1][2] -- variant 0 compressed length
    if c > biggest.comp then biggest = { name = name, n = e.n, comp = c } end
end

local function timeOpen(name)
    local e = Index[name]
    local v = e.v[2] -- precision-1 variant (typical)
    local reps = e.n >= 7 and 5 or 20
    local t0 = os.clock()
    local out
    for _ = 1, reps do out = Inflate.inflate(readBlob(v[1], v[2])) end
    local ms = (os.clock() - t0) / reps * 1000
    print(string.format("n=%d  %-26s  blob=%6dB  raw=%7dB  inflate=%6.1f ms",
        e.n, name, v[2], #out, ms))
end

print("per-piece-count sample:")
local ns = {}
for n in pairs(bySize) do ns[#ns + 1] = n end
table.sort(ns)
for _, n in ipairs(ns) do timeOpen(bySize[n]) end
print("worst by blob size:")
timeOpen(biggest.name)
