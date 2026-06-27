-- TautelliniDevProbe configuration.
--
-- DevProbe is OPT-IN. With active = false the mod loads completely inert: it binds NO hotkeys, arms
-- NO hooks, and runs NO probe. Set active = true and restart (or CTRL+R) for a probe session, and
-- active = false when done to keep dev hotkeys out of normal play.
--
-- `probes` is the single source of truth for which probes load and which key fires each action:
--   enabled = arm this probe at all (false = do not load it).
--   keys    = map each of the probe's action ids to a hotkey. "" = that action stays unbound.
--             Format: a UE4SS key name ("F3", "HOME", "END", "PAGE_DOWN", ...), optionally with one
--             modifier prefix ("SHIFT+F10", "CONTROL+F3", "ALT+HOME"; the UE4SS names are SHIFT,
--             CONTROL, ALT, NOT CTRL). The action ids are listed in
--             each probe file's header (the `actions = {{ id, ... }}` it returns).
--
-- Adding a probe: drop probes/<name>.lua, then add a `<name> = { enabled = true, keys = { ... } }`
-- entry here. Removing one: delete its file and its entry. Toggling enabled or adding a new action
-- binds on CTRL+R; CHANGING an existing key needs a full restart (UE4SS keeps old keybinds until
-- the process exits).
return {
    active = false,
    probes = {
        -- camera: read / zoom / fov the camera surface (AngelScript DefaultCamera write-once test)
        camera = {
            enabled = true,
            keys = { read = "F3", zoom = "F10", fov = "SHIFT+F10" },
        },
        -- lockopen: find a one-shot lock-open call. tryOpen/memorize CALL gameplay functions, so
        -- use a throwaway save. read is safe.
        lockopen = {
            enabled = true,
            keys = { read = "HOME", tryOpen = "END", memorize = "PAGE_DOWN" },
        },
        -- map: measure the in-game map so we can build cursor-to-world teleport. read/cursor are
        -- safe; tele MOVES the player, so use a throwaway save.
        map = {
            enabled = true,
            keys = { read = "PAGE_UP", calib = "SHIFT+PAGE_UP", tele = "SHIFT+PAGE_DOWN", clear = "CONTROL+PAGE_UP", hunt = "CONTROL+PAGE_DOWN", testmove = "ALT+PAGE_DOWN", validate = "ALT+PAGE_UP", jump = "ALT+HOME", ptele = "CONTROL+HOME", gread = "SHIFT+END", gtele = "CONTROL+END", gcal = "ALT+END", genum = "SHIFT+HOME", state = "SHIFT+INS" },
        },
        -- npcs: can we read EVERY NPC's world position at map-open (the marker mod)? Both SAFE.
        npcs = {
            enabled = true,
            keys = { scan = "INS", mixins = "DEL" },
        },
        -- economy + readout GRADUATED into FastTravelAnywhere 0.3.0 (ore read via CountItemsOfClass,
        -- the cursor readout). Left here as reference but DISABLED; re-enable only to re-investigate.
        economy = {
            enabled = false,
            keys = { read = "SHIFT+F3", give = "ALT+F3" },
        },
        readout = {
            enabled = false,
            keys = { show = "CONTROL+F10", hide = "ALT+F10" },
        },
    },
}
