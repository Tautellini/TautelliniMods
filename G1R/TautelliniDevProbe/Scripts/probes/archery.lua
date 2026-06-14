-- probes/archery.lua  --  read GAS attributes + observe the native archery shot path.
-- F1 = dump GAS attribute sets (Dexterity = archery stat) + the ArcheryComponent and
-- equipped weapon. Native /Script/G1R hooks ([bow] lines) auto-arm and fire on a shot.

local ipairs, tostring, string, os, select = ipairs, tostring, string, os, select

return function(ctx)
    local log      = ctx.makeLog("archery")
    local guard, isValid, try = ctx.guard, ctx.isValid, ctx.try
    local fullName, firstPlayer, resolve, pstr = ctx.fullName, ctx.firstPlayer, ctx.resolve, ctx.pstr

    local function enumProps(obj, label)
        local cls = guard(obj, function(o) return o:GetClass() end)
        if not cls then log("    " .. label .. ": no class"); return end
        local n = 0
        local function emit(prop)
            local pn = try(function() return prop:GetFName():ToString() end)
            if pn then
                n = n + 1
                log(string.format("    %s.%s = %s", label, pn, resolve(try(function() return obj[pn] end))))
            end
        end
        if not try(function() cls:ForEachProperty(emit); return true end) then
            try(function() obj:ForEachProperty(emit); return true end)
        end
        if n == 0 then log("    " .. label .. ": (no enumerable properties)") end
    end

    local function dumpObjectIfNative(o, label)
        if not isValid(o) then log("  " .. label .. ": none / not valid"); return end
        local path = ctx.classPath(o)
        log("  " .. label .. " -> " .. fullName(o) .. "   class=" .. tostring(path))
        if path and string.find(path, "/Script/Angelscript", 1, true) then
            log("    (AngelScript class; not poked here, observe via hooks)")
        else
            enumProps(o, label)
        end
    end

    local ATTRSETS = {
        "AttributeSet_Dexterity", "AttributeSet_Health", "AttributeSet_Armor",
        "AttributeSet_Fatigue", "AttributeSet_LevelProgression", "AttributeSet_Lockpicking",
    }

    local function dumpAttributes()
        log("=== GAS attribute sets (Dexterity governs archery) ===")
        for _, cls in ipairs(ATTRSETS) do
            local o, fn, isPlayer = firstPlayer(cls)
            if o then
                log("CLASS " .. cls .. " -> " .. fn .. (isPlayer and "  [PLAYER]" or "  [sample]"))
                dumpObjectIfNative(o, cls)
            else
                log("CLASS " .. cls .. " -> none live (be in-game, then F1)")
            end
        end
        log("=== end attribute dump ===")
    end

    local function dumpArchery()
        log("=== ArcheryComponent (native /Script/G1R) ===")
        local comp, fn, isPlayer = firstPlayer("ArcheryComponent")
        if not comp then log("no live ArcheryComponent (be in-game; draw a bow)"); log("=== end ==="); return end
        log("comp -> " .. fn .. (isPlayer and "  [PLAYER]" or "  [sample]"))
        enumProps(comp, "ArcheryComponent")
        log("  IsAiming=" .. tostring(guard(comp, function(c) return c:IsAiming() end))
            .. "  CanDoAiming=" .. tostring(guard(comp, function(c) return c:CanDoAiming() end)))
        dumpObjectIfNative(guard(comp, function(c) return c:GetBowOrCrossbowWeapon() end), "equipped bow/crossbow")
        log("=== end archery dump ===")
    end

    -- shot observation (throttled per tag)
    local lastLog = {}
    local function onEvent(tag, ctxObj, ...)
        local now = os.clock()
        if lastLog[tag] and now - lastLog[tag] < 0.5 then return end
        lastLog[tag] = now
        local line = tag
        local cn = guard(ctxObj, function(c) return c:GetClass():GetFullName() end)
        if cn then line = line .. "  on=" .. cn end
        local n = select("#", ...); if n > 6 then n = 6 end
        for i = 1, n do line = line .. "  a" .. i .. "=" .. pstr((select(i, ...))) end
        log(line)
        if string.find(tag, "RELEASE", 1, true) or string.find(tag, "draw", 1, true) then
            local w = guard(ctxObj, function(c) return c:GetBowOrCrossbowWeapon() end)
            if w ~= nil then
                log("    weapon = " .. fullName(w) .. "   class=" .. tostring(ctx.classPath(w)))
            end
        end
    end
    local function H(path, tag) return { path = path, tag = tag, cb = function(self, ...) onEvent(tag, self, ...) end } end

    return {
        name = "archery",
        keys = {
            { key = "F1", desc = "dump GAS attributes + ArcheryComponent + weapon",
              fn = function() dumpAttributes(); dumpArchery() end },
        },
        hooks = {
            H("/Script/G1R.ArcheryComponent:ServerDrawBowString",          "[bow] draw start"),
            H("/Script/G1R.ArcheryComponent:ServerReleaseBowString",       "[bow] RELEASE"),
            H("/Script/G1R.ArcheryComponent:OnReleaseBowStringOrCrossbow", "[bow] release handler"),
            H("/Script/G1R.AbilityTask_Archery_Shoot:TaskArcheryShoot",    "[bow] shoot task"),
        },
    }
end
