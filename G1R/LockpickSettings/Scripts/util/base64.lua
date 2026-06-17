-- base64.lua -- minimal base64 decode (PURE, stdlib only, no bit ops). The policy
-- data ships as base64 text (a .lua file) so mod hosts' malware scanners see source,
-- not an opaque high-entropy binary. Non-alphabet chars (newlines/padding) are skipped.

local string, table, math = string, table, math
local sbyte, schar, floor = string.byte, string.char, math.floor

local dec = {}
do
    local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #a do dec[sbyte(a, i)] = i - 1 end
end

local function decode(s)
    local parts, pn = {}, 0
    local buf, bn = {}, 0
    local acc, nbits = 0, 0
    for i = 1, #s do
        local v = dec[sbyte(s, i)]
        if v then
            acc = acc * 64 + v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                local p = 2 ^ nbits
                local byte = floor(acc / p)
                acc = acc - byte * p
                bn = bn + 1
                buf[bn] = schar(byte)
                if bn == 4096 then
                    pn = pn + 1; parts[pn] = table.concat(buf); bn = 0
                end
            end
        end
    end
    if bn > 0 then pn = pn + 1; parts[pn] = table.concat(buf, "", 1, bn) end
    return table.concat(parts)
end

return { decode = decode }
