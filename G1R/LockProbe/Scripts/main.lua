-- LockProbe v22: dev-only exploration mod, NOT for shipping.
-- Post-object-dump probe. Established facts (see LuaModdingSurface.md
-- and the 62MB UE4SS_ObjectDump): GothicLockSceneActor is an AInfo
-- (NO transform, RootComponent legitimately nullptr, scene-center
-- anchoring is dead); FVector/FRotator are LWC double structs and
-- their Lua reads fail on this UE4SS build; FLinearColor (float4)
-- reads always work; m_Plate/m_Bar/m_Latch are GothicLockPieceActor
-- refs (StaticMeshActors WITH transforms) sharing m_PieceId, typed by
-- m_LockPieceType. A game-specific MemberVariableLayout.ini (5.04
-- template) may now be active and could revive double-struct reads.
-- v22 answers:
--   1. did the layout config revive K2_GetActorLocation on the piece
--      part actors (plate/bar/latch, via FindAllOf = healthy wrappers)?
--   2. camera GetCameraLocation / GetCameraRotation as controls
--   3. the MPC's COMPLETE parameter name lists via
--      GetVectorParameterNames/GetScalarParameterNames (TArray<FName>)
--   4. slots per settle, plus part locations per settle when readable
--      (bar offset vs rotation dataset from one solved lock)
-- Usage: FULLY RESTART the game (the layout config loads at boot;
-- check the log header for "Found configuration for game"), open a
-- lock, move pieces, open it, send the log.

local ipairs, pairs, tostring, tonumber, pcall, print, string, math =
    ipairs, pairs, tostring, tonumber, pcall, print, string, math

local function log(msg)
    print("[LockProbe] " .. tostring(msg) .. "\n")
end

local function firstLine(e)
    local sx = tostring(e)
    sx = string.match(sx, "[^\r\n]+") or sx
    return (string.gsub(sx, ".*Scripts\\main%.lua:%d+: ", ""))
end

local function actorLoc(a)
    if not a then return "nil" end
    local ok, x, y, z = pcall(function()
        local v = a:K2_GetActorLocation()
        return v.X, v.Y, v.Z
    end)
    if ok and tonumber(x) and tonumber(y) and tonumber(z) then
        return string.format("%.2f,%.2f,%.2f", x, y, z)
    end
    return "ERR:" .. (ok and "non-numeric" or firstLine(x))
end

