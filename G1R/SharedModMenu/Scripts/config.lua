-- SharedModMenu configuration. This is the ONLY config this mod owns: the keys that open and
-- drive the shared in-game menu. Every other setting in the menu belongs to the mod that
-- registered it and lives in that mod's own folder, not here.
--
-- All values are UE4SS key names. Function keys and numpad are the keys this UE4SS build delivers
-- reliably (e.g. "F2", "F1", "INSERT", "NUM_FIVE"). An unknown / empty name falls back to the
-- default shown beside it. Key bindings are applied ONCE at game start: changing a key here needs
-- a full restart (UE4SS cannot rebind a key in place). A CTRL+R hot reload updates everything else.

return {
    -- the key that toggles the menu open/closed
    menuKey = "F2",

    -- in-menu navigation (defaults in the comments)
    keys = {
        itemPrev = "NUM_EIGHT",  -- move the selection up
        itemNext = "NUM_TWO",    -- move the selection down
        valueDec = "NUM_FOUR",   -- decrease the selected num value
        valueInc = "NUM_SIX",    -- increase the selected num value
        activate = "NUM_FIVE",   -- run the selected [ RUN ] action / flip the selected [ ON/OFF ]
        subPrev  = "NUM_SEVEN",  -- previous sub-tab
        subNext  = "NUM_NINE",   -- next sub-tab
        tabPrev  = "NUM_ONE",    -- previous mod tab
        tabNext  = "NUM_THREE",  -- next mod tab
    },
}
