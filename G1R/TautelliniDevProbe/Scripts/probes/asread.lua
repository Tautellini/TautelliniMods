-- probes/asread.lua  --  AngelScript-layer read experiments (DEV-ONLY, can crash).
-- Settled boundary (2026-06-13): GetCDO() on an ASClass = hard crash (never call it);
-- StaticFindObject("/Script/Angelscript.Default__X") + read fields BY NAME works and
-- returns real values; ForEachProperty enumeration is blind to AS data fields. These
-- keys exercise that. Forensic "ABOUT TO" logging pinpoints any crash. THROWAWAY save.
--   F12 = sweep: read AS DATA fields BY NAME (the working route) + read a live AS
--         instance's properties + enumerate candidate AS CDOs (returns 0, blind).

local ipairs, tostring, string, pcall = ipairs, tostring, string, pcall

return function(ctx)
    local log = ctx.makeLog("asread")
    local isValid, try, fullName, resolve = ctx.isValid, ctx.try, ctx.fullName, ctx.resolve
    local StaticFindObject, FindAllOf = ctx.StaticFindObject, ctx.FindAllOf

    -- forensic: collect names (safe metadata) then read each VALUE with an ABOUT-TO line.
    local function readAllProps(obj, label)
        local cls = ctx.guard(obj, function(o) return o:GetClass() end)
        if not cls then log("  " .. label .. ": no class"); return end
        local names = {}
        local function collect(prop)
            local pn = try(function() return prop:GetFName():ToString() end)
            if pn then names[#names + 1] = pn end
        end
        if not try(function() cls:ForEachProperty(collect); return true end) then
            try(function() obj:ForEachProperty(collect); return true end)
        end
        log("  " .. label .. ": " .. #names .. " enumerable props")
        for _, pn in ipairs(names) do
            log("    ABOUT TO read " .. label .. "." .. pn)
            log("    " .. label .. "." .. pn .. " = " .. resolve(try(function() return obj[pn] end)))
        end
    end

    -- F11 (byname): known AS data fields read BY NAME (the validated capability)
    local NAMED = {
        { "AttackMeleeConfig_Pyrolaser",         { "m_RotationVelocity", "m_MaxRollOffset" } },
        { "BreakFloorDefinition_FireGolem_Cone", { "m_ConeHalfAngleDegrees", "m_ConeLengthMeters", "m_ConeLengthSpeed" } },
        { "BreathOfDeathSpellConfig",            { "m_Duration", "m_EmitterHeight", "m_EmitterWidth" } },
    }
    local function testNamedRead()
        log("########## byname (F11): read AS DATA fields BY NAME (no enumerate, no GetCDO) ##########")
        for _, e in ipairs(NAMED) do
            local name, fields = e[1], e[2]
            local path = "/Script/Angelscript.Default__" .. name
            log("[byname] ABOUT TO: StaticFindObject('" .. path .. "')")
            local cdo; local ok = pcall(function() cdo = StaticFindObject(path) end)
            if not ok or not isValid(cdo) then
                log("[byname] " .. name .. ": no CDO (skip)")
            else
                log("[byname] " .. name .. ": CDO ok, reading fields by name")
                for _, f in ipairs(fields) do
                    log("    ABOUT TO read " .. name .. "." .. f)
                    log("    " .. name .. "." .. f .. " = " .. resolve(try(function() return cdo[f] end)))
                end
            end
        end
        log("[byname] DONE: by-name read sweep SURVIVED.")
    end

    -- Shift+F11: live AS instance property read
    local function testInstanceProps()
        local AS = "Bow_Human_Untrained"
        log("########## instance (Shift+F11): live AS instance property read ##########")
        log("[inst] ABOUT TO: FindAllOf('" .. AS .. "')")
        local list; local ok = pcall(function() list = FindAllOf(AS) end)
        local inst
        if ok and list then for _, o in ipairs(list) do if isValid(o) then inst = o; break end end end
        if not inst then log("[inst] no live " .. AS .. " instance (equip a bow / be in a fight)"); return end
        log("[inst] instance = " .. fullName(inst) .. " -> reading props")
        readAllProps(inst, AS .. ".instance")
        log("[inst] DONE.")
    end

    -- F12: enumerate candidate AS CDOs (demonstrates enumeration is blind: ~0 fields)
    local CANDIDATES = { "Bow_Human_Untrained", "Bow", "GA_ArcheryBow", "GE_Ex_Damage" }
    local function testEnumerate()
        log("########## enumerate (F12): AS Default__ CDOs (expect 0 fields) ##########")
        for _, name in ipairs(CANDIDATES) do
            local path = "/Script/Angelscript.Default__" .. name
            log("[enum] ABOUT TO: StaticFindObject('" .. path .. "')")
            local cdo; local ok = pcall(function() cdo = StaticFindObject(path) end)
            if not ok or not isValid(cdo) then
                log("[enum] " .. name .. ": no CDO (skip)")
            else
                log("[enum] " .. name .. ": CDO ok -> enumerating")
                readAllProps(cdo, name)
            end
        end
        log("[enum] DONE: enumerate sweep SURVIVED.")
    end

    return {
        name = "asread",
        keys = {
            { key = "F12", desc = "AS read sweep: by-name + instance + enumerate",
              fn = function() testNamedRead(); testInstanceProps(); testEnumerate() end },
        },
        hooks = {},
    }
end