local function liveInstances(className)
    local out = {}
    local ok, found = pcall(FindAllOf, className)
    if ok and found then
        for _, obj in ipairs(found) do
            if obj:IsValid() and not string.find(obj:GetFullName(), "Default__", 1, true) then
                out[#out + 1] = obj
            end
        end
    end
    return out
end

local function findScene()
    for _, sub in ipairs(liveInstances("LockPickSubsystem")) do
        local scene
        pcall(function()
            local sc = sub.m_LockSceneActor
            if sc and sc:IsValid() then scene = sc end
        end)
        if scene then return scene end
    end
    return nil
end

-- parts grouped by piece id: { [id] = { Plate = actor, Bar = actor, ... } }
local function pieceParts()
    local parts = {}
    for _, a in ipairs(liveInstances("GothicLockPieceActor")) do
        local id, ty
        pcall(function() id = a.m_PieceId end)
        pcall(function() ty = tostring(a.m_LockPieceType) end)
        if id ~= nil then
            parts[id] = parts[id] or {}
            parts[id][ty or "?"] = a
        end
    end
    return parts
end

local function dumpParts(tag)
    local parts = pieceParts()
    local ids = {}
    for id in pairs(parts) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local line = {}
        for ty, a in pairs(parts[id]) do
            line[#line + 1] = string.format("%s=%s", ty, actorLoc(a))
        end
        table.sort(line)
        log(string.format("%s piece[%d] %s", tag, id, table.concat(line, " ")))
    end
end

local function dumpSlots(tag, n)
    local lib, mpc
    pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary") end)
    pcall(function() mpc = StaticFindObject("/Game/Blueprints/LockPick/MPC_Lockpicking.MPC_Lockpicking") end)
    local scene = findScene()
    if not (lib and mpc and scene) then
        log(tag .. " slots unavailable")
        return
    end
    for i = 0, n - 1 do
        pcall(function()
            local c = lib:GetVectorParameterValue(scene, mpc, FName("Slot_" .. i))
            log(string.format("%s slot[%d]=%.2f,%.2f,%.2f", tag, i, c.R, c.G, c.B))
        end)
    end
end

local function dumpOnce()
    -- 2. camera controls
    local pc = FindFirstOf("PlayerController")
    if pc then
        local okM, mgr = pcall(function() return pc.PlayerCameraManager end)
        if okM and mgr then
            local okL, x, y, z = pcall(function()
                local v = mgr:GetCameraLocation()
                return v.X, v.Y, v.Z
            end)
            log("camMgr GetCameraLocation: " .. (okL and tonumber(x)
                and string.format("%.2f,%.2f,%.2f", x, y, z)
                or ("ERR:" .. firstLine(x))))
            local okR, p, yw, r = pcall(function()
                local v = mgr:GetCameraRotation()
                return v.Pitch, v.Yaw, v.Roll
            end)
            log("camMgr GetCameraRotation: " .. (okR and tonumber(p)
                and string.format("%.2f,%.2f,%.2f", p, yw, r)
                or ("ERR:" .. firstLine(p))))
        end
    end
    -- 3. MPC parameter name enumeration (TArray<FName> out-params)
    local mpc
    pcall(function() mpc = StaticFindObject("/Game/Blueprints/LockPick/MPC_Lockpicking.MPC_Lockpicking") end)
    if mpc then
        for _, fn in ipairs({ "GetVectorParameterNames", "GetScalarParameterNames" }) do
            local ok, err = pcall(function()
                local names = {}
                mpc[fn](mpc, names)
                local out = {}
                for i = 1, #names do
                    local nm = names[i]
                    out[#out + 1] = (type(nm) == "userdata" and nm.ToString)
                        and nm:ToString() or tostring(nm)
                end
                log("MPC " .. fn .. ": [" .. table.concat(out, ", ") .. "]")
            end)
            if not ok then log("MPC " .. fn .. " ERR: " .. firstLine(err)) end
        end
    else
        log("MPC object not found")
    end
    -- 1. scene control (expected: no transform, it is an AInfo)
    local sceneF = liveInstances("GothicLockSceneActor")[1]
    if sceneF then
        log("scene(FindAllOf) loc (AInfo, expect fail/zero): "
            .. actorLoc(sceneF))
    end
end

local Probing = false

-- save-load backstop, same rule as the shipped mod: a GC purge while
-- the poll loop touches object wrappers is a native AV pcall cannot
-- catch (CONFIRMED in-game 2026-06-07: FindAllOf during a save load
-- crashed the process from this very probe). Stop everything the
-- moment the world changes.
local Generation = 0
pcall(RegisterInitGameStatePostHook, function()
    Generation = Generation + 1
    Probing = false
end)

pcall(NotifyOnNewObject, "/Script/G1R.AbilityTask_LockPick", function()
    if Probing then return end
    Probing = true
    local gen = Generation
    ExecuteWithDelay(1500, function()
        ExecuteInGameThread(function()
            if gen ~= Generation then return end
            pcall(dumpOnce)
            pcall(dumpParts, "START")
            pcall(dumpSlots, "START", 7)
            log("start dump complete")
        end)
    end)
    local lastSig, wasMoving, ticks = nil, false, 0
    LoopAsync(400, function()
        local done = false
        ExecuteInGameThread(function()
            if gen ~= Generation then
                done = true
                return
            end
            local ok = pcall(function()
                local scene = findScene()
                if not scene then
                    done = true
                    return
                end
                ticks = ticks + 1
                if ticks > 450 then
                    done = true
                    return
                end
                local lib, mpc
                pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary") end)
                pcall(function() mpc = StaticFindObject("/Game/Blueprints/LockPick/MPC_Lockpicking.MPC_Lockpicking") end)
                if not (lib and mpc) then return end
                local sig = ""
                for i = 0, 6 do
                    pcall(function()
                        local c = lib:GetVectorParameterValue(scene, mpc, FName("Slot_" .. i))
                        sig = sig .. string.format("%.1f,%.1f;", c.R, c.G)
                    end)
                end
                if lastSig and sig ~= lastSig then
                    wasMoving = true
                elseif wasMoving then
                    wasMoving = false
                    pcall(dumpParts, "MOVE")
                    pcall(dumpSlots, "MOVE", 7)
                end
                lastSig = sig
            end)
            if not ok then done = true end
        end)
        if done then
            Probing = false
            log("probe session ended")
            return true
        end
        return false
    end)
end)
log("v22 loaded: layout-fix + bar-dataset probe. RESTART the game "
    .. "fully, open a lock, move pieces, open it, send the log.")
