-- livegraphs.lua  --  decode the lock connection graph from the GAME'S OWN data
-- at runtime, so the mod ships no bundled lock dump (TECH-DEBT Approach A).
--
-- The graph is reflected nowhere and the build calls are not hookable (see
-- TECH-DEBT items 1 and 2); the only place it lives that Lua can reach is the
-- game's compiled AngelScript cache, PrecompiledScript_Shipping.Cache. Each
-- GothicLockConfig subclass has an __InitDefaults function whose loaded bytecode
-- contains AddPiece(id, rotation) / AddConnection(id, connectedId, direction)
-- calls. This is a faithful in-process LuaJIT port of tools/extract_locks.py
-- (proven to reproduce all 416 graphs byte-identically), with two additions for
-- shipping: the two native pointers are AUTO-CALIBRATED per build (no hardcoded
-- address, so a game patch cannot stale it), and the result is validated.
--
-- PURE file: stdlib only (io/string/table/math/loadfile), names no UE4SS global,
-- loads under bare LuaJIT. main.lua supplies the .Cache path (computed from its
-- own location) and a writable cache path; this file does the reading.
--
-- See blob-format-notes.md for the byte layout. Read-only on the .Cache.

local string, table, io, math = string, table, io, math
local byte, ssub, sfind = string.byte, string.sub, string.find
local pairs, ipairs, pcall, tostring, type = pairs, ipairs, pcall, tostring, type
local loadfile, next = loadfile, next

local M = {}

-- loaded-AngelScript opcodes (low byte of a 32-bit word); see blob notes
local CALLSYS = "\61\0\0\0"            -- 0x3d
local PSHC4   = "\2\0\0\0"             -- 0x02 + int32
local PSHVPTR = "\48\0\0\0"            -- 0x30 (push `this`)
local INITDEF = "\14\0\0\0__InitDefaults\0"  -- len(14) prefix + name + NUL
local ULC     = "UGothicLockConfig\0"
-- the lock-config descriptors live in this byte band (per the blob notes); the
-- shipping read takes only this ~4.5 MB slice, sub-second vs the 122 MB whole
local REGION_A, REGION_B = 37700000, 42200000
local MIN_LOCKS = 100  -- a region read finding fewer than this is suspect (patch
                       -- moved the script section): fall back to the whole file

local function u32(d, o)
    local a, b, c, e = byte(d, o, o + 3)
    return a + b * 256 + c * 65536 + e * 16777216
end
local function i32(d, o)
    local v = u32(d, o)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

-- count of contiguous PshC4 immediately before a PshVPtr+CALLSYS at callOff
-- (1-based). Returns the count and, when wanted, the consts in push order.
local function constsBefore(data, callOff)
    local p = callOff
    if p - 4 >= 1 and ssub(data, p - 4, p - 1) == PSHVPTR then p = p - 4 end
    local consts = {}
    while p - 8 >= 1 and ssub(data, p - 8, p - 5) == PSHC4 do
        table.insert(consts, 1, i32(data, p - 4))
        p = p - 8
    end
    return consts
end

-- Find the AddPiece and AddConnection native pointers without hardcoding them:
-- AddPiece is always called with 2 int args, AddConnection with 3, both as
-- PshC4*N + PshVPtr + CALLSYS. Histogram CALLSYS targets by their preceding
-- const count; the target dominating the 2-arg calls is AddPiece, the 3-arg
-- AddConnection. Returns the two 8-byte pointer strings, or nil if ambiguous.
local function calibrate(data)
    local c2, c3 = {}, {}
    local o = sfind(data, CALLSYS, 1, true)
    while o do
        if o - 4 >= 1 and ssub(data, o - 4, o - 1) == PSHVPTR then
            local p, n = o - 4, 0
            while p - 8 >= 1 and ssub(data, p - 8, p - 5) == PSHC4 do
                n = n + 1; p = p - 8
            end
            if n == 2 or n == 3 then
                local tgt = ssub(data, o + 4, o + 11)
                if #tgt == 8 then
                    local bucket = (n == 2) and c2 or c3
                    bucket[tgt] = (bucket[tgt] or 0) + 1
                end
            end
        end
        o = sfind(data, CALLSYS, o + 4, true)
    end
    local function argmax(t)
        local best, bestN = nil, 0
        for k, v in pairs(t) do if v > bestN then best, bestN = k, v end end
        return best, bestN
    end
    local ap, apn = argmax(c2)
    local ac, acn = argmax(c3)
    if not ap or not ac or ap == ac or apn < 50 or acn < 50 then return nil end
    return ap, ac
