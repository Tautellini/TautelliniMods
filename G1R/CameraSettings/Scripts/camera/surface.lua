-- camera/surface.lua -- the camera control catalog: which AngelScript DefaultCamera field
-- backs each menu control, its range, and which section it lives in. PURE: no engine access,
-- no UE4SS globals, loads under bare LuaJIT for tests.
--
-- A control names either `field` (one or more AS scalar fields written to the same value) or
-- `vector` + `component` (one axis of an FVector field, read-modify-written). `key` is the
-- config / saved-settings key. The engine adapter consumes these tables verbatim.

local surface = {}

surface.sections = {
    { title = "Field of View", controls = {
        { key = "fov", name = "FOV", field = { "m_Fov", "m_FOV" },
          min = 50, max = 120, step = 1 },
    } },
    { title = "Distance", controls = {
        { key = "distance", name = "Zoom Distance", field = { "m_ArmLength" },
          min = 80, max = 800, step = 5 },
    } },
    { title = "Position", controls = {
        { key = "shoulder", name = "Shoulder (L/R)", vector = "m_SocketOffset", component = "Y",
          min = -150, max = 150, step = 1 },
        { key = "height", name = "Height (U/D)", vector = "m_SocketOffset", component = "Z",
          min = -150, max = 150, step = 1 },
    } },
    { title = "Smoothing", controls = {
        { key = "lagSpeed", name = "Position Lag", field = { "m_LagSpeed" },
          min = 1, max = 200, step = 1 },
        { key = "rotationLagSpeed", name = "Rotation Lag", field = { "m_RotationLagSpeed" },
          min = 1, max = 200, step = 1 },
        { key = "rotationLagSpeedPitch", name = "Pitch Lag", field = { "m_RotationLagSpeedPitch" },
          min = 1, max = 200, step = 1 },
    } },
}

return surface
