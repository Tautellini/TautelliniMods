-- tests for kit.engine.liveInstances under a fake-UE4SS shim. The shim must be
-- installed BEFORE require("kit") because engine.lua captures FindAllOf as a
-- local at load.
local function mkObj(name, valid)
    return {
        IsValid = function() return valid end,
        GetFullName = function() return name end,
    }
end
_G.FindAllOf = function(_)
    return {
        mkObj("BP_X /Game/Foo.BP_X", true),   -- kept
        mkObj("Default__BP_X", true),         -- filtered: CDO
        mkObj("BP_X /Game/Bar.BP_X", false),  -- filtered: not valid
    }
end

-- run from this dir (tests/run.ps1 sets the cwd); the kit is two levels up
package.path = "../../?/?.lua;./?.lua;" .. package.path

local T = require("tinytest")
local kit = require("kit")

T.add("liveInstances filters CDOs (Default__) and invalid objects, always a table", function()
    local got = kit.engine.liveInstances("BP_X")
    T.ok(type(got) == "table", "liveInstances must always return a table")
    T.eq(#got, 1)
    T.eq(got[1]:GetFullName(), "BP_X /Game/Foo.BP_X")
end)

os.exit(T.run())
