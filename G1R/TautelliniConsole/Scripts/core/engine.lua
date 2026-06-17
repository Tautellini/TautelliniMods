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

local pcall, ipairs, pairs, type = pcall, ipairs, pairs, type
local tostring, tonumber, string, math = tostring, tonumber, string, math

local kit = require("kit")
local liveInstances = kit.engine.liveInstances

-- UE4SS globals captured at load. These are nil under bare LuaJIT (so this file
-- still LOADS for the tests); they are only ever CALLED inside UE4SS.
local FindObject            = FindObject
local FindObjects           = FindObjects
local FindFirstOf           = FindFirstOf
local FindAllOf             = FindAllOf
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

-- ------------------------------------------------------ native safety --
-- isValid() reads the object-table slot, never derefs, so it is the cheap
-- revalidation the cached resolvers below poll with. The pcall turns a nil or a
-- non-UObject into false instead of an error. (Defined up here so the cached
-- attribute-set + clock resolvers can use it.)
local function isValid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end
engine.isValid = isValid

-- ------------------------------------------------------ attribute sets --

-- the player's copy of an attribute set: the live instance whose full name
-- carries "PlayerState" (the proven tries/boost.lua seam). The resolved set is
-- CACHED per class and revalidated with isValid(), so once it is found the
-- SharedModMenu's 250 ms value poll reuses it instead of re-running FindAllOf
-- every tick in-game (the documented hitch source); a save reload or level change
-- invalidates the handle and we resolve once more. A miss (at the main menu,
-- before a player exists) re-scans, which is cheap while those classes are empty.
local attrCache = {}
function engine.findPlayerAttrSet(className)
    local hit = attrCache[className]
    -- A cached handle can pass isValid() (its object-table slot still reads alive)
    -- yet point at a torn-down or replaced set after a save-load / respawn / level
    -- change, deref'ing to nil (the bug that left god healing nothing). Re-confirm
    -- the cached set STILL names a PlayerState before trusting it; clearCaches() on
    -- ClientRestart is the primary invalidation, this is the per-call backstop.
    if hit and isValid(hit) and string.find(fullName(hit), "PlayerState", 1, true) then
        return hit
    end
    attrCache[className] = nil
    for _, s in ipairs(liveInstances(className)) do
        if string.find(fullName(s), "PlayerState", 1, true) then
            attrCache[className] = s
            return s
        end
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

-- ============================================================ game functions ==
-- The reliable way to change G1R state is to call the GAME'S OWN UFUNCTIONs with
-- SIMPLE args only (object/class/number/bool/FName/string) -- never a GAS/engine
-- struct handle, which does not marshal from Lua. Those functions run the real
-- logic AND fire the notifications the HUD subscribes to, unlike a raw attribute
-- write. See ../../docs/cheat-techniques.md.

local SCRIPT_PACKAGES = {
    "/Script/Angelscript.", "/Script/AngelscriptCode.",
    "/Script/G1R.", "/Script/Engine.",
}

-- the class-default-object of a static library/mixin class, probing each script
-- package. Calling a UFUNCTION on this CDO is calling that function library.
local libCache = {}
function engine.libraryObject(className)
    local hit = libCache[className]
    if hit and isValid(hit) then return hit end
    libCache[className] = nil
    if not StaticFindObject then return nil end
    for _, pkg in ipairs(SCRIPT_PACKAGES) do
        local cdo
        pcall(function() cdo = StaticFindObject(pkg .. "Default__" .. className) end)
        if isValid(cdo) then libCache[className] = cdo; return cdo end
    end
    return nil
end

-- player pawn + character-state (PlayerState / m_CharacterState), which carries the
-- inventory and ability system. Returns pawn, state (either may be nil).
function engine.findPlayerPawnState()
    local pawn = liveInstances("GothicPlayerCharacter")[1]
    if not pawn then return nil end
    local state
    pcall(function() state = pawn.PlayerState end)
    if not isValid(state) then state = nil; pcall(function() state = pawn.m_CharacterState end) end
    return pawn, (isValid(state) and state or nil)
end

-- heal the player to full via the character Heal mixin (the PROPER GAS path, so the
-- HUD bar repaints). A huge amount caps at MaxHealth. Returns true on a call.
function engine.healFull(pawn)
    pawn = pawn or engine.findPlayerPawnState()
    if not isValid(pawn) then return false end
    local lib = engine.libraryObject("Module_GAS_GASCharacterMixinsStatics")
    if not lib then return false end
    return (pcall(function() lib:Heal(pawn, 1000000.0, pawn) end))
