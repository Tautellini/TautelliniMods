-- EasyLockpicking for Gothic 1 Remake (v8.2 "per-tier")
-- One behavior, set up once at mod load, driven by config.lua:
--   when the lockpicking minigame starts and LockpickDurability is at a
--   known vanilla tier base (config.baseTries), it is raised to
--   base + config.extraTries. Defaults: 2/4/6 -> 12/14/16.
-- Already-raised values are recognized and left alone (idempotent), so
-- values can never stack or run away across sessions, saves or reloads.
-- Unrecognized values are left untouched and logged.
-- No hotkeys, no polling loops, no restore pass, no RegisterHook calls
-- (those crash in this AngelScript engine, see SPEC.md).

local function log(msg)
    print("[EasyLockpicking] " .. tostring(msg) .. "\n")
end

-- ---------------------------------------------------------------- config --
local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end
local BaseTries  = Config.baseTries or { untrained = 2, trained = 4, master = 6 }
local ExtraTries = tonumber(Config.extraTries) or 10

-- value -> tier lookup tables, built once
local Tiers = {} -- vanilla base -> { name, target }
local Targets = {} -- boosted target -> tier name
for name, base in pairs(BaseTries) do
    local target = base + ExtraTries
    Tiers[base] = { name = name, target = target }
    Targets[target] = name
end

local function lookup(tbl, value)
    -- table keys are exact values; tolerate float fuzz
    for k, v in pairs(tbl) do
        if math.abs(value - k) < 0.001 then return v end
    end
    return nil
end

-- ------------------------------------------------------------ attributes --
local function findPlayerAttrSet()
    local ok, sets = pcall(FindAllOf, "AttributeSet_Lockpicking")
    if not ok or not sets then return nil end
    for _, s in ipairs(sets) do
        if s:IsValid() then
            local full = s:GetFullName()
            if not string.find(full, "Default__", 1, true)
                and string.find(full, "PlayerState", 1, true) then
                return s
            end
        end
    end
    return nil
end

-- ----------------------------------------------------------------- boost --
-- The callback runs on the game thread during task construction, BEFORE
-- the minigame snapshots durability (verified in v7.1).
local okNotify, errNotify = pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick",
    function()
        local ok, err = pcall(function()
            local attr = findPlayerAttrSet()
            if not attr then
                log("Minigame started but no player attribute set found")
                return
            end
            local dur = attr.LockpickDurability
            local cur = dur.CurrentValue
            local tier = lookup(Tiers, cur)
            if tier then
                dur.BaseValue, dur.CurrentValue = tier.target, tier.target
                log(string.format("Minigame: %s tier, tries %.0f -> %d", tier.name, cur, tier.target))
            elseif lookup(Targets, cur) then
                -- already boosted, nothing to do
            else
                log(string.format("Minigame: durability %.2f not a known tier, leaving it alone "
                    .. "(check config.baseTries)", cur))
            end
        end)
        if not ok then log("Boost error: " .. tostring(err)) end
    end)
if not okNotify then
    log("ERROR: could not register minigame notification: " .. tostring(errNotify))
end

local loaded = {}
for name, base in pairs(BaseTries) do
    loaded[#loaded + 1] = string.format("%s %d->%d", name, base, base + ExtraTries)
end
log("v8.2 per-tier loaded: " .. table.concat(loaded, ", "))
