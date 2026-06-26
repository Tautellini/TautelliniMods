-- cheats/lockpicking.lua  --  lockskill: set the player's lockpicking skill tier.
--
-- Gothic's picklock skill has three tiers, each a real GE_Skill_Picklock_*
-- gameplay effect the game's own skill system applies. Granting that effect is what
-- actually changes the minigame: the effect drives the Lockpicking attribute set's
-- LockpickPrecision (how many connections the game prunes), and the game reads that
-- aggregated value at lock setup. A raw attribute write does NOT hold here (GAS
-- recomputes CurrentValue from the active effects), so we grant the SKILL, never
-- poke the number. PURE of UE4SS globals: engine is injected.

local require, ipairs, math, string, tostring =
    require, ipairs, math, string, tostring
local args = require("util.args")

local lockpicking = {}

-- the three tiers, low to high. skill is the GE_Skill_Picklock_* short name the
-- engine resolver expands; value is the LockpickPrecision the tier yields (used for
-- the read-back report only). The middle tier is "Skilled" in-game (what players
-- often call "trained").
local TIERS = {
    { key = "untrained", label = "Untrained", skill = "Picklock_Untrained", value = 0 },
    { key = "skilled",   label = "Skilled",   skill = "Picklock_Skilled",   value = 1 },
    { key = "master",    label = "Master",    skill = "Picklock_Master",    value = 2 },
}

-- spoken tokens -> tier key. "trained" is the everyday word for the Skilled tier;
-- the bare numbers match the precision each tier grants.
local ALIASES = {
    untrained = "untrained", none = "untrained", ["0"] = "untrained",
    skilled = "skilled", trained = "skilled", ["1"] = "skilled",
    master = "master", ["2"] = "master",
}

local function tierByKey(key)
    for _, t in ipairs(TIERS) do if t.key == key then return t end end
    return nil
end

local function resolveTier(token)
    local key = ALIASES[args.lower(token)]
    return key and tierByKey(key) or nil
end

-- the live LockpickPrecision, or nil when there is no player set (not in-game).
local function readPrecision(engine)
    local set = engine.findPlayerAttrSet("AttributeSet_Lockpicking")
    if not set then return nil end
    return engine.readAttr(set, "LockpickPrecision")
end

-- name the tier a precision value corresponds to (for the status line).
local function tierNameFor(precision)
    if precision == nil then return "?" end
    local p = math.floor(precision + 0.5)
    if p <= 0 then return "Untrained" end
    if p == 1 then return "Skilled" end
    return "Master"
end

local function intStr(v)
    if v == nil then return "?" end
    return string.format("%d", math.floor(v + 0.5))
end

-- set the player's picklock tier to exactly `tier`: strip every picklock tier
-- effect first (so two tiers can never stack into a wrong precision), then grant the
-- target. Returns ok, info from the grant.
local function applyTier(engine, tier)
    for _, t in ipairs(TIERS) do engine.removeSkill(t.skill) end
    return engine.grantSkill(tier.skill)
end

local function doLockSkill(params, out, engine)
    if params[1] == nil then
        local p = readPrecision(engine)
        if p == nil then
            out.line("lockskill: no player Lockpicking set (be in-game)")
            return
        end
        out.line("lockskill = " .. tierNameFor(p) .. " (precision " .. intStr(p)
            .. "). Set with: lockskill untrained|skilled|master")
        return
    end
    local tier = resolveTier(params[1])
    if not tier then
        out.line("usage: lockskill untrained|skilled|master  (trained = skilled)")
        return
    end
    local before = readPrecision(engine)
    local ok, info = applyTier(engine, tier)
    if not ok then
        out.line("lockskill: could not grant " .. tier.label .. " ("
            .. tostring(info) .. ") -- be in-game")
        return
    end
    local after = readPrecision(engine)
    out.line("lockskill: " .. tierNameFor(before) .. " -> " .. tier.label
        .. " (precision " .. intStr(before) .. " -> " .. intStr(after) .. ")")
end

function lockpicking.specs()
    return {
        { name = "lockskill",
          help = "set lockpicking skill: lockskill untrained|skilled|master (trained = skilled)",
          run = function(p, out, engine) doLockSkill(p, out, engine) end },
    }
end

-- SharedModMenu section: one button per tier. They are one-shot actions (grant the
-- tier now); a button cannot show the current tier, so the live value stays a
-- console read (`lockskill`).
function lockpicking.menu(engine)
    local items = {}
    for _, tier in ipairs(TIERS) do
        items[#items + 1] = {
            name = tier.label, kind = "action",
            set = function() applyTier(engine, tier) end,
        }
    end
    return { title = "Lockpicking", items = items }
end

return lockpicking
