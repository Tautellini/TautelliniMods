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

T.add("isValid: true for a live UObject, false for invalid / nil / non-object", function()
    T.ok(kit.engine.isValid(mkObj("X", true)) == true, "valid object -> true")
    T.ok(kit.engine.isValid(mkObj("X", false)) == false, "invalid object -> false")
    T.ok(kit.engine.isValid(nil) == false, "nil -> false")
    T.ok(kit.engine.isValid(42) == false, "non-object (no :IsValid) -> false, not an error")
end)

T.add("guard: runs fn on a valid object and returns its result", function()
    T.eq(kit.engine.guard(mkObj("Y", true), function(o) return o:GetFullName() end), "Y")
end)

T.add("guard: invalid object -> nil and fn never runs", function()
    local ran = false
    local got = kit.engine.guard(mkObj("Z", false), function() ran = true; return 1 end)
    T.eq(got, nil)
    T.ok(ran == false, "fn must not run on an invalid object")
end)

T.add("guard: a Lua error inside fn is caught and yields nil", function()
    T.eq(kit.engine.guard(mkObj("W", true), function() error("boom") end), nil)
end)

T.add("try: returns the value, or nil on a caught error", function()
    T.eq(kit.engine.try(function() return 7 end), 7)
    T.eq(kit.engine.try(function() error("x") end), nil)
end)

os.exit(T.run())
