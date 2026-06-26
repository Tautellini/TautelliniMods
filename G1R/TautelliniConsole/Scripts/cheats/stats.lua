-- cheats/stats.lua  --  str, dex, level, skillpoints, xp, speed.
--
-- Subcommand grammar: `<stat> add|remove|set <n>`, bare `<stat>` prints the
-- current value. Additive (add/remove) is the standard and always available;
-- `set` (absolute) is offered only where a target number makes sense (xp is
-- additive-only). PURE of UE4SS globals: engine is injected.

local require, ipairs, math, string, tonumber =
    require, ipairs, math, string, tonumber
local args = require("util.args")

local stats = {}

-- one row per command. setName/attr are the live attribute set class and the
-- attribute field; canSet gates the absolute form; fmt picks integer vs float
-- display. The class names follow the AttributeSet_Lockpicking precedent and are
-- confirmed in-game (a wrong name just logs "no player set", never crashes).
-- label + menu drive the SharedModMenu row (stats.menu): a settable stat becomes a
-- num slider over menu.min/max/step; an additive-only stat (xp) becomes a one-shot
-- "Add menu.add" action.
local DEFS = {
    { name = "str",         setName = "AttributeSet_Strength",         attr = "Strength",      canSet = true,  fmt = "int",   label = "Strength",     menu = { min = 0,   max = 200, step = 1 } },
    { name = "dex",         setName = "AttributeSet_Dexterity",        attr = "Dexterity",     canSet = true,  fmt = "int",   label = "Dexterity",    menu = { min = 0,   max = 200, step = 1 } },
    { name = "level",       setName = "AttributeSet_LevelProgression", attr = "Level",         canSet = true,  fmt = "int",   label = "Level",        menu = { min = 1,   max = 100, step = 1 } },
    { name = "skillpoints", setName = "AttributeSet_LevelProgression", attr = "SkillPoints",   canSet = true,  fmt = "int",   label = "Skill Points", menu = { min = 0,   max = 200, step = 1 } },
    { name = "xp",          setName = "AttributeSet_LevelProgression", attr = "Experience",    canSet = false, fmt = "int",   label = "XP" },
    -- speed has no menu row: it does not apply yet and will live under Movement, not
    -- Stats, once it works (the `speed` command stays for testing).
    { name = "speed",       setName = "AttributeSet_Movement",         attr = "SpeedModifier", canSet = true,  fmt = "float" },
    -- Lockpicking is NOT a stat row: a raw LockpickPrecision write does not hold (GAS
    -- recomputes it from the active skill effects). It lives in cheats/lockpicking.lua,
    -- which grants the real GE_Skill_Picklock_* tier instead.
}

local function fmtVal(v, kind)
    if v == nil then return "?" end
    if kind == "int" then return string.format("%d", math.floor(v + 0.5)) end
    return string.format("%.3f", v)
end

local function run(def, params, out, engine)
    local set = engine.findPlayerAttrSet(def.setName)
    if not set then
        out.line(def.name .. ": no player " .. def.setName .. " (be in-game)")
        return
    end
    local cur = engine.readAttr(set, def.attr)
    local verb = args.lower(params[1])

    if verb == nil then
        out.line(def.name .. " = " .. fmtVal(cur, def.fmt))
        return
    end
    if cur == nil then
        out.line(def.name .. ": could not read the current value")
        return
    end

    local n = tonumber(params[2])
    if verb == "add" or verb == "remove" then
        if not n then
            out.line("usage: " .. def.name .. " " .. verb .. " <number>")
            return
        end
        local target
        if verb == "add" then target = cur + n else target = cur - n end
        if target < 0 then target = 0 end
        if engine.writeAttr(set, def.attr, target, target) then
            out.line(def.name .. ": " .. fmtVal(cur, def.fmt) .. " -> " .. fmtVal(target, def.fmt))
        else
            out.line(def.name .. ": write failed")
        end
    elseif verb == "set" then
        if not def.canSet then
            out.line(def.name .. " has no 'set' (additive only): use '"
                .. def.name .. " add/remove <n>'")
            return
        end
        if not n then
            out.line("usage: " .. def.name .. " set <number>")
            return
        end
        if engine.writeAttr(set, def.attr, n, n) then
            out.line(def.name .. ": " .. fmtVal(cur, def.fmt) .. " -> " .. fmtVal(n, def.fmt))
        else
            out.line(def.name .. ": write failed")
        end
    else
        out.line("usage: " .. def.name .. " [add|remove|set] <number>")
    end
end

function stats.specs()
    local list = {}
    for _, def in ipairs(DEFS) do
        local help
        if def.canSet then
            help = "add/remove/set " .. def.attr
        else
            help = "add/remove " .. def.attr .. " (no set)"
        end
        list[#list + 1] = {
            name = def.name,
            help = help,
            run = function(p, out, engine) run(def, p, out, engine) end,
        }
    end
    return list
end

-- SharedModMenu section: one num slider per settable stat (get reads the live
-- attribute, set writes it absolutely). xp is console-only (no menu row); reads and
-- writes go through the same engine seam the commands use.
function stats.menu(engine)
    local items = {}
    for _, def in ipairs(DEFS) do
        local m = def.menu
        if def.canSet and m then
            items[#items + 1] = {
                name = def.label, kind = "num",
                min = m.min, max = m.max, step = m.step,
                get = function()
                    local set = engine.findPlayerAttrSet(def.setName)
                    if not set then return 0 end
                    return engine.readAttr(set, def.attr) or 0
                end,
                set = function(v)
                    local set = engine.findPlayerAttrSet(def.setName)
                    if set then engine.writeAttr(set, def.attr, v, v) end
                end,
            }
        end
    end
    return { title = "Stats", items = items }
end

return stats