end

-- every CombatConfig the game reads cheat flags from: live instances + the CDO.
-- The CDO is always present (a bare FindAllOf is empty when none is live).
local function combatConfigs()
    local out = {}
    if FindAllOf then
        local ok, all = pcall(FindAllOf, "CombatConfig")
        if ok and all then
            for _, c in ipairs(all) do if isValid(c) then out[#out + 1] = c end end
        end
    end
    if StaticFindObject then
        local cdo
        pcall(function() cdo = StaticFindObject("/Script/G1R.Default__CombatConfig") end)
        if isValid(cdo) then out[#out + 1] = cdo end
    end
    return out
end

-- set a bool cheat flag (m_GodMode, m_ParryCheatMode) on every CombatConfig.
-- Returns true if at least one write ran.
function engine.setCombatFlag(field, value)
    local any = false
    for _, c in ipairs(combatConfigs()) do
        if pcall(function() c[field] = value end) then any = true end
    end
    return any
end

-- set a mixin-backed stat to an ABSOLUTE value through the state mixins: read the
-- current with getName, apply (value - current) with incName. These fire the proper
-- notifications. getName/incName are the G1R mixin UFUNCTION names (e.g.
-- GetStrengthAttribute / IncreaseStrengthAttributeBy). Returns ok, info.
function engine.setStatViaMixin(getName, incName, value)
    local pawn, state = engine.findPlayerPawnState()
    if not (pawn and state) then return false, "no player state (be in-game)" end
    local lib = engine.libraryObject("Module_GAS_GASCharacterStateMixinsStatics")
    if not lib then return false, "state-mixin library not found" end
    local cur = 0
    pcall(function() cur = lib[getName](lib, state, 0.0, pawn) end)
    cur = tonumber(cur) or 0
    local ok = pcall(function() lib[incName](lib, state, value - cur, pawn) end)
    return ok, ok and (cur .. " -> " .. value) or "mixin call failed"
end

-- resolve any game class by short name, probing the script packages (cached;
-- misses remembered). Direct paths, _C, Default__, item It* and GE_* ids are also
-- tried as-is.
local classByName = {}
local function isDirectName(name)
    return name:find("/", 1, true) ~= nil
        or name:sub(-2) == "_C"
        or name:find("Default__", 1, true) ~= nil
        or name:sub(1, 2) == "It"
        or name:sub(1, 3) == "GE_"
end
function engine.resolveClass(name)
    if not name or name == "" then return nil end
    local hit = classByName[name]
    if hit ~= nil then return hit or nil end
    local found
    if StaticFindObject then
        for _, pkg in ipairs(SCRIPT_PACKAGES) do
            local c; pcall(function() c = StaticFindObject(pkg .. name) end)
            if isValid(c) then found = c; break end
        end
        if not found and isDirectName(name) then
            local c; pcall(function() c = StaticFindObject(name) end)
            if isValid(c) then found = c end
        end
    end
    classByName[name] = found or false
    return found or nil
end

-- ---- world + GameplayStatics (actor sweeps, time dilation, weather) ----
function engine.getWorld()
    local pawn = liveInstances("GothicPlayerCharacter")[1]
    local w
    if pawn then pcall(function() w = pawn:GetWorld() end) end
    if isValid(w) then return w end
    w = nil
    if FindFirstOf then pcall(function() w = FindFirstOf("World") end) end
    return isValid(w) and w or nil
end

local gpStatics
function engine.gameplayStatics()
    if gpStatics and isValid(gpStatics) then return gpStatics end
    gpStatics = nil
    if StaticFindObject then pcall(function() gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end) end
    return isValid(gpStatics) and gpStatics or nil
end

-- inheritance-aware actor list (unlike FindAllOf, which is exact-class). Unwraps
-- the RemoteUnrealParam each entry may arrive as. className resolves via resolveClass.
function engine.getAllActorsOfClass(className)
    local world, gs = engine.getWorld(), engine.gameplayStatics()
    local cls = engine.resolveClass(className)
    if not (world and gs and cls) then return {} end
    local raw = {}
    pcall(function() gs:GetAllActorsOfClass(world, cls, raw) end)
    local out = {}
    for _, r in ipairs(raw) do
        local a = r
        local okg, got = pcall(function() return r:get() end)
        if okg and got ~= nil then a = got end
        if isValid(a) then out[#out + 1] = a end
    end
    return out
end

-- the player's AbilitySystemComponent (for effect-based ops like removeskill).
function engine.findASC()
    local pawn, state = engine.findPlayerPawnState()
    if isValid(state) then
        local asc; pcall(function() asc = state.AbilitySystemComponent end)
        if isValid(asc) then return asc end
    end
    for _, owner in ipairs({ pawn, state }) do
        if isValid(owner) then
            local asc; pcall(function() asc = owner:GetAbilitySystemComponent() end)
            if isValid(asc) then return asc end
        end
    end
    return nil
end

-- ---- inventory / items ----
function engine.findInventory(pawn, state)
    if isValid(state) then
        local direct; pcall(function() direct = state.InventoryComponent end)
        if isValid(direct) then return direct end
    end
    local cls = engine.resolveClass("InventoryComponent")
    for _, owner in ipairs({ state, pawn }) do
        if isValid(owner) and cls then
            local c; pcall(function() c = owner:GetComponentByClass(cls) end)
            if isValid(c) then return c end
        end
    end
    return nil
end

function engine.addItem(itemId, count)
    local pawn, state = engine.findPlayerPawnState()
    local inv = engine.findInventory(pawn, state)
    if not inv then return false, "inventory not found (be in-game)" end
    local cls = engine.resolveClass(itemId)
    if not cls then return false, "unknown item '" .. tostring(itemId) .. "'" end
    local ok = pcall(function() inv:AddItemOfClass(cls, count or 1) end)
    return ok, ok and (itemId .. " x" .. (count or 1)) or "add failed"
end

function engine.removeItem(itemId, count)
    local pawn, state = engine.findPlayerPawnState()
    if not isValid(state) then return false, "no player state (be in-game)" end
    local cls = engine.resolveClass(itemId)
    if not cls then return false, "unknown item '" .. tostring(itemId) .. "'" end
    local lib = engine.libraryObject("Module_GAS_GASCharacterStateMixinsStatics")
    if not lib then return false, "state-mixin library not found" end
    local ok
    if count then ok = pcall(function() lib:RemoveItemFromInventory(state, cls, count, pawn) end)
    else          ok = pcall(function() lib:RemoveAllItemsFromInventory(state, cls, pawn) end) end
    return ok, ok and (itemId .. (count and (" x" .. count) or " (all)")) or "remove failed"
end

-- ---- skills (GE_Skill_* gameplay effects) ----
function engine.resolveSkill(name)
    for _, prefix in ipairs({ "", "GE_Skill_", "GE_" }) do
        for _, suffix in ipairs({ "", "_C" }) do
            local cls = engine.resolveClass(prefix .. name .. suffix)
            if cls then return cls, prefix .. name .. suffix end
        end
    end
    return nil
end

function engine.grantSkill(name)
    local pawn, state = engine.findPlayerPawnState()
    if not (pawn and state) then return false, "no player state (be in-game)" end
    local cls, full = engine.resolveSkill(name)
    if not cls then return false, "unknown skill '" .. tostring(name) .. "'" end
    local stateLib = engine.libraryObject("Module_GAS_GASCharacterStateMixinsStatics")
    local charLib  = engine.libraryObject("Module_GAS_GASCharacterMixinsStatics")
    local plans = {
        function() if stateLib then return stateLib:LearnSkillForFree(state, cls, pawn) end end,
        function() if stateLib then return stateLib:LearnSkill(state, cls, false, pawn) end end,
        function() if charLib then charLib:GiveSkill(pawn, cls, pawn); return true end end,
    }
    for _, p in ipairs(plans) do
        local ok, ret = pcall(p)
        if ok and ret ~= nil and ret ~= false then return true, full end
    end
    return false, "all skill grants failed for " .. full
end

function engine.removeSkill(name)
    local asc = engine.findASC()
    if not asc then return false, "no ability system component" end
    local cls, full = engine.resolveSkill(name)
    if not cls then return false, "unknown skill '" .. tostring(name) .. "'" end
    local ok, removed = pcall(function() return asc:RemoveActiveGameplayEffectBySourceEffect(cls, nil, -1) end)
    return ok, ok and (full .. " (removed " .. tostring(removed) .. ")") or "remove failed"
end

-- additive stat nudge via the state mixins (fires the proper notifications).
function engine.incStatViaMixin(incName, delta)
    local pawn, state = engine.findPlayerPawnState()
    if not (pawn and state) then return false end
    local lib = engine.libraryObject("Module_GAS_GASCharacterStateMixinsStatics")
    if not lib then return false end
    return (pcall(function() lib[incName](lib, state, delta, pawn) end))
end

-- ---- clock extras: skip + freeze (the same GameTimeSubsystem as setClock) ----
function engine.skipTime(seconds)
    local c = engine.findClock()
    if not c then return false end
    return (pcall(function() c:SkipTime({ TotalSeconds = seconds }) end))
end

function engine.freezeTime(want)
    local c = engine.findClock()
    if not c then return false end
    if want then return (pcall(function() c:FreezeTime() end)) end
    return (pcall(function() c:UnfreezeTime() end))
end

-- global game speed (1 = normal). A plain float arg, so it marshals.
function engine.setTimeDilation(value)
    local world, gs = engine.getWorld(), engine.gameplayStatics()
    if not (world and gs) then return false end
    return (pcall(function() gs:SetGlobalTimeDilation(world, value) end))
end

-- ---- weather (Ultra Dynamic Sky controller; EWeather is a uint8 enum) ----
local WEATHER_ACTOR_CLASSES = {
    "/Script/G1R.GothicUltraDynamicController", "/Script/G1R.GothicUltraDynamicWeather",
}
function engine.weatherController()
    for _, path in ipairs(WEATHER_ACTOR_CLASSES) do
        local actors = engine.getAllActorsOfClass(path)
        if actors[1] then return actors[1] end
    end
    return nil
end
function engine.setWeather(id)
    local ctrl = engine.weatherController()
    if not ctrl then return false end
    if pcall(function() ctrl:SetCurrentWeatherImmediate(id) end) then return true end
    return (pcall(function() ctrl:SetCurrentWeather(id) end))
end

-- ------------------------------------------------------ player pawn + movement --
-- The player is a GothicPlayerCharacter; its movement is GothicMovementComponent
-- (derives from UCharacterMovementComponent, so it carries the engine's reflected
-- MovementMode / GravityScale / MaxFlySpeed). EXPERIMENTAL: the custom component
-- may re-assert its own mode each tick, so a one-shot write here may not hold.

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

-- ============================================================ flight + speed ==
-- The Gothic movement component is authoritative (re-applies its own mode/gravity
-- each frame), so flight OVERRIDES it: every frame zero gravity + Falling mode, then
-- AddActorWorldOffset toward a tracked position movement.lua advances along the
-- camera look. movement.lua holds the state + math; these are the engine seams. The
-- per-frame work is driven by main.lua's ONE LoopAsync, never a second loop.

-- the Gothic movement component (has SetCheatFlying/MaxFlySpeed); falls back to the
-- generic movement component.
function engine.flyComp(pawn)
    local mc
    pcall(function() mc = pawn:GetGothicMovementComponent() end)
    if isValid(mc) then return mc end
    return engine.movementComp(pawn)
end

-- the locomotion data module: carries the WASD input intent and movement state.
function engine.locoModule(pawn)
    local m
    pcall(function() m = pawn.m_DataModule_Locomotion end)
    if isValid(m) then return m end
    m = nil
    pcall(function()
        local comp = pawn.m_DataModuleComponent
        if isValid(comp) then m = comp:GetLocomotionDataModule(pawn) end
    end)
    return isValid(m) and m or nil
end

-- WASD intent: world-space input dir (x, y) + its 0..1 magnitude.
function engine.flyInput(loco)
    local x, y, amt = 0.0, 0.0, 0.0
    if loco then
        pcall(function() local v = loco.m_LastMovementInput; x, y = v.X, v.Y end)
        pcall(function() amt = loco.m_MovementInputAmount end)
    end
    return x or 0.0, y or 0.0, tonumber(amt) or 0.0
end

-- camera look in degrees (yaw, pitch) from the controller's ControlRotation.
function engine.controlRotation(pawn)
    local pc = engine.playerController(pawn)
    if not pc then return nil end
    local yaw, pitch
    pcall(function() local r = pc.ControlRotation; yaw, pitch = r.Yaw, r.Pitch end)
    if type(yaw) == "number" then return yaw, pitch end
    return nil
end

-- per-frame upkeep so the authoritative comp stops floor-snapping/smoothing us.
function engine.flyUpkeep(mc, loco)
    if mc then
        pcall(function() mc.GravityScale = 0.0 end)
        pcall(function() mc.NetworkSmoothingMode = 0 end)
        pcall(function() mc:StopMovementImmediately() end)
        pcall(function() mc:SetMovementMode(3, 0) end) -- Falling: no floor-snap
    end
    if loco then pcall(function() loco.m_MovementState = 3 end) end
end

-- relative world move via the AngelScript actor library (non-swept; true pass-through).
local flyActorLib
function engine.addActorWorldOffset(pawn, dx, dy, dz)
    if not (flyActorLib and isValid(flyActorLib)) then
        flyActorLib = engine.libraryObject("AngelscriptActorLibrary")
    end
    if not flyActorLib then return false end
    return (pcall(function() flyActorLib:AddActorWorldOffset(pawn, { X = dx, Y = dy, Z = dz }) end))
end

-- enter the flight pose; returns savedGravity, savedSmoothing for restore on exit.
function engine.flyEnable(pawn, speed)
    local mc = engine.flyComp(pawn)
    local sg, ss
    if mc then
        pcall(function() mc:SetCheatFlying(true) end)
        pcall(function() mc.MaxFlySpeed = speed end)
        pcall(function() sg = mc.GravityScale end)
        pcall(function() mc.GravityScale = 0.0 end)
        pcall(function() ss = mc.NetworkSmoothingMode end)
        pcall(function() mc.NetworkSmoothingMode = 0 end)
    end
    pcall(function() pawn:SetActorEnableCollision(false) end)
    return sg, ss
end

function engine.flyDisable(pawn, savedGravity, savedSmoothing)
    pcall(function() pawn:SetActorEnableCollision(true) end)
    local mc = engine.flyComp(pawn)
    if mc then
        pcall(function() mc:SetCheatFlying(false) end)
        if savedGravity ~= nil then pcall(function() mc.GravityScale = savedGravity end) end
        if savedSmoothing ~= nil then pcall(function() mc.NetworkSmoothingMode = savedSmoothing end) end
    end
    local loco = engine.locoModule(pawn)
    if loco then pcall(function() loco.m_MovementState = 1 end) end -- Grounded
end

-- run speed: the Movement attribute set's SpeedModifier multiplier (1.0 = normal).
function engine.setRunSpeed(mult)
    local set = engine.findPlayerAttrSet("AttributeSet_Movement")
    if not set then return false end
    return engine.writeAttr(set, "SpeedModifier", mult, mult)
end
function engine.getRunSpeed()
    local set = engine.findPlayerAttrSet("AttributeSet_Movement")
    if not set then return 1 end
    return engine.readAttr(set, "SpeedModifier") or 1
end

-- ------------------------------------------------------ game clock --
-- The master clock is the native GameTimeSubsystem (verified by SleepProbe:
-- SetCurrentClockTime moves the clock; GetCurrentClockTime reads Hour/Minute).

-- CACHED + revalidated, same reason as findPlayerAttrSet: the menu's clock poll
-- must not FindAllOf every tick. The subsystem lives for the session; isValid()
-- catches a swap on level change.
local clockObj = nil
function engine.findClock()
    if clockObj and isValid(clockObj) then return clockObj end
    clockObj = liveInstances("GameTimeSubsystem")[1]
    return clockObj
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

-- drop every cached live handle so the next access re-resolves. Call this when the
-- player/world changes (ClientRestart): a save-load, respawn or level change tears
-- down the old PlayerState attribute sets and the clock subsystem, and a stale
-- handle can still pass isValid() while deref'ing to nil.
function engine.clearCaches()
    for k in pairs(attrCache) do attrCache[k] = nil end
    clockObj = nil
end

-- reload-persistent scratch: module locals are wiped by a CTRL+R (package.loaded is
-- nilled), so state that must outlive a hot reload (god's stashed real MaxHealth)
-- lives here in a namespaced _G table the reload reset never touches.
local PERSIST = "__TautelliniConsole_persist"
function engine.persist(key, value)
    local t = _G[PERSIST]; if not t then t = {}; _G[PERSIST] = t end
    t[key] = value
end
function engine.persisted(key)
    local t = _G[PERSIST]; return t and t[key] or nil
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
