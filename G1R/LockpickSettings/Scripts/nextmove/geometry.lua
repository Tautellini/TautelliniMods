-- geometry.lua  --  rail axis, step and bar-column anchor (PURE math class)
--
-- ZERO UE4SS globals: Session reads ALL coordinates through the engine facade
-- (slot cloud via engine.readSlot, part roots via engine.readRootPos) and the
-- 45-unit stale-actor gate at the call site where the piece's own slot is
-- known, then hands Geometry plain {x,y,z} number arrays. So the identical
-- file loads under bare LuaJIT and the tests feed it synthetic clouds.
--
-- Modeled as a class per the project's metatable-class convention (and for the
-- tidy fed-cloud-in / frame-out surface plus the placeValues/snapRot
-- namespace); it holds no long-lived state. The thresholds here are
-- play-verified (2026-06-07, 252/252 bar reads on one column): a subtle
-- reorder silently re-opens the anchor-guessing era the direct read retired.
-- MOVE-AND-PRESERVE only.

local setmetatable = setmetatable
local ipairs, pairs = ipairs, pairs
local tostring = tostring
local math, table, string = math, table, string
local floor, abs, sqrt = math.floor, math.abs, math.sqrt

local Geometry = {}
Geometry.__index = Geometry

-- opts: { log = function(msg) end | nil, debug = boolean }
function Geometry.new(pieceCount, opts)
    opts = opts or {}
    local self = setmetatable({}, Geometry)
    self.pieceCount = pieceCount
    self.log = opts.log or function() end
    self.debug = opts.debug and true or false
    return self
end

-- base-7 place values, 0-indexed (place[id] = 7^id). MUST stay 0-indexed: the
-- search reads (rot+3)*place[id] and the engine slot index equals the piece id.
function Geometry.placeValues(n)
    local place = {}
    local pw = 1
    for id = 0, n - 1 do
        place[id] = pw
        pw = pw * 7
    end
    return place
end

-- absolute grid snap: the rotation a slot projects to around the anchored
-- center. No accumulation, so shakes, resets and missed settles cannot drift it.
function Geometry.snapRot(slot, axis, cpProj, stepSize)
    local pr = slot[1] * axis[1] + slot[2] * axis[2] + slot[3] * axis[3]
    return floor((pr - cpProj) / stepSize + 0.5)
end

-- which way is "screen right" along the rail, from STAGE GEOMETRY alone (no
-- camera API): the stage prefab's fixed camera views the lock with piece ids
-- increasing screen-UP and no roll, so screen-right along the rail is
-- worldUp x rowDir projected on the rail axis. The player camera does not
-- render the stage, so projecting on it only works by accident.
function Geometry:stageScreenRight(slotStart, axis)
    local r0, rN = slotStart[0], slotStart[self.pieceCount - 1]
    if not (r0 and rN and axis) then return nil end
    local rv = { rN[1] - r0[1], rN[2] - r0[2], rN[3] - r0[3] }
    -- remove the column component, keep the pure row direction
    local rp = rv[1] * axis[1] + rv[2] * axis[2] + rv[3] * axis[3]
    rv[1], rv[2] = rv[1] - rp * axis[1], rv[2] - rp * axis[2]
    -- worldUp x rowDir, horizontal by construction
    local cx, cy = -rv[2], rv[1]
    local pr = cx * axis[1] + cy * axis[2]
    if abs(pr) > 1.0 then
        return pr > 0 and 1 or -1
    end
    return nil
end

