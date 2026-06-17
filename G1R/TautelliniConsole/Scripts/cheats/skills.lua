-- cheats/skills.lua  --  addskill, removeskill.
--
-- A skill is a GE_Skill_* GameplayEffect. addskill grants it through the game's
-- character mixins (LearnSkillForFree, then fallbacks); removeskill strips every
-- active instance of the effect from the ability system. Names accept the short
-- form (Acrobatics) or full (GE_Skill_Acrobatics). PURE of UE4SS globals: engine
-- is injected. See ../../docs/cheat-techniques.md.

local skills = {}

local function doAdd(params, out, engine)
    local name = params[1]
    if not name then out.line("usage: addskill <Skill>   e.g. addskill Acrobatics"); return end
    local ok, info = engine.grantSkill(name)
    out.line("addskill: " .. (ok and info or ("FAILED " .. tostring(info))))
end

local function doRemove(params, out, engine)
    local name = params[1]
    if not name then out.line("usage: removeskill <Skill>"); return end
    local ok, info = engine.removeSkill(name)
    out.line("removeskill: " .. (ok and info or ("FAILED " .. tostring(info))))
end

function skills.specs()
    return {
        { name = "addskill",
          help = "learn a skill for free: addskill <Skill> (e.g. Acrobatics)",
          run = function(p, out, engine) doAdd(p, out, engine) end },
        { name = "removeskill",
          help = "remove a learned skill: removeskill <Skill>",
          run = function(p, out, engine) doRemove(p, out, engine) end },
    }
end

return skills
