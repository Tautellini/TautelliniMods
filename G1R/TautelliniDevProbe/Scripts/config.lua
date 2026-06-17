-- TautelliniDevProbe configuration.
--
-- DevProbe is OPT-IN. With active = false (the default) the mod loads completely inert: it binds NO
-- hotkeys, arms NO hooks, and runs NO probe. Use it for a dedicated probe session only: set
-- active = true and reload (CTRL+R) or restart, and the probes listed in main.lua's MODULES bind
-- their keys once. When done, set active = false and reload (the bound keys become no-ops) or
-- restart (the bindings are dropped entirely). This keeps dev hotkeys out of normal play.
return {
    active = true,
}
