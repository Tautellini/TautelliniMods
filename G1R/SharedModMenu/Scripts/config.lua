-- SharedModMenu configuration. This is the ONLY config this mod owns: the key that
-- opens the shared in-game menu. Every other setting in the menu belongs to the mod
-- that registered it and lives in that mod's own folder, not here.
-- Apply edits with a game restart, or CTRL+R ingame (UE4SS hot reload).

return {
    -- UE4SS key name that toggles the menu. Function keys and numpad are the keys this
    -- UE4SS build delivers reliably (e.g. "F2", "F1", "INSERT").
    menuKey = "F2",
}