end

-- Enumerate lock-config descriptors and decode each one's piece/connection calls
-- in its __InitDefaults window. Returns { [name] = {pieces, connections} }, count.
local function scanGraphs(data, addPiecePtr, addConnPtr)
    local n = #data
    -- 1. markers: an __InitDefaults preceded by a length-prefixed class name,
    --    with UGothicLockConfig referenced within ~2.6 KB
    local markers, offsByD = {}, {}
    local i = 1
    while true do
        local d = sfind(data, INITDEF, i, true)
        if not d then break end
        i = d + 1
        local a = d - 90; if a < 1 then a = 1 end
        local seg = ssub(data, a, d - 1)
        local best, pos = nil, 1
        while true do
            local s2, e2, tok = sfind(seg, "([%a_][%w_]+)%z", pos)
            if not s2 then break end
            pos = e2 + 1
            local len = #tok
            if len >= 3 and len <= 71 then
                local abs = a + s2 - 1
                if abs >= 5 and u32(data, abs - 4) == len then best = { tok, abs } end
            end
        end
        if best then
            local u = sfind(data, ULC, d, true)
            if u and u < d + 2600 then
                local nm = best[1]
                if ssub(nm, 1, 1) == "U"
                    and (ssub(nm, -5) == "_Lock" or sfind(nm, "_Lock_", 1, true)) then
                    nm = ssub(nm, 2)
                end
                markers[#markers + 1] = { nm = nm, d = d }
                offsByD[#offsByD + 1] = d
            end
        end
    end
    table.sort(offsByD)
    local function windowEnd(d)
        for _, mo in ipairs(offsByD) do
            if mo > d then return (mo < d + 4000) and mo or (d + 4000) end
        end
        return d + 4000
    end
    -- 2. decode each window
    local results, count = {}, 0
    for _, m in ipairs(markers) do
        local nm, d = m.nm, m.d
        if not results[nm] then
            local lo, hi = d, windowEnd(d)
            if hi > n then hi = n end
            local pieces, conns = {}, {}
            local o = sfind(data, CALLSYS, lo, true)
            while o and o < hi do
                local ptr = ssub(data, o + 4, o + 11)
                if ptr == addPiecePtr then
                    local c = constsBefore(data, o)
                    local k = #c
                    if k >= 2 then pieces[#pieces + 1] = { id = c[k], rot = c[k - 1] } end
                elseif ptr == addConnPtr then
                    local c = constsBefore(data, o)
                    local k = #c
                    if k >= 3 then
                        conns[#conns + 1] = { a = c[k], b = c[k - 1], dir = c[k - 2] }
                    end
                end
                o = sfind(data, CALLSYS, o + 4, true)
            end
            results[nm] = { pieces = pieces, connections = conns }
            count = count + 1
        end
    end
    -- drop empty descriptors (the Test_Chest_* companions and any non-puzzle
    -- element carry no AddPiece/AddConnection) so the table matches the bundled
    -- dump exactly: write_lua omits them, and the mod only ever looks graphs up
    -- by an active lock's name, never these.
    for nm, r in pairs(results) do
        if #r.pieces == 0 and #r.connections == 0 then
            results[nm] = nil
            count = count - 1
        end
    end
    return results, count
end

-- A decoded set is trustworthy only if it matches the invariants the extractor
-- validated: per lock, piece ids are the contiguous set 0..N-1 and every
-- connection endpoint is an existing piece. Returns the number of NON-EMPTY,
-- VALID locks (used to pick the better of region vs whole-file).
local function validCount(results)
    local ok = 0
    for _, r in pairs(results) do
        local np = #r.pieces
        if np > 0 then
            local idset, good = {}, true
            for _, p in ipairs(r.pieces) do
                if idset[p.id] then good = false break end
                idset[p.id] = true
            end
            if good then
                for id = 0, np - 1 do if not idset[id] then good = false break end end
            end
            if good then
                for _, c in ipairs(r.connections) do
                    if not idset[c.a] or not idset[c.b] then good = false break end
                end
            end
            if good then ok = ok + 1 end
        end
    end
    return ok
end

local function readSlice(path, lo, hi)
    local fh, err = io.open(path, "rb")
    if not fh then return nil, "open failed: " .. tostring(err) end
    if lo and lo > 0 then fh:seek("set", lo) end
    local data = hi and fh:read(hi - (lo or 0)) or fh:read("*a")
    fh:close()
    if not data or #data == 0 then return nil, "empty read" end
    return data
end

-- Decode the graph from the game's .Cache at `path`. Region fast-path first; on a
-- thin or invalid result (a patch moved the section) fall back to the whole file.
-- Returns { [name] = {pieces, connections} } or nil, err.
function M.decode(path)
    local function attempt(data)
        if not data then return nil, 0 end
        local ap, ac = calibrate(data)
        if not ap then return nil, 0 end
        local g, _ = scanGraphs(data, ap, ac)
        return g, validCount(g)
    end
    local region = readSlice(path, REGION_A, REGION_B)
    local g, ok = attempt(region)
    if g and ok >= MIN_LOCKS then return g end
    local whole, werr = readSlice(path)
    if not whole then
        if g and ok > 0 then return g end
        return nil, werr or "cache unreadable"
    end
    local gw, okw = attempt(whole)
    if gw and okw >= ok and okw > 0 then return gw end
    if g and ok > 0 then return g end
    return nil, "no locks decoded"
end

-- serialize to a loadable Lua chunk in the same shape main consumes
local function serialize(graphs)
    local names = {}
    for k in pairs(graphs) do names[#names + 1] = k end
    table.sort(names)
    local L = { "return {" }
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
            L[#L + 1] = string.format('  ["%s"] = { pieces = { %s }, connections = { %s } },',
                nm, table.concat(ps, ", "), table.concat(cs, ", "))
        end
    end
    L[#L + 1] = "}"
    return table.concat(L, "\n") .. "\n"
end

-- Self-populating cache: decode live and refresh the cache on success; fall back
-- to the written cache only when the live read fails (file moved/unreadable).
-- Returns graphs, source where source is "live" | "cache" | "none".
function M.load(opts)
    opts = opts or {}
    -- forceFallback (debug, from config): skip the live decode + self-cache and load
    -- the bundled snapshot directly, to exercise the fallback path on a machine
    -- where the live decode works fine.
    local err = "forced fallback (debug)"
    if not opts.forceFallback then
        local graphs
        graphs, err = M.decode(opts.cachePath)
        if graphs then
            if opts.cacheFile then
                pcall(function()
                    local fh = io.open(opts.cacheFile, "wb")
                    if fh then fh:write(serialize(graphs)); fh:close() end
                end)
            end
            return graphs, "live"
        end
        if opts.cacheFile then
            local ok, cached = pcall(function()
                local chunk = loadfile(opts.cacheFile)
                return chunk and chunk()
            end)
            if ok and type(cached) == "table" and next(cached) then
                return cached, "cache"
            end
        end
    end
    -- Last resort: the bundled fallback shipped with the mod. Used when the live
    -- decode AND the self-written cache both fail (a build/distribution where the
    -- .Cache is unreadable or does not decode), or when forceFallback is set.
    -- Correct for the vanilla layout; a divergent layout there is simply
    -- unsupported until the bundle is refreshed.
    if opts.fallbackPath then
        local ok, bundled = pcall(function()
            local chunk = loadfile(opts.fallbackPath)
            return chunk and chunk()
        end)
        if ok and type(bundled) == "table" and next(bundled) then
            return bundled, "fallback"
        end
    end
    return nil, "none (" .. tostring(err) .. ")"
end

return M
