-- test_geometry.lua  --  tests for the REAL shipped Scripts/geometry.lua
--
-- geometry.lua is pure math: Session reads the slot cloud and part-root
-- positions through the engine and the 45-unit gate, then hands Geometry plain
-- number arrays. So we synthesize a known layout (no UE4SS present) and assert
-- the anchor derivation recovers the rotations, and that a missing bar column
-- fails honestly instead of guessing.

local function script_dir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*)[/\\][^/\\]*$") or "."
end
local DIR = script_dir()
package.path = DIR .. "/../Scripts/?.lua;" .. DIR .. "/?.lua;" .. package.path

local T = require("tinytest")
local Geometry = require("geometry")

-- Synthesize a lock on a known frame: rail axis +X, rows spaced along Y, the
-- bar column fixed at X = barX, each plate (slot) offset rot*step along the
-- axis. partPos carries the plate (on the slot, d2 ~ 0) and the bar (on the
-- fixed column). This is exactly the shape Session hands Geometry.derive.
local function synth(rotList, step, rowSpacing, barX)
    local n = #rotList
    local slotStart, partPos = {}, {}
    for id = 0, n - 1 do
        local rot = rotList[id + 1]
        local slot = { barX + rot * step, id * rowSpacing, 0 }
        slotStart[id] = slot
        local bar = { barX, id * rowSpacing, 0 }
        local function d2(p)
            return (p[1] - slot[1]) ^ 2 + (p[2] - slot[2]) ^ 2 + (p[3] - slot[3]) ^ 2
        end
        partPos[id] = {
            plate = { p = slot, d2 = d2(slot) },
            bar = { p = bar, d2 = d2(bar) },
        }
    end
    return slotStart, partPos, n
end

-- the rail axis sign is arbitrary (the model is symmetric, colors resolve via
-- the camera), so the recovered rotations may be globally negated. Accept
-- either, as long as the pattern matches under one consistent sign.
local function rots_match(frame, rotList)
    local sign = nil
    for id = 0, #rotList - 1 do
        local got, want = frame.rotStart[id], rotList[id + 1]
        if want ~= 0 then
            local s = (got == want) and 1 or (got == -want and -1 or 0)
            if s == 0 then return false end
            if sign == nil then sign = s elseif sign ~= s then return false end
        elseif got ~= 0 then
            return false
        end
    end
    return true
end

T.add("derive recovers the rotations and anchor from a known layout", function()
    local rotList = { 2, -1, 3, -2, 1 }
    local step, barX = 6.3, 100.0
    local slotStart, partPos = synth(rotList, step, 10.0, barX)
    local g = Geometry.new(#rotList)
    local frame, geoFail = g:derive(slotStart, partPos)
    T.ok(frame ~= nil, "derive failed: " .. tostring(geoFail))
    T.ok(frame.hintGeometry == true, "hintGeometry should be set")
    T.ok(rots_match(frame, rotList), "recovered rotations do not match the layout")
    T.ok(frame.stepSize > 6.1 and frame.stepSize < 6.5,
        "step out of range: " .. tostring(frame.stepSize))
    T.ok(math.abs(frame.cpProj) > 90 and math.abs(frame.cpProj) < 110,
        "anchor column projection off: " .. tostring(frame.cpProj))
    T.ok(frame.screenRight == 1 or frame.screenRight == -1,
        "screenRight should resolve to a side")
end)

T.add("no fixed bar column fails honestly (no anchor guessing)", function()
    -- only the plate type present: nothing can serve as the fixed column
    local rotList = { 2, -1, 3, -2, 1 }
    local step, barX = 6.3, 100.0
    local slotStart, partPos = synth(rotList, step, 10.0, barX)
    for id = 0, #rotList - 1 do partPos[id].bar = nil end
    local g = Geometry.new(#rotList)
    local frame, geoFail = g:derive(slotStart, partPos)
    T.ok(frame == nil, "expected derive to fail with no fixed column")
    T.ok(geoFail ~= nil and geoFail:find("column", 1, true) ~= nil,
        "expected a column-related geoFail, got: " .. tostring(geoFail))
end)

T.add("placeValues are 0-indexed base-7", function()
    local p = Geometry.placeValues(4)
    T.eq(p[0], 1, "place[0]")
    T.eq(p[1], 7, "place[1]")
    T.eq(p[2], 49, "place[2]")
    T.eq(p[3], 343, "place[3]")
end)

T.add("snapRot snaps a projection to the nearest rail rotation", function()
    local axis = { 1, 0, 0 }
    -- center at x=100, step 6.3: x = 100 + 2*6.3 should snap to rot 2
    T.eq(Geometry.snapRot({ 100 + 2 * 6.3, 5, 0 }, axis, 100, 6.3), 2, "rot 2")
    T.eq(Geometry.snapRot({ 100 - 3 * 6.3, 5, 0 }, axis, 100, 6.3), -3, "rot -3")
    T.eq(Geometry.snapRot({ 100 + 0.4, 5, 0 }, axis, 100, 6.3), 0, "near-center snaps to 0")
end)

os.exit(T.run())
