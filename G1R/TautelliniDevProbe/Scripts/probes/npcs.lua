-- probes/npcs.lua  --  can we read EVERY NPC's world position when the map opens?
--
-- This is a Mass-Entity game (significance-driven spawning), so distant NPCs are NOT
-- GothicCharacter actors. But GothicCharacterState persists for ALL characters, and the
-- engine exposes /Script/G1R.GothicCharacterState:GetCharacterLocation (a return-value
-- FVector, the marshaling-safe direction) plus the FCharacterUniqueNameMixins enumerators.
--
-- THE question (two-strike, measure live): does GetCharacterLocation return a real world
-- position for an UNSPAWNED NPC, or only for ones currently spawned near the player? If
-- far-away states report sane coordinates, the map-marker mod is feasible.
--
-- Both actions are SAFE (read-only, no gameplay mutation, no UI change). Open the world map,
-- then press the key.
--
-- ACTIONS (bind in config.probes.npcs.keys):
--   scan   = enumerate GothicCharacterState, call GetCharacterLocation, report spawned vs far.
--   mixins = try the clean FCharacterUniqueNameMixins enumeration API (GetNumTotal, GetAll*).

local ipairs, tostring, type, string, math = ipairs, tostring, type, string, math
local tonumber = tonumber

return function(ctx)
    local log = ctx.makeLog("npcs")
    local isValid, try = ctx.isValid, ctx.try
    local firstLive, fullName, classPath = ctx.firstLive, ctx.fullName, ctx.classPath
    local FindAllOf, SFO = ctx.FindAllOf, ctx.StaticFindObject

    local function vec(v)
        local x = tonumber(try(function() return v.X end))
        local y = tonumber(try(function() return v.Y end))
        local z = tonumber(try(function() return v.Z end))
        if x and y then return x, y, z end
        return nil
    end

    local function playerPos()
        local p = firstLive("GothicPlayerCharacter")
        local rc = isValid(p) and try(function() return p.RootComponent end) or nil
        if not isValid(rc) then return nil end
        return vec(try(function() return rc:K2_GetComponentLocation() end))
    end

    local function dist2D(ax, ay, bx, by)
        return ((ax - bx) ^ 2 + (ay - by) ^ 2) ^ 0.5
    end

    -- a state's location via the engine getter; returns x,y,z or nil
    local function stateLoc(state)
        return vec(try(function() return state:GetCharacterLocation() end))
    end

    -- ------------------------------------------------------------- scan --
    -- The core feasibility test. Counts the populations, then for every GothicCharacterState
    -- tries GetCharacterLocation and classifies it as near (<= SPAWN_NEAR from the player, i.e.
    -- likely a spawned actor) or far (almost certainly an unspawned Mass entity). Lots of valid
    -- FAR positions = we can show the whole world's NPCs.
    local SPAWN_NEAR = 8000      -- cm; rough significance/spawn radius. far beyond this = unspawned
    local SAMPLE = 12            -- how many per-state lines to print

    local function scan()
        log("=== NPC SCAN (open the world map first) ===")
        local px, py = playerPos()
        log("player world: " .. (px and string.format("(%.0f, %.0f)", px, py) or "??"))

        local function count(cls) return #(try(function() return FindAllOf(cls) end) or {}) end
        log(string.format("FindAllOf: GothicCharacter=%d  GothicPlayerCharacter=%d  GothicCharacterState=%d  GothicNPCState=%d",
            count("GothicCharacter"), count("GothicPlayerCharacter"),
            count("GothicCharacterState"), count("GothicNPCState")))

        local states = try(function() return FindAllOf("GothicCharacterState") end) or {}
        local withLoc, near, far, minX, maxX, minY, maxY, shown = 0, 0, 0, nil, nil, nil, nil, 0
        for _, s in ipairs(states) do
            if isValid(s) and not string.find(fullName(s), "Default__", 1, true) then
                local x, y, z = stateLoc(s)
                if x and not (x == 0 and y == 0) then
                    withLoc = withLoc + 1
                    minX = math.min(minX or x, x); maxX = math.max(maxX or x, x)
                    minY = math.min(minY or y, y); maxY = math.max(maxY or y, y)
                    local d = px and dist2D(x, y, px, py) or nil
                    if d and d <= SPAWN_NEAR then near = near + 1 else far = far + 1 end
                    if shown < SAMPLE then
                        shown = shown + 1
                        log(string.format("  [%d] (%.0f, %.0f, %.0f)  %s from player  %s",
                            shown, x, y, z or 0,
                            d and string.format("%.0f", d) or "?", fullName(s)))
                    end
                end
            end
        end
        log(string.format("states with a location: %d  (near<=%d: %d,  FAR: %d)",
            withLoc, SPAWN_NEAR, near, far))
        if minX then
            log(string.format("location spread: X[%.0f .. %.0f]  Y[%.0f .. %.0f]", minX, maxX, minY, maxY))
        end

        -- cross-check: a spawned actor's RootComponent pos vs its CharacterState's GetCharacterLocation
        local chars = try(function() return FindAllOf("GothicCharacter") end) or {}
        local checks = 0
        for _, c in ipairs(chars) do
            if checks >= 3 then break end
            if isValid(c) and not string.find(fullName(c), "Player", 1, true)
                and not string.find(fullName(c), "Default__", 1, true) then
                local rc = try(function() return c.RootComponent end)
                local ax, ay = vec(try(function() return rc:K2_GetComponentLocation() end))
                local st = try(function() return c.m_CharacterState end)
                local sx, sy = isValid(st) and stateLoc(st) or nil
                if ax then
                    checks = checks + 1
                    log(string.format("  cross-check: actor(%.0f,%.0f) vs state(%s)  delta=%s",
                        ax, ay, (sx and string.format("%.0f,%.0f", sx, sy)) or "no state loc",
                        (sx and string.format("%.0f", dist2D(ax, ay, sx, sy))) or "?"))
                end
            end
        end
        log("VERDICT: many FAR states with sane coords = unspawned NPC positions are readable -> mod is feasible.")
        log("=== end scan ===")
    end

    -- ----------------------------------------------------------- mixins --
    -- Try the clean enumeration API. These are module-level (static) UFunctions on the
    -- FCharacterUniqueNameMixins struct; we don't know how UE4SS surfaces a static call here,
    -- so try the native Default object and the two managing subsystems, and report what works.
    -- /Script/G1R is native (not AngelScript), so StaticFindObject on its Default object is safe;
    -- we never call GetCDO (that is the AS hard-crash, not relevant here).
    local function arrLen(v)
        if type(v) ~= "userdata" and type(v) ~= "table" then return nil end
        local n = tonumber(try(function() return #v end))
        if n then return n end
        return tonumber(try(function() return v:GetArrayNum() end))
    end

    local function describe(v)
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then return t .. " " .. tostring(v) end
        if t == "nil" then return "nil" end
        local n = arrLen(v)
        if n then return "array len=" .. n end
        local fn = try(function() return v:GetFullName() end)
        return fn and ("obj " .. fn) or ("<" .. t .. ">")
    end

    local FUNCS = { "GetNumTotal", "GetAllNPCStates", "GetAllCharacterStates",
        "GetAllPlayerStates", "GetAllSpawnedCharacters" }

    local function callOn(label, obj)
        if not isValid(obj) then log("  " .. label .. ": not found"); return end
        log("  " .. label .. " = " .. fullName(obj))
        for _, fname in ipairs(FUNCS) do
            local ok, r = pcall(function() return obj[fname](obj) end)
            log(string.format("    %-22s %s", fname, ok and describe(r) or ("THREW " .. tostring(r))))
        end
    end

    local function mixins()
        log("=== NPC MIXINS (clean enumeration API) ===")
        callOn("Default__FCharacterUniqueNameMixins",
            SFO and try(function() return SFO("/Script/G1R.Default__FCharacterUniqueNameMixins") end) or nil)
        callOn("GothicCharacterStateSubsystem", firstLive("GothicCharacterStateSubsystem"))
        callOn("GothicCharacterSignificanceSubsystem", firstLive("GothicCharacterSignificanceSubsystem"))
        log("=== end mixins ===")
    end

    return {
        name = "npcs",
        actions = {
            { id = "scan",   desc = "SCAN: enumerate CharacterStates + GetCharacterLocation (SAFE)", fn = scan },
            { id = "mixins", desc = "MIXINS: try the FCharacterUniqueNameMixins enumeration API (SAFE)", fn = mixins },
        },
    }
end
