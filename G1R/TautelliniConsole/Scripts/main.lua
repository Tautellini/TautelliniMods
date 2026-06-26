-- TautelliniConsole for Gothic 1 Remake  --  thin orchestrator
--
-- A console cheat layer built entirely in UE4SS Lua. It self-adds the vendored
-- shared kit, requires the mod modules, builds a command registry, and owns ALL
-- registration: a RegisterConsoleCommandHandler per command, plus the
-- ConsoleEnabler hook that surfaces the native ~ console. The work lives in the
-- kit (engine primitives, log) and the mod's modules: core/ (engine adapter,
-- registry, output), util/args, and the feature folder cheats/. See the spec in
-- plans/tautellini-console.md.
--
-- Commands type into either the native ~ console (Tilde / F10, surfaced below) or
-- the UE4SS console window. v1 is the proven core: god, heal, mana, oxygen,
-- nofatigue, str/dex/level/skillpoints/xp, speed, lockskill, time, plus the
-- generic set/dumpobj/help. All over the reflected surface in
-- ../../LuaModdingSurface.md; nothing depends on the game's stripped Marvin/cheat
-- exec functions.

-- UE4SS mods share one Lua state: another mod overwriting a standard global
-- (seen in the wild: ipairs replaced by a table) must not break us. Capture as
-- locals at load time.
local ipairs, pairs, tostring = ipairs, pairs, tostring
local type, pcall, print, require = type, pcall, print, require
local rawget, debug, string = rawget, debug, string

local ModVersion = "0.3.2-alpha"

-- ---------------------------------------------------- vendored shared kit --
-- This mod ships its OWN copy of the kit under <Mod>/shared/kit/ (deploy.ps1
-- vendors it from the one repo source), so each build is self-contained. That
-- folder is not on UE4SS's default search path, so add it from this file's own
-- location (the BPModLoaderMod pattern).
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")
local ModDir = here and here:match("^(.*)[/\\][^/\\]*$") or nil
if ModDir then
    package.path = ModDir .. "/shared/?/?.lua;"
        .. ModDir .. "/shared/?.lua;" .. package.path
end

-- --------------------------------------------------------- hot reload reset --
-- CTRL+R re-runs this chunk. nil EVERY module (the kit AND the mod's, by their
-- exact require names) in package.loaded, and FULL-SWEEP ue4ss_loaded_modules
-- (keyed by absolute path, so a bare-name nil there is a silent no-op). Do it
-- BEFORE the first require so edits to any file take effect.
local MODULES = {
    "kit", "config",
    "core.engine", "core.registry", "core.output", "core.menu", "util.args",
    "cheats.resources", "cheats.stats", "cheats.items", "cheats.skills",
    "cheats.lockpicking", "cheats.movement", "cheats.time", "cheats.world",
    "cheats.generic",
}
for _, m in ipairs(MODULES) do package.loaded[m] = nil end
do
    local reg = rawget(_G, "ue4ss_loaded_modules")
    if type(reg) == "table" then
        for k in pairs(reg) do reg[k] = nil end
    end
end

-- the shared kit is the foundation: without it the mod cannot run
local okKit, kit = pcall(require, "kit")
if not okKit or type(kit) ~= "table" then
    print("[TautelliniConsole] FATAL: shared kit not found (" .. tostring(kit)
        .. "). Re-deploy; the kit vendors under <Mod>/shared/.\n")
    return
end
local log = kit.log.make("[TautelliniConsole]")

-- ----------------------------------------------------------------- modules --
local function tryRequire(name) return kit.boot.tryRequire(name, log) end

local Config    = tryRequire("config") or { commandPrefix = "", verbose = true }
local engine    = tryRequire("core.engine")
local registry  = tryRequire("core.registry")
local output    = tryRequire("core.output")
local resources = tryRequire("cheats.resources")
local stats     = tryRequire("cheats.stats")
local itemsCmd  = tryRequire("cheats.items")
local skillsCmd = tryRequire("cheats.skills")
local lockpickCmd = tryRequire("cheats.lockpicking")
local movement  = tryRequire("cheats.movement")
local timeCmd   = tryRequire("cheats.time")
local worldCmd  = tryRequire("cheats.world")
local generic   = tryRequire("cheats.generic")
local menuSpec  = tryRequire("core.menu")

if not (engine and registry and output) then
    log("FATAL: core modules failed to load; aborting")
    return
end

-- ------------------------------------------------------------- build registry --
local prefix = Config.commandPrefix or ""
local reg = registry.new(prefix)
if resources then reg:addAll(resources.specs()) end
if stats     then reg:addAll(stats.specs())     end
if itemsCmd  then reg:addAll(itemsCmd.specs())  end
if skillsCmd then reg:addAll(skillsCmd.specs()) end
if lockpickCmd then reg:addAll(lockpickCmd.specs()) end
if movement  then reg:addAll(movement.specs())  end
if timeCmd   then reg:addAll(timeCmd.specs())   end
if worldCmd  then reg:addAll(worldCmd.specs())  end
if generic   then reg:addAll(generic.specs(reg)) end -- generic.help reads reg

-- =============================== registration (tail) ======================= --
local RegisterConsoleCommandHandler = rawget(_G, "RegisterConsoleCommandHandler")
local ExecuteInGameThread           = rawget(_G, "ExecuteInGameThread")
local RegisterHook                  = rawget(_G, "RegisterHook")
-- game-thread timers (gameLoop): #1180-safe, with an internal LoopAsync fallback
local Async                         = kit.async

-- Dispatch indirection: the registered console handlers are thin and STABLE
-- (registered once per process), and look up the CURRENT command closure here.
-- We rebuild this table on every (re)load, so a hot reload refreshes command
-- behavior WITHOUT re-registering handlers (which could stack duplicates).
local DISPATCH_KEY = "__TautelliniConsole_dispatch"
local dispatch = {}
_G[DISPATCH_KEY] = dispatch

