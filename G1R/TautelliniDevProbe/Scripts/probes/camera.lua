-- probes/camera.lua  --  read the camera surface, and test WRITE-ONCE on the AngelScript
-- config (the clean path: no per-tick reapply).
--
-- Findings (2026-06-18):
--   * The manager re-asserts the native SpringArm / PlayerCameraManager every frame from
--     its config, so direct native writes revert.
--   * The config is the AngelScript object /Script/Angelscript.Default__DefaultCamera, and
--     its reflected fields READ by name (proven): m_Fov/m_FOV=75, m_ArmLength=215 (zoom,
--     matches the live boom), m_SocketOffset=(0,70,-4), m_LagSpeed=50,
--     m_RotationLagSpeed=100, m_RotationLagSpeedPitch=30, m_LagMaxDistance=50.
--   * So writing DefaultCamera.m_ArmLength / m_Fov ONCE should make the manager apply our
--     value every frame, no tick-fighting. This pass tests that the WRITE works and sticks.
--
-- Repo canon: StaticFindObject("Default__X") + reflected field read/WRITE by name is the
-- safe AS path (GetCDO crashes, ForEachProperty is AS-blind, AS instance props are unsafe).
-- The write target here is exactly ONE object (the config), validated, single field per
-- toggle, pcall-wrapped. No class sweeps.
--
-- ACTIONS (bind a key to each in config.probes.camera.keys):
--   read = READ native surface + DISCOVER/READ DefaultCamera AS fields
--   zoom = DefaultCamera.m_ArmLength 450 <-> original (write once; sticks?)
--   fov  = DefaultCamera.m_Fov + m_FOV 100 <-> original (write once; sticks?)

local ipairs, tostring, type, table, string =
      ipairs, tostring, type, table, string

return function(ctx)
    local log = ctx.makeLog("camera")
    local isValid, try = ctx.isValid, ctx.try
    local fullName, classPath, firstLive = ctx.fullName, ctx.classPath, ctx.firstLive

    local function isAS(obj)
        local p = classPath(obj)
        return p and string.find(p, "/Script/Angelscript", 1, true) and true or false
    end
    local function tag(obj) return isAS(obj) and "AngelScript" or "native" end

    local function fmt(v)
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
        if t == "nil" then return "nil" end
        if t == "userdata" then
            local vec = try(function()
                return string.format("vec(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
            end)
            if vec then return vec end
            local fn = try(function() return v:GetFullName() end)
            if fn then return "obj " .. fn end
        end
        return "<" .. t .. ">"
    end
    local function readField(obj, name)
        return fmt(try(function() return obj[name] end))
    end

    -- the AngelScript camera config (one global Default object; the canonical safe path)
    local function defaultCamera()
        local cfg = ctx.StaticFindObject
            and try(function() return ctx.StaticFindObject("/Script/Angelscript.Default__DefaultCamera") end)
            or nil
        return isValid(cfg) and cfg or nil
    end

    -- ----------------------------------------------------------------- read --
    local AS_FIELDS = { "m_Fov", "m_FOV", "m_ArmLength", "m_SocketOffset", "m_LagSpeed",
        "m_RotationLagSpeed", "m_RotationLagSpeedPitch", "m_LagMaxDistance" }
    local SURFACES = {
        { class = "GothicCameraSpringArmComponent",
          fields = { "TargetArmLength", "SocketOffset", "CameraLagSpeed",
                     "CameraRotationLagSpeed" } },
        { class = "PlayerCameraManager", fields = { "DefaultFOV" } },
    }
    local function readSurface(s)
        local o = firstLive(s.class)
        if not o then log(string.format("%-30s : no live instance", s.class)); return end
        log(string.format("%-30s : %s  [%s]", s.class, fullName(o), tag(o)))
        for _, f in ipairs(s.fields) do log(string.format("    %s = %s", f, readField(o, f))) end
    end

    local function readAll()
        log("=== CAMERA READ (be in-game) ===")
        for _, s in ipairs(SURFACES) do readSurface(s) end
        local pcm = firstLive("PlayerCameraManager")
        if pcm then log("    GetFOVAngle() = " .. tostring(try(function() return pcm:GetFOVAngle() end))) end
        local cfg = defaultCamera()
        if cfg then
            log("DefaultCamera (AngelScript config):")
            for _, f in ipairs(AS_FIELDS) do log(string.format("    %s = %s", f, readField(cfg, f))) end
        else
            log("DefaultCamera config not found")
        end
        log("=== end read. ===")
    end

    -- --------------------------------------------------- write-once AS toggle --
    -- Set one or more config fields to a test value (write ONCE), restore on re-press.
    -- The manager should pick the value up and apply it every frame with no tick from us.
    local function makeToggle(label, fields, testValue)
        local saved = nil
        return function()
            local cfg = defaultCamera()
            if not cfg then log(label .. ": no DefaultCamera config (be in-game)"); return end
            if saved == nil then
                saved = {}
                for _, f in ipairs(fields) do saved[f] = try(function() return cfg[f] end) end
                local ok = true
                for _, f in ipairs(fields) do
                    if not try(function() cfg[f] = testValue; return true end) then ok = false end
                end
                log(string.format("%s %s: %s = %s (was %s). Watch the camera -- does it change and "
                    .. "STAY with no tick from us? %s again to restore.",
                    label, ok and "APPLIED" or "WRITE FAILED", table.concat(fields, "/"),
                    tostring(testValue), tostring(saved[fields[1]]), label))
            else
                for _, f in ipairs(fields) do
                    if saved[f] ~= nil then try(function() cfg[f] = saved[f] end) end
                end
                log(label .. " RESTORED")
                saved = nil
            end
        end
    end

    local toggleZoom = makeToggle("ZOOM", { "m_ArmLength" }, 450.0)
    local toggleFov  = makeToggle("FOV", { "m_Fov", "m_FOV" }, 100.0)

    -- hotkeys come from config.probes.camera.keys (by action id); none are hardcoded here
    return {
        name = "camera",
        actions = {
            { id = "read", desc = "READ native surface + DefaultCamera AS config", fn = readAll },
            { id = "zoom", desc = "ZOOM: DefaultCamera.m_ArmLength 450 <-> original", fn = toggleZoom },
            { id = "fov",  desc = "FOV: DefaultCamera.m_Fov 100 <-> original", fn = toggleFov },
        },
    }
end
