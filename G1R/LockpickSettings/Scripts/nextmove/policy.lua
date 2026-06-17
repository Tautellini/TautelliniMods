-- policy.lua -- shipped next-move LOOKUP (PURE: stdlib only, no UE4SS globals; io
-- only via the injected readBlob). Replaces the runtime search: the optimal move for
-- every solvable state x precision variant (live edges = authored minus first k) is
-- precomputed (tools/build_policies.py) into data/lockpolicies.bin; on open we inflate
-- one lock+variant and answer :move(rots) by a single byte lookup.

local setmetatable = setmetatable
local string, math = string, math
local sbyte = string.byte
local floor = math.floor

local Inflate = require("util.inflate")

-- base-7 state code (rot+3 per piece), or nil if any rotation is off the rail
local function encode(rots, n, place)
    local S = 0
    for id = 0, n - 1 do
        local r = rots[id]
        if not r or r < -3 or r > 3 then return nil end
        S = S + (r + 3) * place[id]
    end
    return S
end

local Lock = {}
Lock.__index = Lock

-- move byte = piece*2 + (dir>0 and 1 or 0) + 1; 0 = none / at goal / unreachable
function Lock:move(rots)
    local idx = encode(rots, self.n, self.place)
    if not idx then return nil end
    local b = sbyte(self.arr, idx + 1)
    if not b or b == 0 then return nil end
    local m = b - 1
    return { piece = floor(m / 2), dir = (m % 2 == 1) and 1 or -1 }
end

local Policy = {}
Policy.__index = Policy

-- opts: { index = <lockName -> {n, v={{off,len}x3}}>, readBlob = fn(off,len)->str, log }
function Policy.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Policy)
    self.index = opts.index or {}
    self.readBlob = opts.readBlob
    self.log = opts.log or function() end
    return self
end

function Policy:has(lockName)
    return self.index[lockName] ~= nil
end

-- open the lock's policy at precision (clamped 0..2); nil if absent or decode fails
function Policy:open(lockName, precision)
    local e = self.index[lockName]
    if not e or not self.readBlob then return nil end
    local k = floor((precision or 0) + 0.5)
    if k < 0 then k = 0 elseif k > 2 then k = 2 end
    local v = e.v[k + 1]
    if not v then return nil end
    local comp = self.readBlob(v[1], v[2])
    if not comp or #comp == 0 then return nil end
    local arr = Inflate.inflate(comp)
    if not arr or #arr ~= 7 ^ e.n then return nil end -- size mismatch = corrupt
    local place = {}
    local p = 1
    for id = 0, e.n - 1 do place[id] = p; p = p * 7 end
    return setmetatable({ arr = arr, n = e.n, place = place }, Lock)
end

Policy._encode = encode -- for the test suite

return Policy
