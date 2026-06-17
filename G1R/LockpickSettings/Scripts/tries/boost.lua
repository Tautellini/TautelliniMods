-- boost.lua -- the Extra-Tries feature: raise LockpickDurability once per minigame
-- start. Stateless, idempotent; nothing stacks across sessions/saves/reloads.

local ipairs, pairs = ipairs, pairs
local type, tonumber = type, tonumber
local string, table = string, table

local boost = {}

-- vanilla LockpickDurability per tier. GAME CONSTANTS used to detect the tier, so
-- they live here, not in config.lua. Fix here if a game patch changes them.
boost.BASE_TRIES = { untrained = 2, trained = 4, master = 6 }

-- normalize the configured extra into a per-tier number table; non-table boosts nothing.
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

-- build the lookup plan. A boosted total that collides with another tier's base or
-- another boosted total is ambiguous (could be re-boosted = stacking), so that tier
-- is excluded and reported, never guessed. Returns bases (base->name), boostable
-- (base->{name,target}), targets (total->name), effective (name->resulting value),
-- skipped (collided tiers, sorted).
function boost.plan(extra)
    local perTier = boost.perTier(extra)
    local bases, boostable, targets, effective = {}, {}, {}, {}
    for name, base in pairs(boost.BASE_TRIES) do
        bases[base] = name
        effective[name] = base
    end
    local total, hits = {}, {}
    for name, base in pairs(boost.BASE_TRIES) do
        total[name] = base + perTier[name]
        if perTier[name] > 0 then hits[total[name]] = (hits[total[name]] or 0) + 1 end
    end
    local skipped = {}
    for name, base in pairs(boost.BASE_TRIES) do
        local t = total[name]
        if perTier[name] <= 0 then
            -- no boost; stays vanilla but known
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

-- raise the tries. The durability value identifies the tier (num.lookup tolerates
-- float fuzz); already-boosted and unknown values are left alone.
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
        return -- already boosted
    end
    local entry = num.lookup(plan.boostable, cur)
    if entry then
        dur.BaseValue, dur.CurrentValue = entry.target, entry.target
        log(string.format("Minigame: %s tier, tries %.0f -> %d", entry.name, cur, entry.target))
    elseif num.lookup(plan.bases, cur) then
        return -- known vanilla tier we are deliberately not boosting (0 or skipped)
    else
        log(string.format("Minigame: durability %.2f not a known vanilla tier, "
            .. "leaving it alone (a game patch or another mod may have changed "
            .. "the base values; see boost.BASE_TRIES)", cur))
    end
end

return boost
