-- data/locations.lua -- curated quick-travel destinations in WORLD coordinates. Each becomes a
-- one-press button in the SharedModMenu. z is the captured standing height: when present the mod
-- teleports straight to it (reliable), otherwise it ground-traces to find the surface.
--
-- To add your own: set captureCoords = true in config.lua, stand where you want a destination, and
-- press Shift + the hotkey. The log prints a ready-to-paste entry (with z); drop it in and rename.
return {
    { name = "Old Camp",                x = 119636, y = -95498,  z = -5330 },
    { name = "Old Camp (Inner Castle)", x = 111954, y = -102508, z = -3680 },
    { name = "New Camp",                x = 168754, y = -85752,  z = -242  },
    { name = "Swamp Camp",              x = 52178,  y = -115089, z = -8871 },
    { name = "Old Mine",                x = 146198, y = -69089,  z = -3475 },
    { name = "Free Mine",               x = 167731, y = -122412, z = 3595  },
    { name = "Exchange Zone",           x = 103627, y = -58695,  z = 2504  },
}
