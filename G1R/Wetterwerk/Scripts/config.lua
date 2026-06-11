-- Wetterwerk configuration
-- Apply edits with a game restart, or CTRL+R ingame (UE4SS hot reload).

return {
    -- ---------------------------------------------------------------- hotkeys --
    -- These work WITHOUT the UE4SS GUI overlay, so you can control the weather
    -- with the console GUI off (and so dodge the Frame-Generation present-hook
    -- caveat). UE4SS key names, e.g. "F9", "F10", "K". Set to "" to disable one.
    -- Defaults stay clear of LockpickSettings (F6/F7/F8) so both mods coexist.
    weatherNextHotkey = "F9",  -- cycle to the next weather preset
    weatherPrevHotkey = "",    -- cycle to the previous preset ("" = off)
    holdHotkey        = "F10", -- toggle Hold (pin the weather, stop the game cycle)

    -- ------------------------------------------------------- on-load behavior --
    -- Applied once when you enter the world. presetOnLoad sets a preset by index
    -- (nil does nothing); holdOnLoad engages Hold immediately.
    presetOnLoad = nil,
    holdOnLoad   = false,

    -- ----------------------------------------------------------------- presets --
    -- The live preset count is read from the controller; this is only the
    -- fallback used for the menu grid and hotkey cycling if that read ever fails.
    presetCountFallback = 10,

    -- ------------------------------------------------------------- atmosphere --
    -- Which atmosphere knobs the menu shows, by catalog key (see
    -- data/atmosphere.lua for all keys: cloud, fog, fogbase, rain, snow, thunder,
    -- dust, wind, winddir, wetness).
    atmosphereSliders = { "cloud", "fog", "rain", "wind", "thunder" },

    -- EXPERIMENTAL. Off by default: v1 ships rock-solid preset switching + Hold,
    -- and shows the atmosphere knobs as a READ-ONLY readout. The live weather
    -- LERPS toward the active preset, so raw atmosphere writes fight that lerp and
    -- their persistence is still being verified in-game. Set true to turn the
    -- knobs into live sliders; they take effect only while Hold is engaged (the
    -- override is re-asserted each poll so it wins the lerp). See the README.
    enableAtmosphereWrites = false,

    -- On releasing Hold, ask the game to resume its own weather cycle (Randomize
    -- Weather on). Leave true unless you want the sky to simply stay put.
    resumeCycleOnRelease = true,

    -- --------------------------------------------------------------- internals --
    -- Heartbeat poll, milliseconds. The control refreshes its cached readout and
    -- runs the Hold watchdog at this cadence (one cached controller handle, a few
    -- reflected reads). 400ms is light; raise it if you ever notice a hitch.
    pollMs = 400,

    -- Log control internals (found actors, drift re-asserts, writes) to the UE4SS
    -- log. Alpha default: on, so bug reports arrive with a trace. Set false for
    -- quiet play.
    debug = true,
}
