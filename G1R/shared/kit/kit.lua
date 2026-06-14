-- kit.lua  --  the shared TautelliniMods library (the "kit")
--
-- ONE source of truth in the repo (G1R/shared/kit/); deploy.ps1 vendors a copy
-- into each mod under <Mod>/shared/kit/ so every deployed mod and public ZIP is
-- SELF-CONTAINED (no global Mods/shared dependency). A mod's main.lua self-adds
-- its own shared/ to package.path, then require("kit") returns this table.
--
-- Generic, game-agnostic helpers only: no mod-domain knowledge ever lives here
-- (a CI grep guards that, see tests/). Reusable by any future G1R mod.
--
-- ISOLATED Lua states: UE4SS runs every mod in its OWN Lua state (measured
-- 2026-06-14: _G, package.loaded, and even this kit are SEPARATE tables per mod;
-- the old "single state, first-require-wins" assumption was wrong). So vendoring a
-- private copy per mod is REQUIRED, not just tidy, there is no shared module instance
-- to rely on. The ONLY cross-mod channel is UE4SS shared variables, which the menu
-- bridge uses (see menu.lua). The kit API stays additive-only within a major; a
-- breaking change renames the module (kit -> kit2). Assert kit.version >= your minimum.
--
-- Siblings are loaded by FILE PATH (loadfile), not require, so only "kit" itself is
-- a require target.

local debug, assert, loadfile = debug, assert, loadfile

local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local function load(name)
    return assert(loadfile(dir .. "/" .. name .. ".lua"))()
end

local kit = {}
kit.version = load("version") -- the kit's own semver (string)
kit.log     = load("log")     -- log.make("[Tag]") -> logger
kit.num     = load("num")     -- lookup, colorDist2
kit.color   = load("color")   -- colorFrom decoder
kit.engine  = load("engine")  -- liveInstances, readRootPos (generic UE4SS access)
kit.boot    = load("boot")    -- tryRequire (require-and-degrade)
kit.menu    = load("menu")    -- register(name, spec): cross-mod menu bridge (shared vars)
return kit
