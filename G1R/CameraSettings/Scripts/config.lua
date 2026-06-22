-- CameraSettings config. Edit then restart (or CTRL+R) the game.
-- Menu changes are saved to saved_settings.lua and override these on next launch; delete
-- that file to reset to the values here. The game's true vanilla camera values are captured
-- once to vanilla_snapshot.lua on first load and used by the master toggle / per-section reset.
--
-- The defaults below MATCH the game's vanilla camera, so a fresh install changes nothing
-- until you tune a value. All numbers are written to the AngelScript camera config, which the
-- camera manager applies every frame.

return {
    -- Master: ON applies the values below, OFF restores the vanilla camera live (A/B compare).
    overridesEnabled = true,

    -- Field of view. Vanilla 75. Higher = wider.
    fov = 75,

    -- Third-person distance (camera arm length). Vanilla 215. Higher = further out.
    distance = 215,

    -- Camera position offset from the player. Vanilla shoulder 70, height -4.
    shoulder = 70,  -- left/right
    height   = -4,  -- up/down

    -- Smoothing (higher = snappier follow). Vanilla 50 / 100 / 30.
    lagSpeed              = 50,
    rotationLagSpeed      = 100,
    rotationLagSpeedPitch = 30,
}
