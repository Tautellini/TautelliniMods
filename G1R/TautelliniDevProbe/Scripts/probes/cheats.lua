-- probes/cheats.lua  --  dev-only: discover the player's REAL GAS attribute sets
-- so TautelliniConsole stops guessing class/field names.
--
-- The console's god/heal/mana/oxygen/stats commands write the player's attribute
-- sets through engine.findPlayerAttrSet(<class>). Those class names were guessed by
-- analogy to the one PROVEN name (AttributeSet_Lockpicking); a wrong name resolves
-- to nil and the command does nothing. This probe prints the GROUND TRUTH: every
-- attribute set on the player, its real class name, and each GameplayAttributeData
-- field's base/current value. Feed the log back and the console's DEFS get corrected
-- to confirmed names.
--
-- Two discovery routes, both logged so we cross-check:
--   A (NUM_ONE) known-list scan: for each name the console/archery probes use, is
--     there a live instance under the player? Found = name is real; NOT FOUND = the
--     console's guess is wrong.
--   A also runs route DISCOVER: walk the player AbilitySystemComponent's
--     SpawnedAttributes to surface sets whose names we did NOT guess.
--   B (NUM_TWO) write-readback: fill Health to MaxHealth, read it back immediately
--     and after a short delay, so we learn whether GAS reverts a CurrentValue write
--     (the "does the heal stick" question). Benign on a real save (it only heals).
--
-- READ-ONLY except NUM_TWO (which only heals). No TMap iteration, no AS class pokes;
-- only native /Script GAS sets are enumerated, the seam the repo rule allows.

local ipairs, tostring, string, table, pcall = ipairs, tostring, string, table, pcall

