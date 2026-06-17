-- inflate.lua -- raw DEFLATE decompressor (PURE, puff port). Arithmetic-only bit ops
-- so it behaves identically under LuaJIT and PUC Lua 5.4. Decodes the policy blobs.

local string, table, math = string, table, math
local sbyte, schar = string.byte, string.char
local floor = math.floor
local unpack = table.unpack or unpack

local POW2 = {}
for i = 0, 31 do POW2[i] = 2 ^ i end

-- length codes 257..285: base length, extra bits (1-indexed by sym-257+1)
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43,
    51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4,
    4, 4, 5, 5, 5, 5, 0 }
-- distance codes 0..29: base distance, extra bits
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
    385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9,
    10, 10, 11, 11, 12, 12, 13, 13 }
local CLORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- canonical Huffman from a 0-indexed code-length array -> { count, symbol }
local function build(lengths, n)
    local count = {}
    for len = 0, 15 do count[len] = 0 end
    for s = 0, n - 1 do count[lengths[s]] = count[lengths[s]] + 1 end
    local offs = { [1] = 0 }
    for len = 1, 15 do offs[len + 1] = offs[len] + count[len] end
    local symbol = {}
    for s = 0, n - 1 do
        local l = lengths[s]
        if l ~= 0 then symbol[offs[l]] = s; offs[l] = offs[l] + 1 end
    end
    return { count = count, symbol = symbol }
end

local function inflate(input)
    local pos = 1
    local bitbuf, bitcnt = 0, 0
    local inlen = #input

    local function getbits(need)
        while bitcnt < need do
            local b = sbyte(input, pos) or 0
            pos = pos + 1
            bitbuf = bitbuf + b * POW2[bitcnt]
            bitcnt = bitcnt + 8
        end
        local val = bitbuf % POW2[need]
        bitbuf = (bitbuf - val) / POW2[need]
        bitcnt = bitcnt - need
        return val
    end

    -- decode one canonical Huffman symbol, one bit at a time
    local function decode(h)
        local code, first, index = 0, 0, 0
        local count = h.count
        for len = 1, 15 do
            code = code + getbits(1)
            local c = count[len]
            if code - first < c then return h.symbol[index + (code - first)] end
            index = index + c
            first = (first + c) * 2
            code = code * 2
        end
        return nil
    end

    local out, outn = {}, 0
    local fixedLit, fixedDist -- built once on first fixed block

    local function codes(lh, dh)
        while true do
            local sym = decode(lh)
            if sym == nil then return false end
            if sym == 256 then return true end
            if sym < 256 then
                outn = outn + 1
                out[outn] = sym
            else
                sym = sym - 257
                if not LBASE[sym + 1] then return false end
                local length = LBASE[sym + 1] + getbits(LEXT[sym + 1])
                local dsym = decode(dh)
                if dsym == nil or not DBASE[dsym + 1] then return false end
                local dist = DBASE[dsym + 1] + getbits(DEXT[dsym + 1])
                local start = outn - dist
                if start < 0 then return false end
                for j = 1, length do
                    outn = outn + 1
                    out[outn] = out[start + j]
                end
            end
        end
    end

    repeat
        local final = getbits(1)
        local btype = getbits(2)
        if btype == 0 then
            -- stored: align to byte boundary, copy LEN raw bytes
            bitbuf, bitcnt = 0, 0
            local len = (sbyte(input, pos) or 0) + (sbyte(input, pos + 1) or 0) * 256
            pos = pos + 4 -- skip LEN(2) + NLEN(2)
            for _ = 1, len do
                outn = outn + 1
                out[outn] = sbyte(input, pos) or 0
                pos = pos + 1
            end
        elseif btype == 1 then
            if not fixedLit then
                local ll = {}
                for s = 0, 143 do ll[s] = 8 end
                for s = 144, 255 do ll[s] = 9 end
                for s = 256, 279 do ll[s] = 7 end
                for s = 280, 287 do ll[s] = 8 end
                local dl = {}
                for s = 0, 31 do dl[s] = 5 end
                fixedLit, fixedDist = build(ll, 288), build(dl, 32)
            end
            if not codes(fixedLit, fixedDist) then return nil, "bad fixed block" end
        elseif btype == 2 then
            local hlit = getbits(5) + 257
            local hdist = getbits(5) + 1
            local hclen = getbits(4) + 4
            local cl = {}
            for i = 0, 18 do cl[i] = 0 end
            for i = 1, hclen do cl[CLORDER[i]] = getbits(3) end
            local clh = build(cl, 19)
            local lengths = {}
            local n = 0
            while n < hlit + hdist do
                local sym = decode(clh)
                if sym == nil then return nil, "bad code-length symbol" end
                if sym < 16 then
                    lengths[n] = sym; n = n + 1
                elseif sym == 16 then
                    local prev = lengths[n - 1] or 0
                    for _ = 1, getbits(2) + 3 do lengths[n] = prev; n = n + 1 end
                elseif sym == 17 then
                    for _ = 1, getbits(3) + 3 do lengths[n] = 0; n = n + 1 end
                else -- 18
                    for _ = 1, getbits(7) + 11 do lengths[n] = 0; n = n + 1 end
                end
            end
            local litl, distl = {}, {}
            for i = 0, hlit - 1 do litl[i] = lengths[i] end
            for i = 0, hdist - 1 do distl[i] = lengths[hlit + i] end
            if not codes(build(litl, hlit), build(distl, hdist)) then
                return nil, "bad dynamic block"
            end
        else
            return nil, "bad block type"
        end
        if pos > inlen + 1 then return nil, "unexpected end of stream" end
    until final == 1

    -- assemble in chunks (table.unpack caps the per-call count)
    local res, ri = {}, 0
    for i = 1, outn, 1024 do
        ri = ri + 1
        res[ri] = schar(unpack(out, i, math.min(i + 1023, outn)))
    end
    return table.concat(res)
end

return { inflate = inflate }
