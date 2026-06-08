-- boost.lua  --  the Extra-Tries feature (stateless module)
--
-- Independent of the hint/connection features: runs once per minigame start,
-- idempotent, no per-lock state, so it is a module, not a class. When the
-- lockpicking minigame starts and LockpickDurability sits at a known vanilla
-- tier base, raise it to base + extra. Already-boosted values are recognized
-- and left alone; unknown values are left untouched and logged. Nothing can
-- stack across sessions, saves or reloads.

local ipairs, pairs = ipairs, pairs
local string = string

local boost = {}

-- The vanilla LockpickDurability per skill tier. These are GAME CONSTANTS, not
-- user config: the boost recognizes these exact values to identify the player's
-- tier, so a user changing them would break detection. They live here in code
-- on purpose, OUT of the user-editable config.lua (which exposes only
-- extraTries). If a game patch ever changes the vanilla values, fix them here.
boost.BASE_TRIES = { untrained = 2, trained = 4, master = 6 }

-- value lookups for a given extra, built from BASE_TRIES:
--   tiers   : vanilla base   -> { name, target }  (recognize a tier, raise it)
--   targets : boosted target -> name              (recognize already-boosted)
function boost.tierTables(extraTries)
    local tiers, targets = {}, {}
    for name, base in pairs(boost.BASE_TRIES) do
        local target = base + extraTries
        tiers[base] = { name = name, target = target }
        targets[target] = name
    end
    return tiers, targets
end

-- the player's lockpicking attribute set (the one under PlayerState).
function boost.findPlayerAttrSet(engine)
    for _, s in ipairs(engine.liveInstances("AttributeSet_Lockpicking")) do
        if string.find(s:GetFullName(), "PlayerState", 1, true) then
            return s
        end
    end
    return nil
end

-- raise the tries. deps are injected so the boost is decoupled from the engine:
-- extraTries (from config), the engine facade, num (for lookup), and log. The
-- durability value identifies the skill tier; the read tolerates float fuzz via
-- num.lookup.
function boost.apply(extraTries, engine, num, log)
    local attr = boost.findPlayerAttrSet(engine)
    if not attr then
        log("Minigame started but no player attribute set found")
        return
    end
    local tiers, targets = boost.tierTables(extraTries)
    local dur = attr.LockpickDurability
    local cur = dur.CurrentValue
    local tier = num.lookup(tiers, cur)
    if tier then
        dur.BaseValue, dur.CurrentValue = tier.target, tier.target
        log(string.format("Minigame: %s tier, tries %.0f -> %d", tier.name, cur, tier.target))
    elseif num.lookup(targets, cur) then
        -- already boosted, nothing to do
    else
        log(string.format("Minigame: durability %.2f not a known vanilla tier, "
            .. "leaving it alone (a game patch or another mod may have changed "
            .. "the base values; see boost.BASE_TRIES)", cur))
    end
end

return boost
