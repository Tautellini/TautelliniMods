-- cheats/lockpick.lua  --  lockmaster: max the lockpick attributes.
--
-- One-shot write of the player's Lockpicking set. Overlaps with the
-- LockpickSettings mod's tries boost, but is handy for a pure-cheat loadout.
-- PURE of UE4SS globals: engine is injected.

local lockpick = {}

-- Durability = number of allowed failed/refused moves before a pick breaks.
-- Precision = connections removed per broken pick (the master perk mechanic;
-- baseline 1.0). High values trivialize the minigame, which is the point here.
local DURABILITY = 99
local PRECISION  = 5

function lockpick.specs()
    return {
        { name = "lockmaster",
          help = "max lockpick durability + precision",
          run = function(p, out, engine)
              local set = engine.findPlayerAttrSet("AttributeSet_Lockpicking")
              if not set then
                  out.line("lockmaster: no player Lockpicking set (be in-game)")
                  return
              end
              local a = engine.writeAttr(set, "LockpickDurability", DURABILITY, DURABILITY)
              local b = engine.writeAttr(set, "LockpickPrecision", PRECISION, PRECISION)
              local tail = ""
              if not (a and b) then tail = " (one or both writes failed)" end
              out.line("lockmaster: durability=" .. DURABILITY
                  .. " precision=" .. PRECISION .. tail)
          end },
    }
end

return lockpick