-- candidate rail axes from the slot cloud: differencing adjacent-row
-- differences cancels the row direction. The degenerate same-column fallback
-- recovers an axis from the row direction's horizontal perpendicular.
function Geometry:deriveAxis(slotStart)
    local n = self.pieceCount
    local D = {}
    for id = 0, n - 2 do
        local a, b = slotStart[id], slotStart[id + 1]
        D[#D + 1] = { b[1] - a[1], b[2] - a[2], b[3] - a[3] }
    end
    local best, bestLen = nil, 4.0 -- ignore sub-step noise
    for i = 1, #D do
        for j = i + 1, #D do
            local e = { D[i][1] - D[j][1], D[i][2] - D[j][2],
                D[i][3] - D[j][3] }
            local len = sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3])
            if len > bestLen then
                best, bestLen = e, len
            end
        end
    end
    local candidates = {}
    if best then
        candidates[1] = { name = "slot-cloud", v = { best[1] / bestLen,
            best[2] / bestLen, best[3] / bestLen } }
    end
    if not best and #D > 0 then
        -- DEGENERATE SCRAMBLE fallback (all pieces in one column): the
        -- difference-of-differences cancels to nothing, but the ROW direction
        -- always exists, rails are horizontal, so the axis is the row
        -- direction's horizontal perpendicular.
        local rx, ry, rz = 0, 0, 0
        for _, dv in ipairs(D) do
            rx, ry, rz = rx + dv[1], ry + dv[2], rz + dv[3]
        end
        local rl = sqrt(rx * rx + ry * ry + rz * rz)
        if rl > 1.0 then
            rx, ry = rx / rl, ry / rl
            local ax, ay = ry, -rx -- cross(rowDir, worldUp)
            local al = sqrt(ax * ax + ay * ay)
            if al > 0.5 then
                candidates[#candidates + 1] = { name = "row-cross",
                    v = { ax / al, ay / al, 0 } }
            end
        end
    end
    return candidates
end

