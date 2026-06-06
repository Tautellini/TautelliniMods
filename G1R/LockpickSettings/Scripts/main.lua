-- EasyLockpicking for Gothic 1 Remake (v7.1 "tries only")
-- Grants extra lockpick tries, transiently:
--   * minigame starts -> durability raised to vanilla + extraTries
--   * minigame ends   -> exact vanilla restored
-- Nothing persists: stored stats, saves and locks stay 100% vanilla.
-- No RegisterHook calls (they crash in this AngelScript engine, see SPEC.md).
--
--   CTRL+ALT+F6 = print status
--   CTRL+R      = hot-reload after editing config.lua

local function log(msg)
    print("[EasyLockpicking] " .. tostring(msg) .. "\n")
end

-- ---------------------------------------------------------------- config --
package.loaded["config"] = nil -- ensure CTRL+R picks up edits
local okCfg, Config = pcall(require, "config")
if not okCfg or type(Config) ~= "table" then
    log("ERROR in config.lua, using built-in defaults (" .. tostring(Config) .. ")")
    Config = {}
end
local ExtraByVanilla = Config.extraTriesByVanilla or { [4] = 6 }
local ExtraDefault   = Config.extraTriesDefault or 4

local function extraFor(vanilla)
    -- table keys are exact vanilla values; tolerate float fuzz
    for v, extra in pairs(ExtraByVanilla) do
        if math.abs(vanilla - v) < 0.001 then return extra, true end
    end
    return ExtraDefault, false
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

-- ------------------------------------------------------- session handling --
local boost = nil   -- { vanilla = x, applied = y } while a session is boosted
local watching = false
local lastLogged = nil

local function applyBoost()
    local attr = findPlayerAttrSet()
    if not attr then
        log("Minigame started but no player attribute set found")
        return
    end
    local ok, err = pcall(function()
        local dur = attr.LockpickDurability
        local vanilla = dur.CurrentValue
        if boost and math.abs(vanilla - boost.applied) < 0.001 then
            log("Minigame: boost still active from previous attempt, keeping it")
            return
        end
        local extra, known = extraFor(vanilla)
        local target = vanilla + extra
        dur.BaseValue, dur.CurrentValue = target, target
        boost = { vanilla = vanilla, applied = target }
        lastLogged = target
        log(string.format("Minigame: vanilla durability %.0f (+%d tries) -> %.0f%s",
            vanilla, extra, target,
            known and "" or "  [unknown tier, used default; tell the modder this vanilla value]"))
    end)
    if not ok then log("Boost error: " .. tostring(err)) end
end

local function restoreVanilla()
    if not boost then return end
    local attr = findPlayerAttrSet()
    if attr then
        pcall(function()
            local dur = attr.LockpickDurability
            -- Only restore if the value is still ours. If the game changed it
            -- meanwhile (skill-up, effect reapply), respect the game's value.
            if math.abs(dur.CurrentValue - boost.applied) < 0.001 then
                dur.BaseValue, dur.CurrentValue = boost.vanilla, boost.vanilla
                log(string.format("Minigame ended: durability restored to %.0f", boost.vanilla))
            else
                log(string.format("Minigame ended: game changed durability to %.2f, leaving it alone",
                    dur.CurrentValue))
            end
        end)
    end
    boost = nil
end

local function liveTaskExists()
    local ok, tasks = pcall(FindAllOf, "AbilityTask_LockPick")
    if not ok or not tasks then return false end
    for _, t in ipairs(tasks) do
        if t:IsValid() and not string.find(t:GetFullName(), "Default__", 1, true) then
            return true
        end
    end
    return false
end

local function watchSession()
    if watching then return end
    watching = true
    LoopAsync(1000, function()
        local done = false
        ExecuteInGameThread(function()
            if not liveTaskExists() then
                watching = false
                done = true
                restoreVanilla()
                return
            end
            -- research bonus: log how failures consume durability
            local attr = findPlayerAttrSet()
            if attr then
                local cur = attr.LockpickDurability.CurrentValue
                if lastLogged ~= nil and math.abs(cur - lastLogged) > 0.001 then
                    log(string.format("Durability during minigame: %.2f -> %.2f", lastLogged, cur))
                end
                lastLogged = cur
            end
        end)
        return done
    end)
end

local okNotify, errNotify = pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick",
    function(task)
        -- Apply synchronously: this callback runs on the game thread during
        -- task construction, BEFORE the minigame snapshots durability.
        -- (A deferred ExecuteInGameThread arrived too late for the first
        -- session of a game run: pick broke at vanilla 4 despite the boost.)
        applyBoost()
        watchSession()
    end)
if not okNotify then
    log("ERROR: could not register minigame notification: " .. tostring(errNotify))
end

-- ---------------------------------------------------------------- status --
RegisterKeyBind(Key.F6, {ModifierKey.CONTROL, ModifierKey.ALT}, function()
    ExecuteInGameThread(function()
        local attr = findPlayerAttrSet()
        if not attr then
            log("Status: no player attribute set (not in game?)")
            return
        end
        local dur, prec = attr.LockpickDurability, attr.LockpickPrecision
        log(string.format("Status: Durability Base=%.2f Current=%.2f | Precision Base=%.2f Current=%.2f | boost %s",
            dur.BaseValue, dur.CurrentValue, prec.BaseValue, prec.CurrentValue,
            boost and "ACTIVE" or "inactive"))
    end)
end)

log("v7.1 tries-only loaded. Extra tries apply only while the minigame runs.")
