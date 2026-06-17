-- cheats/items.lua  --  additem, removeitem.
--
-- Item ids are the game's `It*` class names (e.g. ItMi_Gold, ItMw_1H_Sword_01),
-- resolved by engine.resolveClass. additem uses the inventory component's
-- AddItemOfClass; removeitem uses the character-state mixins. PURE of UE4SS
-- globals: engine is injected. See ../../docs/cheat-techniques.md.

local require, tonumber = require, tonumber
local args = require("util.args")

local items = {}

local function doAddItem(params, out, engine)
    local id = params[1]
    if not id then out.line("usage: additem <ItemId> [count]   e.g. additem ItMi_Gold 500"); return end
    local count = tonumber(params[2]) or 1
    local ok, info = engine.addItem(id, count)
    out.line("additem: " .. (ok and info or ("FAILED " .. tostring(info))))
end

local function doRemoveItem(params, out, engine)
    local id = params[1]
    if not id then out.line("usage: removeitem <ItemId> [count]   (no count removes all of it)"); return end
    local count = tonumber(params[2]) -- nil = remove all
    local ok, info = engine.removeItem(id, count)
    out.line("removeitem: " .. (ok and info or ("FAILED " .. tostring(info))))
end

-- console-only (no menu): item ids do not fit a menu control.
function items.specs()
    return {
        { name = "additem",
          help = "give an item: additem <ItemId> [count]",
          run = function(p, out, engine) doAddItem(p, out, engine) end },
        { name = "removeitem",
          help = "remove an item: removeitem <ItemId> [count] (no count = all)",
          run = function(p, out, engine) doRemoveItem(p, out, engine) end },
    }
end

return items
