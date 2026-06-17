-- core/menu.lua  --  builds the SharedModMenu spec for this mod.
--
-- Each cheat module may expose an optional menu(engine) returning ONE section
-- { title, items } whose bool/num/action items mirror its console commands (the
-- SharedModMenu item spec). This aggregator collects every contributing module's
-- section into the list main.lua's tail hands to kit.menu.register. PURE: no
-- UE4SS globals (engine is injected), so it loads under bare LuaJIT.
--
-- "Will ever expose": a new cheat module gets a menu tab for free by adding a
-- menu(engine) function and appearing in main.lua's module set. Commands that do
-- not map to a bool/num/action control (help, set, dumpobj, the momentary
-- up/down, the flydbg diagnostic) stay console-only by simply not contributing.

local type, pcall, select = type, pcall, select

local menu = {}

-- the loaded cheat modules are passed as varargs (NOT a list): a failed require
-- leaves a nil, and varargs + select("#") skip it, where ipairs over a list would
-- truncate at the first nil and silently drop every later sub-tab. Any module with
-- a .menu function contributes one section; a module whose menu(engine) errors is
-- skipped so one bad section can never drop the whole tab.
function menu.build(engine, ...)
    local mods, n = { ... }, select("#", ...)
    local sections = {}
    for i = 1, n do
        local m = mods[i]
        if type(m) == "table" and type(m.menu) == "function" then
            local ok, sec = pcall(m.menu, engine)
            if ok and type(sec) == "table" then
                sections[#sections + 1] = sec
            end
        end
    end
    return sections
end

return menu
