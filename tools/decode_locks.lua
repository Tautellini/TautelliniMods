-- decode_locks.lua  --  PROOF-OF-CONCEPT LuaJIT port of tools/extract_locks.py.
--
-- Purpose: prove TECH-DEBT Approach A. The lock connection graph can be decoded
-- from the game's own PrecompiledScript_Shipping.Cache entirely in LuaJIT (the
-- UE4SS runtime), so the shipping mod needs to ship NO lock data of its own. This
-- script is a dev oracle: run it under the repo luajit, diff its output against
-- G1R/reference/lock-graphs.lua. Byte-identical data lines == the port is exact.
--
-- It is a faithful transcription of extract_locks.py (same regions, same byte
-- patterns, same arg order), NOT new logic. Read-only on the .Cache.
--
-- Usage: tools\luajit\luajit.exe tools\decode_locks.lua > out.txt
--   then diff out.txt against the data lines of reference/lock-graphs.lua.

local string, table, io, math = string, table, io, math
local byte, sub, find = string.byte, string.sub, string.find

local CACHE = [[C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache]]

-- the two native asCScriptFunction* pointers for this build (see blob notes); a
-- shipping port would locate these per-build, the proof reuses the known values
local ADDPIECE_PTR = "\xc0\x2f\x2d\x6d\xe9\x01\x00\x00"  -- 0x1E96D2D2FC0
local ADDCONN_PTR  = "\x80\x31\x2d\x6d\xe9\x01\x00\x00"  -- 0x1E96D2D3180
local CALLSYS = "\x3d\x00\x00\x00"
local PSHC4   = "\x02\x00\x00\x00"
local PSHVPTR = "\x30\x00\x00\x00"
local INITDEF = "\x0e\x00\x00\x00__InitDefaults\x00"     -- len(14) prefix + name
local ULC     = "UGothicLockConfig\x00"
local REGION_A, REGION_B = 37700000, 42200000

local function u32(data, o) -- o is 1-based
    local a, b, c, d = byte(data, o, o + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function i32(data, o)
    local v = u32(data, o)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

-- walk backwards from a CALLSYS, collecting contiguous PshC4 consts in push order
local function collectConsts(data, callOff, lo)
    local p = callOff
    if p - 4 >= lo and sub(data, p - 4, p - 1) == PSHVPTR then p = p - 4 end
    local consts = {}
    while p - 8 >= lo and sub(data, p - 8, p - 5) == PSHC4 do
        table.insert(consts, 1, i32(data, p - 4))
        p = p - 8
    end
    return consts
end

local fh = assert(io.open(CACHE, "rb"))
local data = fh:read("*a")
fh:close()

-- 1. enumerate lock-config descriptors: an __InitDefaults marker preceded by a
--    length-prefixed class name, with UGothicLockConfig referenced within ~2.6KB
local markers = {}
local i = REGION_A
while true do
    local d = find(data, INITDEF, i, true)
    if not d or d > REGION_B then break end
    i = d + 1
    local a = math.max(REGION_A, d - 90)
    local seg = sub(data, a, d - 1)
    local best
    local pos = 1
    while true do
        local s2, e2, tok = find(seg, "([%a_][%w_]+)%z", pos)
        if not s2 then break end
        pos = e2 + 1
        local len = #tok
        if len >= 3 and len <= 71 then
            local abs = a + s2 - 1            -- absolute 1-based token start
            if abs >= 5 and u32(data, abs - 4) == len then
                best = { tok, abs }
            end
        end
    end
    if best then
        local u = find(data, ULC, d, true)
        if u and u < d + 2600 then
            local nm = best[1]
            if sub(nm, 1, 1) == "U"
                and (sub(nm, -5) == "_Lock" or find(nm, "_Lock_", 1, true)) then
                nm = sub(nm, 2)
            end
            markers[#markers + 1] = { nm = nm, d = d }
        end
    end
end

-- 2. per descriptor, window = this marker .. next marker (cap 4000B)
local offs = {}
local seen = {}
for _, m in ipairs(markers) do
    if not seen[m.d] then seen[m.d] = true; offs[#offs + 1] = m.d end
end
table.sort(offs)
local function windowEnd(d)
    for _, mo in ipairs(offs) do
        if mo > d then return math.min(mo, d + 4000) end
    end
    return d + 4000
end

local results, order = {}, {}
for _, m in ipairs(markers) do
    local nm, d = m.nm, m.d
    if not results[nm] then
        local lo, hi = d, windowEnd(d)
        local pieces, conns = {}, {}
        local o = find(data, CALLSYS, lo, true)
        while o and o < hi do
            local ptr = sub(data, o + 4, o + 11)
            if ptr == ADDPIECE_PTR then
                local c = collectConsts(data, o, lo)
                local n = #c
                if n >= 2 then pieces[#pieces + 1] = { c[n], c[n - 1] } end
            elseif ptr == ADDCONN_PTR then
                local c = collectConsts(data, o, lo)
                local n = #c
                if n >= 3 then conns[#conns + 1] = { c[n], c[n - 1], c[n - 2] } end
            end
            o = find(data, CALLSYS, o + 4, true)
        end
        results[nm] = { pieces = pieces, connections = conns }
        order[#order + 1] = nm
    end
end

-- 3. emit data lines in extract_locks.py's exact format, sorted by name
table.sort(order)
for _, nm in ipairs(order) do
    local r = results[nm]
    if #r.pieces > 0 or #r.connections > 0 then
        local ps = {}
        for _, p in ipairs(r.pieces) do
            ps[#ps + 1] = string.format("{id=%d, rot=%d}", p[1], p[2])
        end
        local cs = {}
        for _, c in ipairs(r.connections) do
            cs[#cs + 1] = string.format("{a=%d, b=%d, dir=%d}", c[1], c[2], c[3])
        end
        io.write(string.format('  ["%s"] = { pieces = { %s }, connections = { %s } },\n',
            nm, table.concat(ps, ", "), table.concat(cs, ", ")))
    end
end
