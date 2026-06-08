-- boost.lua  --  the Extra-Tries feature (stateless module)
--
-- Independent of the hint/connection features: runs once per minigame start,
-- idempotent, no per-lock state, so it is a module, not a class. When the
-- lockpicking minigame starts and LockpickDurability sits at a known vanilla
-- tier base, raise it to base + extra. Already-boosted values are recognized
-- and left alone; unknown values are left untouched and logged. Nothing can
-- stack across sessions, saves or reloads.

local ipairs = ipairs
local string = string

local boost = {}

-- the player's lockpicking attribute set (the one under PlayerState).
function boost.findPlayerAttrSet(engine)
    for _, s in ipairs(engine.liveInstances("AttributeSet_Lockpicking")) do
        if string.find(s:GetFullName(), "PlayerState", 1, true) then
            return s
        end
    end
    return nil
end

-- raise the tries. deps are injected so the boost math is decoupled from
-- config parsing and the engine: tiers (vanilla base -> {name, target}),
-- targets (boosted target -> name), the engine facade, num (for lookup), and
-- log. The durability value identifies the skill tier; the read tolerates
-- float fuzz via num.lookup.
function boost.apply(tiers, targets, engine, num, log)
    local attr = boost.findPlayerAttrSet(engine)
    if not attr then
        log("Minigame started but no player attribute set found")
        return
    end
    local dur = attr.LockpickDurability
    local cur = dur.CurrentValue
    local tier = num.lookup(tiers, cur)
    if tier then
        dur.BaseValue, dur.CurrentValue = tier.target, tier.target
        log(string.format("Minigame: %s tier, tries %.0f -> %d", tier.name, cur, tier.target))
    elseif num.lookup(targets, cur) then
        -- already boosted, nothing to do
    else
        log(string.format("Minigame: durability %.2f not a known tier, leaving it alone "
            .. "(check config.baseTries)", cur))
    end
end

return boost
