-- core/engine.lua  --  the mod's engine ADAPTER. The ONLY mod file that names
-- UE4SS access globals; every call is pcall-wrapped. It re-exports the kit's
-- generic primitives (liveInstances) and adds the cheat-domain reads/writes that
-- the pure modules (registry, args, cheats/*) call through it. They never name a
-- global themselves.
--
-- pcall does NOT catch native access violations. We only ever touch
-- confirmed-safe surfaces (live attribute-set instances filtered to PlayerState,
-- the native GameTimeSubsystem, the engine GameViewport/Console, reflected
-- property writes via ImportText). No TMap iteration, no GetCDO/StaticFindObject
-- on AngelScript class objects (see ../../LuaModdingSurface.md).

local pcall, ipairs, type = pcall, ipairs, type
local tostring, tonumber, string, math = tostring, tonumber, string, math

local kit = require("kit")
local liveInstances = kit.engine.liveInstances

-- UE4SS globals captured at load. These are nil under bare LuaJIT (so this file
-- still LOADS for the tests); they are only ever CALLED inside UE4SS.
local FindObject            = FindObject
local FindObjects           = FindObjects
local FindFirstOf           = FindFirstOf
local StaticFindObject      = StaticFindObject
local StaticConstructObject = StaticConstructObject
local FName                 = FName
local EObjectFlags          = EObjectFlags

local engine = {}
engine.liveInstances = liveInstances

local function fullName(o)
    local n
    local ok = pcall(function() n = o:GetFullName() end)
    return (ok and n) or "<?>"
end
engine.fullName = fullName

function engine.firstLive(className)
    return liveInstances(className)[1]
end

-- ------------------------------------------------------ attribute sets --

-- the player's copy of an attribute set: the live instance whose full name
-- carries "PlayerState" (the proven tries/boost.lua seam).
function engine.findPlayerAttrSet(className)
    for _, s in ipairs(liveInstances(className)) do
        if string.find(fullName(s), "PlayerState", 1, true) then return s end
    end
    return nil
end

-- read an attribute's current value (a GameplayAttributeData with
-- BaseValue/CurrentValue). Returns a number or nil.
function engine.readAttr(set, name)
    local v
    if pcall(function() v = set[name].CurrentValue end) and type(v) == "number" then return v end
    if pcall(function() v = set[name].BaseValue end) and type(v) == "number" then return v end
    return nil
end

-- write BaseValue and/or CurrentValue (skip a nil). Returns true on success.
function engine.writeAttr(set, name, base, current)
    return (pcall(function()
        local a = set[name]
        if base ~= nil then a.BaseValue = base end
        if current ~= nil then a.CurrentValue = current end
    end))
end

-- ------------------------------------------------------ player pawn + movement --
-- The player is a GothicPlayerCharacter; its movement is GothicMovementComponent
-- (derives from UCharacterMovementComponent, so it carries the engine's reflected
-- MovementMode / GravityScale / MaxFlySpeed). EXPERIMENTAL: the custom component
-- may re-assert its own mode each tick, so a one-shot write here may not hold.

local function isValid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end
engine.isValid = isValid

function engine.findPlayerPawn()
    return liveInstances("GothicPlayerCharacter")[1]
end

-- the pawn's CharacterMovement (ACharacter base property), falling back to a
-- named Gothic field if the engine name is not exposed.
function engine.movementComp(pawn)
    if not pawn then return nil end
    local comp
    pcall(function() comp = pawn.CharacterMovement end)
    if isValid(comp) then return comp end
    comp = nil
    pcall(function() comp = pawn.m_GothicMovementComponent end)
    if isValid(comp) then return comp end
    return nil
end

-- the anim instance carrying bCheatFlying, via the movement component's ref.
function engine.animInstance(comp)
    local ai
    pcall(function() ai = comp.m_AnimInstance end)
    if isValid(ai) then return ai end
    return nil
end

-- the character's MAIN anim instance (GothicAnimInstance): the one carrying the
-- input/state flags like bIsCrouching (sneak), isJumping, m_IsAiming. Reached via
-- the skeletal mesh, not the movement component's lower-level anim instance.
function engine.mainAnimInstance(pawn)
    local ai
    pcall(function() ai = pawn.Mesh:GetAnimInstance() end)
    if isValid(ai) then return ai end
    pcall(function() ai = pawn.Mesh.AnimScriptInstance end)
    if isValid(ai) then return ai end
    return nil
end

-- generic reflected property read/write on a live object (not an attribute set).
function engine.getObjProp(obj, name)
    local v
    if pcall(function() v = obj[name] end) then return v end
    return nil
end

function engine.setObjProp(obj, name, value)
    return (pcall(function() obj[name] = value end))
end

-- toggle an actor's collision (SetActorEnableCollision is an engine UFunction).
function engine.setActorCollision(pawn, enabled)
    return (pcall(function() pawn:SetActorEnableCollision(enabled) end))
end

-- launch the character vertically (ACharacter:LaunchCharacter, a clean UFunction
-- with NO FHitResult out-param, unlike the teleport calls). bZOverride sets the
-- Z velocity; bXYOverride false keeps current horizontal motion. In flying mode
-- with gravity 0 this glides you up/down (but drops you into falling mode).
function engine.launchZ(pawn, vz)
    return (pcall(function()
        pawn:LaunchCharacter({ X = 0, Y = 0, Z = vz }, false, true)
    end))
end

-- add a movement-input vector this frame (APawn:AddMovementInput). In flying mode
-- a Z component climbs/descends WITHOUT leaving flying, so horizontal running is
-- preserved. Called every tick while a vertical key is held.
function engine.addMovementInput(pawn, x, y, z, scale)
    return (pcall(function()
        pawn:AddMovementInput({ X = x, Y = y, Z = z }, scale or 1.0, true)
    end))
end

-- the physics volume the pawn is currently in (AActor:GetPhysicsVolume). Flagging
-- its bWaterVolume true is the standard UE lever that makes swimming stick.
function engine.physicsVolume(pawn)
    local vol
    pcall(function() vol = pawn:GetPhysicsVolume() end)
    if isValid(vol) then return vol end
    return nil
end

-- the pawn's controller (for raw key polling).
function engine.playerController(pawn)
    local pc
    pcall(function() pc = pawn.Controller end)
    if isValid(pc) then return pc end
    return nil
end

-- is a physical key currently held? APlayerController:IsInputKeyDown takes an
-- FKey; we build it from the key name. This reads the RAW key regardless of the
-- game's movement state, which is the only way to get input while airborne.
function engine.isInputKeyDown(pc, keyName)
    if not FName then return false end
    local down
    pcall(function() down = pc:IsInputKeyDown({ KeyName = FName(keyName) }) end)
    return down == true
end

-- actor world location, read through the ROOT COMPONENT, not K2_GetActorLocation
-- (the repo's rule, ../../LuaModdingSurface.md: the actor-level call is on the
-- broken path; the component K2_GetComponentLocation is the proven-safe read, as
-- in the kit's readRootPos). Returns x, y, z or nil.
function engine.getActorLocation(pawn)
    local rc
    pcall(function() rc = pawn.RootComponent end)
    if not rc then return nil end
    local x, y, z
    local ok = pcall(function()
        local v = rc:K2_GetComponentLocation()
        x, y, z = v.X, v.Y, v.Z
    end)
    if ok and type(x) == "number" then return x, y, z end
    -- fallback: the RelativeLocation struct field (works when the layout is live)
    x = nil
    ok = pcall(function()
        local v = rc.RelativeLocation
        x, y, z = v.X, v.Y, v.Z
    end)
    if ok and type(x) == "number" then return x, y, z end
    return nil
end

-- teleport an actor by moving its root component world location (sweep off,
-- teleport on). A Lua table passes as the FVector. Tries the component set first,
-- then the actor-level set, returning true on the first that runs.
function engine.setActorLocation(pawn, x, y, z)
    local vec = { X = x, Y = y, Z = z }
    local rc
    pcall(function() rc = pawn.RootComponent end)
    if rc and pcall(function() rc:K2_SetWorldLocation(vec, false, {}, true) end) then
        return true
    end
    if pcall(function() pawn:K2_SetActorLocation(vec, false, {}, true) end) then
        return true
    end
    return false
end

-- nudge an actor's Z by dz. The set call has been the sticking point (the
-- FHitResult out-param), so we try several known UE4SS forms and VERIFY each by
-- reading the position back: only a form that actually moved the pawn returns
-- true. Returns false if none moved it.
function engine.nudgeActorZ(pawn, dz)
    local x0, y0, z0 = engine.getActorLocation(pawn)
    if not z0 then return false end
    local targetZ = z0 + dz
    local rc
    pcall(function() rc = pawn.RootComponent end)

    -- each attempt sets the location to (x0, y0, targetZ) via a different call form
    local attempts = {}
    local function add(obj, getter, setter, hit, teleport)
        attempts[#attempts + 1] = function()
            local v = obj[getter](obj)
            v.X, v.Y, v.Z = x0, y0, targetZ
            if hit then obj[setter](obj, v, false, {}, teleport)
            else obj[setter](obj, v, false, teleport) end
        end
    end
    if rc then
        add(rc, "K2_GetComponentLocation", "K2_SetWorldLocation", true, true)
        add(rc, "K2_GetComponentLocation", "K2_SetWorldLocation", false, true)
    end
    add(pawn, "K2_GetActorLocation", "K2_SetActorLocation", true, true)
    add(pawn, "K2_GetActorLocation", "K2_SetActorLocation", false, true)

    local tol = math.max(1, math.abs(dz) * 0.1)
    for _, fn in ipairs(attempts) do
        pcall(fn)
        local _, _, nz = engine.getActorLocation(pawn)
        if nz and math.abs(nz - targetZ) < tol then return true end
    end
    return false
end

-- ------------------------------------------------------ game clock --
-- The master clock is the native GameTimeSubsystem (verified by SleepProbe:
-- SetCurrentClockTime moves the clock; GetCurrentClockTime reads Hour/Minute).

function engine.findClock()
    return liveInstances("GameTimeSubsystem")[1]
end

function engine.readClock()
    local c = engine.findClock()
    if not c then return nil end
    local h, m
    local ok = pcall(function()
        local ct = c:GetCurrentClockTime()
        h, m = ct.Hour, ct.Minute
    end)
    if ok and type(h) == "number" and type(m) == "number" then
        return { hour = h, minute = m }
    end
    return nil
end

function engine.setClock(h, m, s)
    local c = engine.findClock()
    if not c then return false end
    return (pcall(function() c:SetCurrentClockTime(h, m, s or 0.0) end))
end

-- ------------------------------------ generic reflection poke (set) --
-- Ported from UE4SS's stock ConsoleCommandsMod set.lua: FindObject ->
-- Reflection():GetProperty -> ImportText, writing every instance of a class (or
-- the single named object). The two banned object flags are distinct single-bit
-- flags, so a sum equals their bitwise OR; we use + so the file parses under
-- LuaJIT 5.1 (which has no | operator) as well as in-game.
function engine.setPropByReflection(classOrObjectName, propName, value)
    if not (FindObject and FindObjects and EObjectFlags) then
        return "set: reflection API unavailable"
    end
    local banned = EObjectFlags.RF_ClassDefaultObject + EObjectFlags.RF_ArchetypeObject
    local msg
    local ok = pcall(function()
        local obj = FindObject(nil, classOrObjectName, nil, banned)
        if not obj or not obj:IsValid() then
            msg = "unrecognized class or object '" .. classOrObjectName .. "'"
            return
        end
        if obj:IsClass() then
            local prop = obj:Reflection():GetProperty(propName)
            if not prop:IsValid() then
                msg = "unrecognized property '" .. propName .. "' on " .. classOrObjectName
                return
            end
            local objs = FindObjects(0, obj, nil, nil, banned, false)
            local n = 0
            for _, inst in ipairs(objs) do
                prop:ImportText(value, prop:ContainerPtrToValuePtr(inst), 0, inst)
                n = n + 1
            end
            msg = "set " .. classOrObjectName .. "." .. propName .. " = " .. value
                .. " on " .. n .. " instance(s)"
        else
            local prop = obj:Reflection():GetProperty(propName)
            if not prop:IsValid() then
                msg = "unrecognized property '" .. propName .. "'"
                return
            end
            prop:ImportText(value, prop:ContainerPtrToValuePtr(obj), 0, obj)
            msg = "set " .. classOrObjectName .. "." .. propName .. " = " .. value
        end
    end)
    if not ok then return "set: error" end
    return msg
end

-- ----------------------------------------- dump an object's props (dumpobj) --
function engine.dumpProps(name, emit, out)
    if not FindObject then
        if out then out.line("dumpobj: reflection API unavailable") end
        return
    end
    local obj
    pcall(function() obj = FindObject(nil, name, nil, 0) end)
    local valid = false
    if obj then pcall(function() valid = obj:IsValid() end) end
    if not valid then
        if out then out.line("dumpobj: not found '" .. tostring(name) .. "'") end
        return
    end
    if out then out.line("dumpobj " .. fullName(obj)) end
    local cls
    if not pcall(function() cls = obj:GetClass() end) or not cls then return end
    local count = 0
    local function onProp(prop)
        if count >= 200 then return end
        local pn
        if pcall(function() pn = prop:GetFName():ToString() end) and pn then
            local v
            pcall(function() v = obj[pn] end)
            local t = type(v)
            local s
            if t == "number" or t == "boolean" or t == "string" then
                s = tostring(v)
            elseif t == "nil" then
                s = "nil"
            else
                s = "<" .. t .. ">"
            end
            count = count + 1
            emit(pn .. " = " .. s)
        end
    end
    if not pcall(function() cls:ForEachProperty(onProp) end) then
        pcall(function() obj:ForEachProperty(onProp) end)
    end
end

-- --------------------------------- surface the native ~ console --
-- The stock ConsoleEnablerMod technique, without UEHelpers: find the
-- GameViewport, construct an Engine.Console and attach it, then add Tilde + F10
-- to the InputSettings console keys. Best effort; the UE4SS console window works
-- regardless. Returns (ok, reasonIfFailed).
function engine.surfaceNativeConsole()
    if not (StaticFindObject and StaticConstructObject) then
        return false, "construct API unavailable"
    end
    local err
    local ok = pcall(function()
        local gv
        if FindFirstOf then pcall(function() gv = FindFirstOf("GameViewportClient") end) end
        local gvValid = false
        if gv then pcall(function() gvValid = gv:IsValid() end) end
        if not gvValid and FindFirstOf then
            local eng
            pcall(function() eng = FindFirstOf("GameEngine") end)
            local engValid = false
            if eng then pcall(function() engValid = eng:IsValid() end) end
            if not engValid then pcall(function() eng = FindFirstOf("Engine") end) end
            if eng then pcall(function() gv = eng.GameViewport end) end
        end
        gvValid = false
        if gv then pcall(function() gvValid = gv:IsValid() end) end
        if not gvValid then err = "no GameViewport"; return end

        local haveConsole = false
        pcall(function()
            local existing = gv.ViewportConsole
            haveConsole = existing and existing:IsValid()
        end)
        if not haveConsole then
            local cls = StaticFindObject("/Script/Engine.Console")
            local clsValid = false
            if cls then pcall(function() clsValid = cls:IsValid() end) end
            if not clsValid then err = "no Console class"; return end
            local con = StaticConstructObject(cls, gv)
            local conValid = false
            if con then pcall(function() conValid = con:IsValid() end) end
            if not conValid then err = "construct failed"; return end
            gv.ViewportConsole = con
        end

        if FName then
            local is = StaticFindObject("/Script/Engine.Default__InputSettings")
            local isValid = false
            if is then pcall(function() isValid = is:IsValid() end) end
            if isValid then
                pcall(function()
                    local keys = is.ConsoleKeys
                    local want = { FName("Tilde"), FName("F10") }
                    for _, kn in ipairs(want) do
                        local present = false
                        local n = 0
                        pcall(function() n = #keys end)
                        for i = 1, n do
                            local same = false
                            pcall(function() same = (keys[i].KeyName == kn) end)
                            if same then present = true; break end
                        end
                        if not present then
                            pcall(function() keys[#keys + 1].KeyName = kn end)
                        end
                    end
                end)
            end
        end
    end)
    if not ok then return false, "exception" end
    if err then return false, err end
    return true
end

return engine
