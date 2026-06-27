-- immersive/cost.lua -- PURE math for Immersive Mode: what an F6 auto-solve costs to clear a lock.
-- No engine, no UE4SS globals (loads under bare Lua for tests). A lock's difficulty is its connection
-- count. The skill it demands comes from two connection thresholds, the lockpick cost from a ratio.
-- See main.lua's immersive gate and the readout for the live reads (skill = LockpickPrecision, picks =
-- ItKe_Lockpick).

local math = math

local cost = {}

local SKILL_NAMES = { [0] = "Untrained", [1] = "Skilled", [2] = "Master" }
function cost.skillName(tier) return SKILL_NAMES[tier] or "?" end

-- the precision tier (0..2) a lock of `connections` difficulty demands, from two connection
-- thresholds: at or above masterAtConnections needs Master, at or above skilledAtConnections needs
-- Skilled, below that Untrained. Master is checked first so the result stays monotonic even if the
-- two thresholds are set out of order.
function cost.requiredSkill(connections, cfg)
    local c = connections or 0
    if cfg.masterAtConnections and c >= cfg.masterAtConnections then return 2 end
    if cfg.skilledAtConnections and c >= cfg.skilledAtConnections then return 1 end
    return 0
end

-- lockpicks an F6 solve costs for a lock of `connections` difficulty, clamped to [min, max].
function cost.lockpickCost(connections, cfg)
    local c = math.floor((connections or 0) * (cfg.lockpicksPerConnection or 0) + 0.5)
    local lo = cfg.lockpickCostMin or 0
    if c < lo then c = lo end
    local hi = cfg.lockpickCostMax
    if hi and c > hi then c = hi end
    return c
end

-- ore a successful pick rewards for a lock of `connections` difficulty, clamped to [min, max].
function cost.oreReward(connections, cfg)
    local r = math.floor((connections or 0) * (cfg.orePerConnection or 0) + 0.5)
    local lo = cfg.oreRewardMin or 0
    if r < lo then r = lo end
    local hi = cfg.oreRewardMax
    if hi and r > hi then r = hi end
    return r
end

-- may the solver clear this lock? Fail-OPEN on an unreadable skill or pick count (never block on a
-- read failure). Returns ok, hasSkill, canAfford, requiredTier, lockpickCost.
function cost.evaluate(connections, precision, lockpicks, cfg)
    local req = cost.requiredSkill(connections, cfg)
    local c = cost.lockpickCost(connections, cfg)
    local hasSkill = (precision == nil) or (precision >= req)
    local canAfford = (lockpicks == nil) or (lockpicks >= c)
    return (hasSkill and canAfford), hasSkill, canAfford, req, c
end

return cost