-- fit the step size for a given axis projection: the grid is slightly
-- nonuniform and the scene's step property is unreadable in some
-- configurations, so scan for the step that snaps the projections onto a grid.
-- Returns bestStep, bestWorst (the worst residual at that step).
function Geometry:fitStep(ps)
    local n = self.pieceCount
    local bestStep, bestWorst
    local step = 5.6
    while step <= 7.0 do
        local qs, qmean = {}, 0
        for id = 0, n - 1 do
            qs[id] = ps[id] / step
            qmean = qmean + qs[id]
        end
        qmean = qmean / n
        local resid = {}
        for id = 0, n - 1 do
            qs[id] = qs[id] - qmean
            resid[#resid + 1] = qs[id] - floor(qs[id] + 0.5)
        end
        table.sort(resid)
        local c = resid[floor((#resid + 1) / 2)]
        local worst = 0
        local minR, maxR = 99, -99
        for id = 0, n - 1 do
            local q = qs[id] - c
            local rr = floor(q + 0.5)
            local rs = abs(q - rr)
            if rs > worst then worst = rs end
            if rr < minR then minR = rr end
            if rr > maxR then maxR = rr end
        end
        if maxR - minR <= 6
            and (bestWorst == nil or worst < bestWorst) then
            bestStep, bestWorst = step, worst
        end
        step = step + 0.02
    end
    return bestStep, bestWorst
end

-- the bar-column DIRECT READ on one axis: the plate type tracks the slots; every
-- other readable type is a fixed-column candidate that must put EVERY plate on
-- an in-range integer grid; exactly one distinct surviving column is required,
-- anything else (none, several) is an honest geoFail. partPos[id][ty] = {p,d2}
-- is supplied by the caller (already engine-read and 45-unit-gated). Returns an
-- adopted table { c, st, rots, ty } or nil, geoFail.
function Geometry:findAnchorColumn(ps, axis, partPos, bestStep, degenerate)
    local n = self.pieceCount
    -- which types are present
    local tySet = {}
    for id = 0, n - 1 do
        for ty in pairs(partPos[id] or {}) do tySet[ty] = true end
    end
    -- the plate type tracks the slots (equal positions)
    local plateTy = nil
    for ty in pairs(tySet) do
        local match, have = 0, 0
        for id = 0, n - 1 do
            local e = partPos[id][ty]
            if e then
                have = have + 1
                if e.d2 < 1.5 ^ 2 then match = match + 1 end
            end
        end
        if have > 0 and match * 2 > have then
            plateTy = ty
            break
        end
    end
    -- fixed-column candidates from every other type: one shared column across
    -- pieces, tight spread required
    local cols = {}
    for ty in pairs(tySet) do
        if ty ~= plateTy then
            local prj = {}
            for id = 0, n - 1 do
                local e = partPos[id][ty]
                if e then
                    prj[#prj + 1] = e.p[1] * axis[1]
                        + e.p[2] * axis[2] + e.p[3] * axis[3]
                end
            end
            if #prj > 0 then
                table.sort(prj)
                if prj[#prj] - prj[1] < 2.0 then
                    cols[#cols + 1] = { ty = ty,
                        c = prj[floor((#prj + 1) / 2)] }
                end
            end
        end
    end
    -- validation: the column must put EVERY plate on an integer grid position
    -- within the rail
    local adopted, geoFail = nil, nil
    for _, cc in ipairs(cols) do
        local st = not degenerate and bestStep or nil
        if degenerate then
            -- step from the uniform plate-to-bar distance: |D| = k*step with
            -- k in 1..3 and the step physically near 6.2, so k is unique.
            local D = 0
            for id = 0, n - 1 do
                local d = ps[id] - cc.c
                if abs(d) > abs(D) then D = d end
            end
            for k = 1, 3 do
                local kk = abs(D) / k
                if kk > 5.4 and kk < 7.2 then
                    st = kk
                    break
                end
            end
        end
        if st then
            local rots, okAll = {}, true
            for id = 0, n - 1 do
                local q = (ps[id] - cc.c) / st
                local r = floor(q + 0.5)
                if abs(q - r) > 0.30
                    or r < -3 or r > 3 then
                    okAll = false
                    break
                end
                rots[id] = r
            end
            if okAll then
                if adopted ~= nil
                    and abs(adopted.c - cc.c)
                    > st * 0.3 then
                    adopted = nil
                    geoFail = "two fixed columns both fit the plate grid"
                    break
                elseif adopted == nil then
                    adopted = { c = cc.c, st = st,
                        rots = rots, ty = cc.ty }
                end
            elseif self.debug then
                self.log(string.format("solver: column ty=%s "
                    .. "rejected by the plate grid",
                    tostring(cc.ty)))
            end
        end
    end
    if not adopted and not geoFail then
        geoFail = (#cols == 0)
            and "no fixed part column readable"
            or "no fixed column fits the plate grid"
    end
    return adopted, geoFail
end

-- derive the full rail frame from the slot cloud plus the (pre-read, gated)
-- part-root positions. Returns frame
--   { axis, sign, stepSize, cpProj, rotStart (0-indexed), screenRight,
--     hintGeometry = true }
-- or nil, geoFail. Pure: no engine, no pcall (errors here are bugs, the caller
-- pcall-wraps defensively).
function Geometry:derive(slotStart, partPos)
    local n = self.pieceCount
    local candidates = self:deriveAxis(slotStart)
    local geoFail = nil
    for _, cand in ipairs(candidates) do
        local axis = cand.v
        local ps = {}
        for id = 0, n - 1 do
            local sl = slotStart[id]
            ps[id] = sl[1] * axis[1] + sl[2] * axis[2] + sl[3] * axis[3]
        end
        local bestStep, bestWorst = self:fitStep(ps)
        if bestWorst and bestWorst <= 0.30 then
            local psMin, psMax = ps[0], ps[0]
            for id = 1, n - 1 do
                if ps[id] < psMin then psMin = ps[id] end
                if ps[id] > psMax then psMax = ps[id] end
            end
            -- same-column scrambles give the sweep nothing to fit; the step
            -- then derives from the bar distance instead
            local degenerate = psMax - psMin < 4.0
            local adopted, fail = self:findAnchorColumn(ps, axis, partPos,
                bestStep, degenerate)
            if fail and not geoFail then geoFail = fail end
            if adopted then
                local frame = {
                    axis = axis,
                    sign = 1,
                    stepSize = adopted.st,
                    -- the anchor as an absolute projection: every settle snaps
                    -- every pin DIRECTLY onto the grid around this center
                    cpProj = adopted.c,
                    rotStart = {},
                    hintGeometry = true,
                }
                for id = 0, n - 1 do
                    frame.rotStart[id] = adopted.rots[id]
                end
                frame.screenRight = self:stageScreenRight(slotStart, axis)
                if self.debug then
                    self.log(string.format("solver: anchored on the ty=%s "
                        .. "column (step %.2f%s)",
                        tostring(adopted.ty), adopted.st,
                        degenerate and ", degenerate scramble"
                        or string.format(", residual %.2f", bestWorst)))
                end
                return frame
            end
        end
        if self.debug then
            self.log(string.format("solver: slot-cloud axis rejected "
                .. "(best residual %.2f)", bestWorst or 99))
        end
    end
    return nil, geoFail
end

return Geometry
