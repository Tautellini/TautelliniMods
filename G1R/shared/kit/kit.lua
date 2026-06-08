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
-- Single Lua state caveat: UE4SS loads ONE copy of a module name across all
-- mods (first require wins, shared via the global package.loaded). The kit's
-- API is therefore ADDITIVE-ONLY within a major; a breaking change renames the
-- module (kit -> kit2). Consumers should assert kit.version >= their minimum.
--
-- Siblings are loaded by FILE PATH (loadfile), not require, so they never enter
-- the global package.loaded and never collide across mods. Only "kit" itself is
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
return kit
