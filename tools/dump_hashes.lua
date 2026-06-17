-- dump_hashes.lua  --  inflate every shipped policy blob with the mod's pure-Lua
-- inflater and write per-blob hashes, to diff against tools/_hashes_py.txt
-- (Python zlib). Run with the Lua 5.4 runtime: tools/lua54/lua.exe tools/dump_hashes.lua
package.path = "G1R/LockpickSettings/Scripts/?.lua;" .. package.path
local Inflate = require("util.inflate")

local idx = assert(loadfile(
    "G1R/LockpickSettings/Scripts/data/lockpolicies_index.lua"))()
local fh = assert(io.open(
    "G1R/LockpickSettings/Scripts/data/lockpolicies.bin", "rb"))
local bin = fh:read("*a")
fh:close()

local function hashb(s)
    local h = 0
    for i = 1, #s do h = (h * 131 + string.byte(s, i)) % 2147483647 end
    return h
end

local names = {}
for k in pairs(idx) do names[#names + 1] = k end
table.sort(names)

local lines, bad = {}, 0
for _, name in ipairs(names) do
    local e = idx[name]
    local size = 7 ^ e.n
    for k = 0, 2 do
        local v = e.v[k + 1]
        local comp = bin:sub(v[1] + 1, v[1] + v[2]) -- offsets are 0-based
        local raw, err = Inflate.inflate(comp)
        if not raw then
            bad = bad + 1
            print("INFLATE FAIL " .. name .. " k" .. k .. " " .. tostring(err))
        else
            if #raw ~= size then
                bad = bad + 1
                print("LEN " .. name .. " k" .. k .. " " .. #raw .. " != " .. size)
            end
            lines[#lines + 1] = string.format("%s %d %d", name, k, hashb(raw))
        end
    end
end

local of = assert(io.open("tools/_hashes_lua.txt", "w"))
of:write(table.concat(lines, "\n") .. "\n")
of:close()
print("blobs " .. #lines .. "  bad " .. bad)