return function(ctx)
    local log = ctx.makeLog("cheats")
    local guard, isValid, try = ctx.guard, ctx.isValid, ctx.try
    local fullName, classPath = ctx.fullName, ctx.classPath
    local firstPlayer, resolve = ctx.firstPlayer, ctx.resolve

    -- every attribute set name the console DEFS + archery probe reference (union).
    -- A name that comes back NOT FOUND is a console guess to drop or rename.
    local KNOWN = {
        "AttributeSet_Health", "AttributeSet_Mana", "AttributeSet_Oxygen",
        "AttributeSet_Fatigue", "AttributeSet_Strength", "AttributeSet_Dexterity",
        "AttributeSet_Armor", "AttributeSet_LevelProgression",
        "AttributeSet_Lockpicking", "AttributeSet_Movement",
    }

    -- candidate player-state / ASC class names to reach SpawnedAttributes through
    local PS_CANDIDATES  = { "GothicPlayerState", "PlayerState" }
    local ASC_CANDIDATES = { "GothicAbilitySystemComponent", "AbilitySystemComponent" }

    -- dump every reflected field of a set; a GameplayAttributeData resolves to
    -- "cur=.. base=..", so the attribute fields stand out from plain scalars.
    local function dumpFields(set, label)
        local cls = guard(set, function(o) return o:GetClass() end)
        if not cls then log("    " .. label .. ": no class"); return end
        local n = 0
        local function emit(prop)
            local pn = try(function() return prop:GetFName():ToString() end)
            if pn then
                n = n + 1
                log(string.format("    .%s = %s", pn, resolve(try(function() return set[pn] end))))
            end
        end
        if not try(function() cls:ForEachProperty(emit); return true end) then
            try(function() set:ForEachProperty(emit); return true end)
        end
        if n == 0 then log("    (no enumerable properties)") end
    end

    -- route A: does the console's guessed name resolve to a live player set?
    local function scanKnown()
        log("=== route A: console/archery known-name scan ===")
        for _, cls in ipairs(KNOWN) do
            local o, fn, isPlayer = firstPlayer(cls)
            if o then
                log("FOUND  " .. cls .. " -> " .. fn .. (isPlayer and "  [PLAYER]" or "  [sample, no PlayerState match]"))
                dumpFields(o, cls)
            else
                log("NOT FOUND  " .. cls .. "  (console guess is wrong or not spawned yet)")
            end
        end
    end

    -- reach the player ASC and walk SpawnedAttributes to discover real set names
    local function findASC()
        for _, c in ipairs(ASC_CANDIDATES) do
            local a = firstPlayer(c)
            if isValid(a) then return a, c end
        end
        for _, c in ipairs(PS_CANDIDATES) do
            local ps = firstPlayer(c)
            if isValid(ps) then
                local a = guard(ps, function(p) return p.AbilitySystemComponent end)
                if not isValid(a) then a = guard(ps, function(p) return p:GetAbilitySystemComponent() end) end
                if isValid(a) then return a, c .. ".AbilitySystemComponent" end
            end
        end
        return nil
    end

    local function discover()
        log("=== route DISCOVER: player ASC SpawnedAttributes ===")
        local asc, via = findASC()
        if not asc then
            log("no player AbilitySystemComponent reached (tried " ..
                table.concat(ASC_CANDIDATES, ", ") .. " and PlayerState.AbilitySystemComponent)")
            return
        end
        log("ASC via " .. tostring(via) .. " -> " .. fullName(asc))
        local sets = guard(asc, function(a) return a.SpawnedAttributes end)
        if not sets then
            log("  SpawnedAttributes not readable (try GetSpawnedAttributes / different field)")
            return
        end
        local count = try(function() return #sets end) or 0
        log("  SpawnedAttributes count = " .. tostring(count))
        for i = 1, count do
            local set = try(function() return sets[i] end)  -- UE4SS TArray is 1-based
            if isValid(set) then
                log("  [" .. i .. "] class=" .. tostring(classPath(set)) .. "  -> " .. fullName(set))
                dumpFields(set, "set" .. i)
            else
                log("  [" .. i .. "] (not valid)")
            end
        end
    end

    local function fullDump()
        log("================ player attribute-set dump ================")
        scanKnown()
        discover()
        log("================ end dump ================")
    end

    -- route B: fill Health, read it back now and after a delay, to learn whether a
    -- CurrentValue write survives the next GAS recompute. Heal-only, so it is safe.
    local ExecuteWithDelay = ctx.ExecuteWithDelay
    local function readHealth()
        local set = firstPlayer("AttributeSet_Health")
        if not isValid(set) then return nil end
        local h = try(function() return set.Health.CurrentValue end)
        local mx = try(function() return set.MaxHealth.CurrentValue end)
        return h, mx, set
    end
    local function healTest()
        log("=== route B: Health write-readback (heal to max) ===")
        local h0, mx, set = readHealth()
        if not set then log("no player AttributeSet_Health (be in-game)"); return end
        log(string.format("before: Health.cur=%s  MaxHealth.cur=%s", tostring(h0), tostring(mx)))
        if mx == nil then log("MaxHealth unreadable; field name may differ, see route A"); return end
        local wrote = pcall(function() set.Health.BaseValue = mx; set.Health.CurrentValue = mx end)
        local h1 = try(function() return set.Health.CurrentValue end)
        log(string.format("wrote=%s  immediate readback: Health.cur=%s", tostring(wrote), tostring(h1)))
        if ExecuteWithDelay then
            ExecuteWithDelay(750, function()
                local h2 = try(function() return set.Health.CurrentValue end)
                log(string.format("after 750ms: Health.cur=%s  (reverted = GAS recomputes; stuck = direct write works)", tostring(h2)))
            end)
        else
            log("ExecuteWithDelay unavailable; re-press NUM_ONE to see if the heal stuck")
        end
    end

    -- god lever hunt: DamageMultiplier=0 does NOT stop incoming damage (play-tested),
    -- so try the native cheat flag CombatConfig.m_GodMode. We only poke a NATIVE
    -- /Script instance, never an AngelScript CombatConfig (the GetCDO/read ban).
    local firstLive = ctx.firstLive
    local function findCombatConfig()
        local o = firstLive("CombatConfig")
        if isValid(o) then return o end
        return nil
    end
    local function setGodFlag(want)
        log("=== god lever: CombatConfig.m_GodMode = " .. tostring(want) .. " ===")
        local cc = findCombatConfig()
        if not isValid(cc) then log("no live CombatConfig (FindAllOf empty); the flag may live elsewhere"); return end
        local path = classPath(cc)
        log("CombatConfig -> " .. fullName(cc) .. "  class=" .. tostring(path))
        if path and string.find(path, "/Script/Angelscript", 1, true) then
            log("AngelScript CombatConfig; NOT poking it (native-only rule). Need the /Script/G1R one.")
            return
        end
        if want then dumpFields(cc, "CombatConfig") end
        local before = try(function() return cc.m_GodMode end)
        local wrote = pcall(function() cc.m_GodMode = want end)
        local after = try(function() return cc.m_GodMode end)
        log(string.format("m_GodMode  before=%s  wrote=%s  after=%s", tostring(before), tostring(wrote), tostring(after)))
        if want then log("now take a hit: NO health loss = m_GodMode is the lever; still bleed = vestigial, use a re-heal tick") end
    end

    -- HUD-refresh hunt: a raw `set.Health.BaseValue = x` write updates the value (the
    -- character window reads it live) but does NOT fire the GAS notify the W_HealthBar
    -- subscribes to, so the bar goes stale. Route the heal through the ASC's own
    -- SetNumericAttributeBase, which broadcasts the change. The open question is whether
    -- an FGameplayAttribute marshals from Lua; we try a couple of forms and log each, so
    -- a failure is a caught Lua error, not a guess baked into the shipping mod.
    local function ascHealFunc()
        log("=== HUD refresh: ASC SetNumericAttributeBase(Health) ===")
        local asc = firstPlayer("GothicAbilitySystemComponent")
        if not isValid(asc) then log("no live ASC (be in-game)"); return end
        local hset = firstPlayer("AttributeSet_Health")
        if not isValid(hset) then log("no Health set"); return end
        local maxv = try(function() return hset.MaxHealth.CurrentValue end)
        if not maxv then log("no MaxHealth"); return end
        local cls = guard(hset, function(o) return o:GetClass() end)
        if not cls then log("no Health set class"); return end
        local prop
        pcall(function() prop = cls:Reflection():GetProperty("Health") end)
        local pv = false; if prop then pcall(function() pv = prop:IsValid() end) end
        log("Health FProperty valid=" .. tostring(pv) .. "  target=" .. tostring(maxv))
        -- first lower the value a touch via a raw write so a successful notify is VISIBLE
        -- as the bar jumping back up (otherwise we'd be setting full to full)
        pcall(function() hset.Health.BaseValue = maxv * 0.5; hset.Health.CurrentValue = maxv * 0.5 end)
        log("pre-set Health to ~half (raw); now firing the notify path")
        if pv then
            local ok1, e1 = pcall(function() asc:SetNumericAttributeBase({ Attribute = prop }, maxv) end)
            log("SetNumericAttributeBase({Attribute=prop}) ok=" .. tostring(ok1) .. (ok1 and "" or ("  err=" .. tostring(e1))))
            if not ok1 then
                local ok2, e2 = pcall(function() asc:SetNumericAttributeBase({ Attribute = prop, AttributeName = "Health", AttributeOwner = cls }, maxv) end)
                log("retry +AttributeName/Owner ok=" .. tostring(ok2) .. (ok2 and "" or ("  err=" .. tostring(e2))))
            end
        else
            log("no FProperty -> cannot build FGameplayAttribute; will need the widget route")
        end
        log(">> WATCH THE HUD BAR: jumped from half back to FULL = this is the fix.")
    end

    return {
        name = "cheats",
        keys = {
            { key = "NUM_ONE",   desc = "dump player attribute sets (real names + fields)", fn = fullDump },
            { key = "NUM_TWO",   desc = "Health write-readback test (heals you)", fn = healTest },
            { key = "NUM_THREE", desc = "god lever: set CombatConfig.m_GodMode = true", fn = function() setGodFlag(true) end },
            { key = "NUM_FOUR",  desc = "god lever: set CombatConfig.m_GodMode = false", fn = function() setGodFlag(false) end },
            { key = "NUM_SIX",   desc = "HUD refresh: heal via ASC SetNumericAttributeBase", fn = ascHealFunc },
        },
    }
end
