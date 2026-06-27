-- probes/economy.lua  --  read the player's ore (currency) count for FastTravelAnywhere's Immersive
-- Mode. SOLVED 2026-06-26: state.InventoryComponent:CountItemsOfClass(oreClass) returns the ore
-- total (measured 269, matched the HUD), where oreClass = ItMi_Orenugget (German "Erzbrocken"; an
-- AngelScript class, resolves at /Script/Angelscript.ItMi_Orenugget). It is symmetric to the proven
-- AddItemOfClass, and counts are keyed by ItemDefinition internally but the UClass call bridges it.
--
-- HARD LESSON (this probe crashed the game once): do NOT batter-test unknown UFunction names live.
-- pcall does NOT catch a native access violation, and calling a guessed UFunction with a class arg
-- AV'd the game right after CountItemsOfClass succeeded. So this probe now calls ONLY the one proven
-- accessor, with an ABOUT-TO log so any future crash still points at the exact call.
--
-- ACTIONS (bind in config.probes.economy.keys):
--   read = SAFE. Resolve ItMi_Orenugget, find the inventory, call CountItemsOfClass once.
--   give = DANGER (mutates inventory; throwaway save). Add 100 ore via AddItemOfClass to confirm the
--          read moves with it.

local ipairs, tostring, type, string, table, tonumber, pcall =
      ipairs, tostring, type, string, table, tonumber, pcall

return function(ctx)
    local log = ctx.makeLog("economy")
    local isValid, try = ctx.isValid, ctx.try
    local firstLive, fullName = ctx.firstLive, ctx.fullName
    local SFO = ctx.StaticFindObject

    local SCRIPT_PACKAGES = { "/Script/Angelscript.", "/Script/AngelscriptCode.", "/Script/G1R.", "/Script/Engine." }
    -- ItMi_Orenugget is the ore item (proven); the rest are backups in case a build renames it.
    local CURRENCY_CANDIDATES = { "ItMi_Orenugget", "ItMiNugget", "ItMi_OreNugget" }

    local function lib(p) return SFO and try(function() return SFO(p) end) or nil end

    local function resolveOne(form)
        for _, pkg in ipairs(SCRIPT_PACKAGES) do
            local c = lib(pkg .. form)
            if isValid(c) then return c, pkg .. form end
        end
        local c = lib(form)
        if isValid(c) then return c, form end
        return nil
    end
    local function resolveClass(name)
        local c, full = resolveOne(name)
        if c then return c, full end
        return resolveOne(name .. "_C")
    end
    -- the first ore class that resolves, as (class, name, fullpath)
    local function resolveCurrency()
        for _, c in ipairs(CURRENCY_CANDIDATES) do
            local cls, full = resolveClass(c)
            if isValid(cls) then return cls, c, full end
        end
        return nil
    end

    local function playerPawnState()
        local pawn = firstLive("GothicPlayerCharacter")
        if not isValid(pawn) then return nil end
        local state = try(function() return pawn.PlayerState end)
        if not isValid(state) then state = try(function() return pawn.m_CharacterState end) end
        return pawn, (isValid(state) and state or nil)
    end

    local function findInventory(pawn, state)
        local direct = isValid(state) and try(function() return state.InventoryComponent end) or nil
        if isValid(direct) then return direct, "state.InventoryComponent" end
        local cls = (resolveClass("InventoryComponent"))
        for _, owner in ipairs({ state, pawn }) do
            if isValid(owner) and cls then
                local c = try(function() return owner:GetComponentByClass(cls) end)
                if isValid(c) then return c, "GetComponentByClass" end
            end
        end
        return nil
    end

    -- inv:CountItemsOfClass(oreClass) -> int. The ONLY native call here. Returns a number or nil.
    local function oreCount(inv, oreCls, oreName)
        if not (isValid(inv) and isValid(oreCls)) then return nil end
        log("  ABOUT TO call inv:CountItemsOfClass(" .. tostring(oreName) .. ")")
        local v
        local ok = pcall(function() v = inv:CountItemsOfClass(oreCls) end)
        if ok then return tonumber(v) end
        log("  CountItemsOfClass threw: " .. tostring(v))
        return nil
    end

    local function readEconomy()
        log("=== ECONOMY READ (compare the count to your on-screen ore / Erzbrocken) ===")
        local oreCls, oreName, full = resolveCurrency()
        if not oreCls then
            log("  NO ore class resolved (tried " .. table.concat(CURRENCY_CANDIDATES, ", ") .. ")")
            log("=== end ==="); return
        end
        log("  ore class: " .. oreName .. " -> " .. tostring(full))
        local pawn, state = playerPawnState()
        if not isValid(pawn) then log("  no player pawn (be in-game on a save)"); log("=== end ==="); return end
        local inv, how = findInventory(pawn, state)
        log("  inventory = " .. (inv and (fullName(inv) .. " via " .. how) or "NOT FOUND"))
        local count = oreCount(inv, oreCls, oreName)
        if count then
            log("  ORE COUNT = " .. tostring(count) .. "  (this is the affordability gate's read)")
        else
            log("  ore count unavailable (CountItemsOfClass returned no number)")
        end
        log("=== end read ===")
    end

    local function giveCurrency()
        local pawn, state = playerPawnState()
        if not (isValid(pawn) and isValid(state)) then log("give: no player state (be in-game)"); return end
        local inv = (findInventory(pawn, state))
        if not isValid(inv) then log("give: no inventory component"); return end
        local oreCls, oreName = resolveCurrency()
        if not isValid(oreCls) then log("give: no ore class resolved"); return end
        local ok = pcall(function() inv:AddItemOfClass(oreCls, 100) end)
        log("give: AddItemOfClass(" .. oreName .. ", 100) " .. (ok and "ran (re-run read; expect +100)" or "FAILED"))
    end

    return {
        name = "economy",
        actions = {
            { id = "read", desc = "READ ore count via CountItemsOfClass(ItMi_Orenugget) (SAFE, one call)", fn = readEconomy },
            { id = "give", desc = "DANGER: add 100 ore to confirm the read moves (throwaway save)", fn = giveCurrency },
        },
    }
end
