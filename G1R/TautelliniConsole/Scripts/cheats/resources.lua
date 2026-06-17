-- cheats/resources.lua  --  god, heal, mana, oxygen, nofatigue.
--
-- These drive the GAME'S OWN functions through the engine adapter, not raw attribute
-- writes, so the HUD repaints (see ../../docs/cheat-techniques.md):
--   god   -> CombatConfig m_GodMode flag (real invulnerability) + a full Heal.
--   heal  -> the character Heal mixin (proper GAS path; the bar updates).
-- mana/oxygen/nofatigue still use the attribute write until their mixins are mapped;
-- the value is correct (the character window shows it) but those bars may lag.
-- PURE of UE4SS globals: engine is injected.

local require, tostring = require, tostring
local args = require("util.args")

local resources = {}

-- a silent output sink for the menu path: a menu action has no console device, so
-- the same apply helpers take this and just skip their feedback line.
local noopOut = { line = function() end }

-- last god toggle, so a bare `god` flips. Per-load module state (resets on a
-- full game restart, which is fine: god is off by default).
local godOn = false

-- fill a value attribute to its paired max on the player's set (raw write; correct
-- value, but the bar may not repaint until a mixin is found for this resource).
local function refill(engine, setName, valueAttr, maxAttr, out, label)
    local set = engine.findPlayerAttrSet(setName)
    if not set then
        out.line(label .. ": no player " .. setName .. " (be in-game)")
        return
    end
    local maxv = engine.readAttr(set, maxAttr)
    if not maxv then
        out.line(label .. ": could not read " .. maxAttr)
        return
    end
    if engine.writeAttr(set, valueAttr, maxv, maxv) then
        out.line(label .. ": " .. valueAttr .. " filled to " .. tostring(maxv))
    else
        out.line(label .. ": write failed")
    end
end

-- heal Health to full through the character Heal mixin, so the HUD bar repaints.
local function healFull(engine, out)
    if engine.healFull() then
        out.line("heal: Health restored to full")
    else
        out.line("heal: Heal mixin unavailable (be in-game)")
    end
end

-- set Fatigue (and best-effort FillRatio) to 0. Shared by `nofatigue` and the menu.
local function clearFatigue(engine, out)
    local set = engine.findPlayerAttrSet("AttributeSet_Fatigue")
    if not set then
        out.line("nofatigue: no player Fatigue set (be in-game)")
        return
    end
    local ok = engine.writeAttr(set, "Fatigue", 0, 0)
    engine.writeAttr(set, "FillRatio", 0, 0) -- best effort; may not exist
    if ok then
        out.line("nofatigue: Fatigue set to 0")
    else
        out.line("nofatigue: write failed")
    end
end

-- god on/off via the CombatConfig m_GodMode cheat flag (the lever the combat code
-- reads, set on the CDO + any live config), plus a full Heal when turned on. Shared
-- by the command and the menu toggle. Returns a one-line status; sets godOn.
local function setGod(engine, want)
    local ok = engine.setCombatFlag("m_GodMode", want and true or false)
    if not ok then return "god: no CombatConfig found (be in-game)" end
    godOn = want
    if want then
        engine.healFull()
        return "god ON: invulnerable (m_GodMode) + healed."
    end
    return "god OFF."
end

function resources.isGodOn() return godOn end

-- parrycheat: every melee attack auto-parries, via the CombatConfig flag.
local parryOn = false
local function setParry(engine, want)
    if not engine.setCombatFlag("m_ParryCheatMode", want and true or false) then
        return "parrycheat: no CombatConfig found (be in-game)"
    end
    parryOn = want
    return "parrycheat: " .. (want and "ON" or "OFF")
end
function resources.isParryOn() return parryOn end

-- onehit: a huge Strength + Dexterity boost so hits one-shot. Reverted on OFF, so
-- the boost is tracked and never double-applied. Magic damage does not scale, so
-- it is not covered.
local ONEHIT_BOOST = 100000.0
local oneHitOn = false
local function setOneHit(engine, want)
    want = want and true or false
    if want ~= oneHitOn then
        local sign = want and 1 or -1
        engine.incStatViaMixin("IncreaseStrengthAttributeBy", sign * ONEHIT_BOOST)
        engine.incStatViaMixin("IncreaseDexterityAttributeBy", sign * ONEHIT_BOOST)
        oneHitOn = want
    end
    return "onehit: " .. (want and "ON" or "OFF")
end
function resources.isOneHitOn() return oneHitOn end

-- shared on/off/toggle handler for the simple combat flags
local function doToggle(params, out, name, cur, apply)
    local verb = args.toggleVerb(params[1])
    if verb == nil then out.line("usage: " .. name .. " [on|off]"); return end
    local want
    if verb == "toggle" then want = not cur else want = (verb == "on") end
    out.line(apply(want))
end

local function doGod(params, out, engine)
    doToggle(params, out, "god", godOn, function(w) return setGod(engine, w) end)
end

function resources.specs()
    return {
        { name = "god",
          help = "invulnerability toggle [on|off] (CombatConfig m_GodMode)",
          run = function(p, out, engine) doGod(p, out, engine) end },
        { name = "heal",
          help = "restore Health to full (proper heal; bar updates)",
          run = function(p, out, engine) healFull(engine, out) end },
        { name = "mana",
          help = "fill Mana to max",
          run = function(p, out, engine)
              refill(engine, "AttributeSet_Mana", "Mana", "MaxMana", out, "mana")
          end },
        { name = "oxygen",
          help = "fill Oxygen to max",
          run = function(p, out, engine)
              refill(engine, "AttributeSet_Oxygen", "Oxygen", "MaxOxygen", out, "oxygen")
          end },
        { name = "nofatigue",
          help = "clear tiredness (set Fatigue to 0)",
          run = function(p, out, engine) clearFatigue(engine, out) end },
        { name = "parrycheat",
          help = "auto-parry every melee attack [on|off]",
          run = function(p, out, engine)
              doToggle(p, out, "parrycheat", parryOn, function(w) return setParry(engine, w) end)
          end },
        { name = "onehit",
          help = "one-hit kills (huge STR/DEX) [on|off]",
          run = function(p, out, engine)
              doToggle(p, out, "onehit", oneHitOn, function(w) return setOneHit(engine, w) end)
          end },
    }
end

-- SharedModMenu section: god as a live toggle, the refills + fatigue clear as
-- one-shot actions. Same apply helpers as the commands, so menu and console agree.
function resources.menu(engine)
    return { title = "Player", items = {
        { name = "God Mode", kind = "bool",
          get = function() return godOn end,
          set = function(v) setGod(engine, v and true or false) end },
        { name = "Auto-Parry", kind = "bool",
          get = function() return parryOn end,
          set = function(v) setParry(engine, v and true or false) end },
        { name = "One-Hit Kills", kind = "bool",
          get = function() return oneHitOn end,
          set = function(v) setOneHit(engine, v and true or false) end },
        { name = "Heal (full HP)", kind = "action",
          set = function() engine.healFull() end },
        { name = "Restore Mana", kind = "action",
          set = function() refill(engine, "AttributeSet_Mana", "Mana", "MaxMana", noopOut, "mana") end },
        { name = "Restore Oxygen", kind = "action",
          set = function() refill(engine, "AttributeSet_Oxygen", "Oxygen", "MaxOxygen", noopOut, "oxygen") end },
        { name = "Clear Fatigue", kind = "action",
          set = function() clearFatigue(engine, noopOut) end },
    } }
end

return resources
