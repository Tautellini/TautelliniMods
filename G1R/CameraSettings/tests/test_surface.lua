-- tests/test_surface.lua -- catalog integrity for camera/surface.lua (pure module).
-- Run from this folder: luajit test_surface.lua  (or lua test_surface.lua)

package.path = "../Scripts/?.lua;" .. package.path
local surface = require("camera.surface")

assert(type(surface.sections) == "table" and #surface.sections > 0, "no sections")

local seen, count = {}, 0
for _, sec in ipairs(surface.sections) do
    assert(type(sec.title) == "string" and sec.title ~= "", "section needs a title")
    assert(type(sec.controls) == "table" and #sec.controls > 0,
        "section needs controls: " .. tostring(sec.title))
    for _, c in ipairs(sec.controls) do
        count = count + 1
        assert(type(c.key) == "string" and c.key ~= "", "control needs a key")
        assert(not seen[c.key], "duplicate key: " .. tostring(c.key))
        seen[c.key] = true
        assert(type(c.name) == "string" and c.name ~= "", "control needs a name: " .. c.key)
        assert(type(c.min) == "number" and type(c.max) == "number" and c.min < c.max,
            "bad range: " .. c.key)
        assert(type(c.step) == "number" and c.step > 0, "bad step: " .. c.key)
        local hasField = type(c.field) == "table" and #c.field > 0
        local hasVector = type(c.vector) == "string" and type(c.component) == "string"
        assert(hasField or hasVector, "control needs field or vector: " .. c.key)
        if hasVector then
            assert(c.component == "X" or c.component == "Y" or c.component == "Z",
                "bad component: " .. c.key)
        end
    end
end

print(string.format("test_surface OK: %d sections, %d controls", #surface.sections, count))