local function runSpec(spec, params, ar)
    -- Run INLINE, never across an async boundary. The console output device `ar`
    -- is valid only for the duration of this synchronous handler call; deferring
    -- the work (ExecuteInGameThread) and then calling ar:Log() dereferences a
    -- freed FOutputDevice, a native access violation pcall cannot catch (it
    -- crashed the game on the first `help`). UE console exec already runs on the
    -- game thread, so inline engine access is safe, exactly as UE4SS's own stock
    -- ConsoleCommandsMod set.lua does it.
    local out = output.make(ar, log)
    local ok, err = pcall(spec.run, params, out, engine)
    if not ok then out.line(spec.name .. ": error (" .. tostring(err) .. ")") end
end

for _, spec in ipairs(reg:all()) do
    local full = reg:fullName(spec)
    dispatch[full] = function(params, ar) runSpec(spec, params, ar) end
end

-- register each unique full name ONCE per process (a prefix change adds the new
-- names; the old ones stay registered but their dispatch entry is gone, so they
-- return false and fall through).
_G.__TautelliniConsole_registered = _G.__TautelliniConsole_registered or {}
local registered = _G.__TautelliniConsole_registered

if RegisterConsoleCommandHandler then
    local nNew = 0
    for _, spec in ipairs(reg:all()) do
        local full = reg:fullName(spec)
        if not registered[full] then
            registered[full] = true
            local ok = pcall(RegisterConsoleCommandHandler, full,
                function(_full, params, ar)
                    local d = _G[DISPATCH_KEY]
                    local fn = d and d[full]
                    if fn then fn(params, ar); return true end
                    return false
                end)
            if ok then nNew = nNew + 1 end
        end
    end
    log("registered " .. nNew .. " new command(s); " .. #reg:all()
        .. " active (prefix '" .. prefix .. "')")
else
    log("RegisterConsoleCommandHandler unavailable: no commands registered "
        .. "(is this UE4SS?)")
end

-- surface the native ~ console (best effort; the UE4SS console window always
-- works as a fallback).
local function trySurfaceConsole(reason)
    local ok, why = engine.surfaceNativeConsole()
    if ok then
        log("native ~ console available (Tilde / F10) [" .. reason .. "]")
    else
        log("native console not surfaced (" .. tostring(why) .. ") [" .. reason
            .. "]; use the UE4SS console window")
    end
end
-- restore the pawn if a hot reload happened mid-flight (collision/flying left on),
-- then surface the console -- both on the game thread.
local function onLoad()
    if movement then pcall(movement.recover, engine) end
    trySurfaceConsole("load")
end
if ExecuteInGameThread then
    ExecuteInGameThread(onLoad)
else
    onLoad()
end

-- re-surface after a level/world load, and drop the engine's cached live handles:
-- a save-load / respawn / level change replaces the player attribute sets and the
-- clock, and a stale cached handle can pass isValid() yet deref to nil (this is what
-- silently broke god/heal/stats until a CTRL+R). ClientRestart runs on the game thread.
if RegisterHook and not _G.__TautelliniConsole_consoleHook then
    _G.__TautelliniConsole_consoleHook = true
    pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart",
        function() pcall(engine.clearCaches); trySurfaceConsole("ClientRestart") end)
end

-- flight driver: this ONE loop runs movement.holdTick each frame while fly is on (the
-- authoritative-position step). We never start a second loop, so nothing dangles across a
-- hot reload. Refreshed each (re)load via _G so the STABLE loop (started once) calls the
-- current code. Driven through kit.async: on builds with the Delayed Action System the tick
-- runs ON the game thread with no nested deferral; otherwise kit.async falls back to
-- LoopAsync + ExecuteInGameThread, and serialises ticks so game-thread work never backs up.
_G.__TautelliniConsole_flyHold = {
    active = function() return movement ~= nil and movement.isFlying() end,
    tick = function()
        if movement and engine then pcall(movement.holdTick, engine) end
    end,
}
if Async and Async.gameLoop and not _G.__TautelliniConsole_flyLoop then
    _G.__TautelliniConsole_flyLoop = true
    Async.gameLoop(16, function()
        local h = _G.__TautelliniConsole_flyHold
        if h and h.active() then return h.tick end
    end)
end

-- ------------------------------------------- shared mod menu (optional) --
-- Publish every cheat module's menu() section into the optional SharedModMenu.
-- UE4SS runs each mod in its OWN Lua state, so kit.menu serializes this spec over
-- UE4SS shared variables; SharedModMenu renders it and pushes edits back, which
-- kit.menu applies through these get/set closures (its ~250 ms poll runs them on
-- the game thread). With SharedModMenu not installed the publish is a harmless
-- no-op. Guarded on kit.menu so an older vendored kit just skips the tab. The
-- live reads behind the num/bool get()s cache their resolved handles in the engine
-- adapter, so the in-game poll stays lean (no per-tick FindAllOf once resolved).
if menuSpec and kit.menu and kit.menu.register then
    -- items and skills are console-only (their args do not fit a toggle/slider/
    -- button), so they contribute no menu section. lockpicking does: three tier
    -- buttons.
    local sections = menuSpec.build(engine, resources, stats, lockpickCmd, movement, timeCmd, worldCmd)
    if #sections > 0 then
        pcall(kit.menu.register, "TautelliniConsole", sections)
        log("SharedModMenu: registered " .. #sections .. " section(s) (a tab "
            .. "appears if the SharedModMenu mod is installed)")
    end
end

log("loaded v" .. ModVersion .. ". Open the console and type '" .. prefix
    .. "help' for the command list.")
