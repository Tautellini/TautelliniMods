-- EasyLockpicking for Gothic 1 Remake (v8 "bare minimum")
-- One behavior, set up once at mod load, driven by config.lua:
--   every time the lockpicking minigame starts, LockpickDurability is
--   raised to at least Config.minTries.
-- The write is idempotent (applying it twice changes nothing), so values
-- can never stack or run away across sessions, saves or reloads.
-- No hotkeys, no polling loops, no restore pass, no RegisterHook calls
-- (those crash in this AngelScript engine, see SPEC.md).

local function log(msg)
    print("[EasyLockpicking] " .. tostring(msg) .. "\n")
end

-- ---------------------------------------------------------------- config --
local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in default (" .. tostring(Config) .. ")")
    Config = {}
end
local MinTries = tonumber(Config.minTries) or 14

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
            if dur.CurrentValue < MinTries then
                log(string.format("Minigame: durability %.0f -> %d", dur.CurrentValue, MinTries))
                dur.BaseValue, dur.CurrentValue = MinTries, MinTries
            end
        end)
        if not ok then log("Boost error: " .. tostring(err)) end
    end)
if not okNotify then
    log("ERROR: could not register minigame notification: " .. tostring(errNotify))
end

log(string.format("v8 bare-minimum loaded: every minigame starts with at least %d tries.", MinTries))
