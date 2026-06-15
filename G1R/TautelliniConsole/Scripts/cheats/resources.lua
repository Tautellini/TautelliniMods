-- cheats/resources.lua  --  god, heal, mana, oxygen, nofatigue.
--
-- All one-shot writes over the player's live attribute sets (the proven
-- tries/boost.lua seam, here via engine.findPlayerAttrSet). god is the only
-- stateful command, and only to make a bare `god` flip; it does NOT run a tick
-- loop (one-shot per the spec). PURE of UE4SS globals: engine is injected.

local require, tostring = require, tostring
local args = require("util.args")

local resources = {}

-- last god toggle, so a bare `god` flips. Per-load module state (resets on a
-- full game restart, which is fine: god is off by default).
local godOn = false

-- fill a value attribute to its paired max on the player's set.
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
    if engine.writeAttr(set, valueAttr, nil, maxv) then
        out.line(label .. ": " .. valueAttr .. " filled to " .. tostring(maxv))
    else
        out.line(label .. ": write failed")
    end
end

local function doGod(params, out, engine)
    local verb = args.toggleVerb(params[1])
    if verb == nil then
        out.line("usage: god [on|off]")
        return
    end
    local want
    if verb == "toggle" then want = not godOn else want = (verb == "on") end

    local set = engine.findPlayerAttrSet("AttributeSet_Health")
    if not set then
        out.line("god: no player Health set (be in-game)")
        return
    end
    if want then
        local maxv = engine.readAttr(set, "MaxHealth")
        if maxv then engine.writeAttr(set, "Health", nil, maxv) end
        engine.writeAttr(set, "DamageMultiplier", 0, 0)
        godOn = true
        out.line("god ON: health filled, DamageMultiplier=0. If you still take "
            .. "damage, that multiplier is your OUTGOING damage; tell me and I'll "
            .. "switch the lever.")
    else
        engine.writeAttr(set, "DamageMultiplier", 1, 1)
        godOn = false
        out.line("god OFF: DamageMultiplier restored to 1.")
    end
end

function resources.specs()
    return {
        { name = "god",
          help = "invulnerability toggle [on|off] (one-shot write)",
          run = function(p, out, engine) doGod(p, out, engine) end },
        { name = "heal",
          help = "fill Health to max",
          run = function(p, out, engine)
              refill(engine, "AttributeSet_Health", "Health", "MaxHealth", out, "heal")
          end },
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
          run = function(p, out, engine)
              local set = engine.findPlayerAttrSet("AttributeSet_Fatigue")
              if not set then
                  out.line("nofatigue: no player Fatigue set (be in-game)")
                  return
              end
              local ok = engine.writeAttr(set, "Fatigue", 0, 0)
              engine.writeAttr(set, "FillRatio", 0, 0) -- best effort; may not exist
              if ok then
                  out.line("nofatigue: Fatigue set to 0 (if that made you MORE "
                      .. "tired, the scale is inverted, tell me)")
              else
                  out.line("nofatigue: write failed")
              end
          end },
    }
end

return resources
