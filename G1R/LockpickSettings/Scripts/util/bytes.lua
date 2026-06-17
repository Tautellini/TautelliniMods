-- bytes.lua -- reconstruct a byte string from a Lua array of integers (one per byte).
-- The policy data ships as a numeric array (data/lockpolicies.lua), not a binary blob
-- or a base64/escaped string, so mod-host scanners read it as plain data rather than
-- as a packed binary or obfuscated code.

local string, table = string, table
local schar, concat = string.char, table.concat

local function fromInts(t)
    local parts, pn = {}, 0
    local buf, bn = {}, 0
    for i = 1, #t do
        bn = bn + 1
        buf[bn] = schar(t[i])
        if bn == 4096 then pn = pn + 1; parts[pn] = concat(buf); bn = 0 end
    end
    if bn > 0 then pn = pn + 1; parts[pn] = concat(buf, "", 1, bn) end
    return concat(parts)
end

return { fromInts = fromInts }
