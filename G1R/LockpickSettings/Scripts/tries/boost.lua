-- boost.lua  --  the Extra-Tries feature (stateless module)
--
-- Independent of the hint/connection features: runs once per minigame start,
-- idempotent, no per-lock state, so it is a module, not a class. When the
-- lockpicking minigame starts and LockpickDurability sits at a known vanilla
-- tier base, raise it to base + that tier's extra. Already-boosted values are
-- recognized and left alone; unknown values are left untouched and logged.
-- Nothing can stack across sessions, saves or reloads.

local ipairs, pairs = ipairs, pairs
local type, tonumber = type, tonumber
local string, table = string, table

local boost = {}

-- The vanilla LockpickDurability per skill tier. These are GAME CONSTANTS, not
-- user config: the boost recognizes these exact values to identify the player's
-- tier, so a user changing them would break detection. They live here in code
-- on purpose, OUT of the user-editable config.lua. If a game patch ever changes
-- the vanilla values, fix them here.
boost.BASE_TRIES = { untrained = 2, trained = 4, master = 6 }

-- Normalize the configured extra into a per-tier number table. extraTries is a
-- per-tier table ({ untrained = 5, trained = 10, master = 20 }); a missing or
-- non-positive entry leaves that tier at its vanilla value. Anything that is not
-- a table boosts nothing (the single-number-for-all-tiers form was dropped).
function boost.perTier(extra)
    local out = {}
    if type(extra) == "table" then
        for name in pairs(boost.BASE_TRIES) do
            local v = tonumber(extra[name])
            out[name] = (v and v > 0) and v or 0
        end
    else
        for name in pairs(boost.BASE_TRIES) do out[name] = 0 end
    end
    return out
end

-- Build the lookup plan from the configured extra. Detection MUST stay
-- unambiguous: the boost recognizes a tier purely by its durability value, so a
-- boosted total that equals another tier's vanilla base (or another tier's
-- boosted total) could be misread and raised again (stacking). Any tier whose
-- total would collide is EXCLUDED from boosting and reported, never guessed.
-- Returns:
--   bases     : every vanilla base value -> tier name (all tiers are "known")
--   boostable : base -> { name, target } for tiers with a safe, positive boost
--   targets   : boosted total -> name (recognized later as already done)
--   effective : tier name -> the value the boost leaves it at (target or base)
--   skipped   : tier names dropped for a collision (sorted)
function boost.plan(extra)
    local perTier = boost.perTier(extra)
    local bases, boostable, targets, effective = {}, {}, {}, {}
    for name, base in pairs(boost.BASE_TRIES) do
        bases[base] = name
        effective[name] = base
    end
    -- a total is ambiguous if it lands on a vanilla base of another tier, or if
    -- two boosted tiers reach the same total
    local total, hits = {}, {}
    for name, base in pairs(boost.BASE_TRIES) do
        total[name] = base + perTier[name]
        if perTier[name] > 0 then hits[total[name]] = (hits[total[name]] or 0) + 1 end
    end
    local skipped = {}
    for name, base in pairs(boost.BASE_TRIES) do
        local t = total[name]
        if perTier[name] <= 0 then
            -- no boost requested for this tier; it stays vanilla but is "known"
        elseif (bases[t] and bases[t] ~= name) or hits[t] > 1 then
            skipped[#skipped + 1] = name
        else
            boostable[base] = { name = name, target = t }
            targets[t] = name
            effective[name] = t
        end
    end
    table.sort(skipped)
    return { bases = bases, boostable = boostable, targets = targets,
        effective = effective, skipped = skipped }
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
-- extra (number OR per-tier table, from config), the engine facade, num (for the
-- float-tolerant lookup), and log. The durability value identifies the skill
-- tier; the read tolerates float fuzz via num.lookup.
function boost.apply(extra, engine, num, log)
    local attr = boost.findPlayerAttrSet(engine)
    if not attr then
        log("Minigame started but no player attribute set found")
        return
    end
    local plan = boost.plan(extra)
    if #plan.skipped > 0 then
        log("Minigame: " .. table.concat(plan.skipped, ", ") .. " extra would land "
            .. "on another tier's durability, left vanilla (give each tier a clear "
            .. "total clear of 2/4/6 and of each other)")
    end
    local dur = attr.LockpickDurability
    local cur = dur.CurrentValue
    if num.lookup(plan.targets, cur) then
        return -- already boosted, nothing to do
    end
    local entry = num.lookup(plan.boostable, cur)
    if entry then
        dur.BaseValue, dur.CurrentValue = entry.target, entry.target
        log(string.format("Minigame: %s tier, tries %.0f -> %d", entry.name, cur, entry.target))
    elseif num.lookup(plan.bases, cur) then
        -- a known vanilla tier we are deliberately not boosting (0 or skipped)
        return
    else
        log(string.format("Minigame: durability %.2f not a known vanilla tier, "
            .. "leaving it alone (a game patch or another mod may have changed "
            .. "the base values; see boost.BASE_TRIES)", cur))
    end
end

return boost
