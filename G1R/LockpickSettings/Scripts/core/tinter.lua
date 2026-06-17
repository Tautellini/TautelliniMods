-- tinter.lua -- all HighlightColor reads/writes (engine-facing). Owns the palette and
-- per-tick tinting; the per-piece bookkeeping (painted/tinted/selectedRow) lives on the
-- Session. Reaches the engine only through the injected pcall-wrapped facade.

local setmetatable = setmetatable
local pairs = pairs

local Tinter = {}
Tinter.__index = Tinter

-- hintColor(s,palette) and partnerTints(s,palette) are the injected PURE feature
-- policies, so the tint mechanism never knows which feature wants what.
function Tinter.new(palette, engine, num, hintColor, partnerTints)
    local self = setmetatable({}, Tinter)
    self.palette = palette
    self.engine = engine
    self.num = num
    self.hintColor = hintColor
    self.partnerTints = partnerTints
    return self
end

-- unified tinting, re-asserted every tick (the game's move FX rewrites the channel).
-- Hint outranks the partner tint; the selected piece keeps its native glow (except for
-- the hint). The glow check reads the truth per piece to avoid stale tints piling up.
function Tinter:retint(s)
    local palette = self.palette
    local engine, num = self.engine, self.num
    local desired = {}
    if s.flags.connections then
        for b, color in pairs(self.partnerTints(s, palette)) do
            desired[b] = color
        end
    end
    local hintId = (s.flags.nextMove and s.nextMove) and s.nextMove.piece or nil
    if hintId then
        desired[hintId] = self.hintColor(s, palette)
    end
    local newTinted = {}
    for id, e in pairs(s.pieces) do
        local want = desired[id]
        local isGlow = false
        if s.selectedSig and id ~= hintId and (want or s.tinted[id]) then
            local mid = e.mids[1]
            if mid then
                local c = engine.readHighlight(mid)
                if c then
                    local own = s.painted[id]
                    local mine = own and num.colorDist2(c, own) < 0.05
                    if not mine and num.colorDist2(c, s.selectedSig) < 0.05 then
                        isGlow = true
                        if id ~= s.selectedRow then
                            s.selectedRow = id -- adopt the observed selection
                        end
                    end
                end
            end
        end
        if isGlow then
            if s.tinted[id] then newTinted[id] = true end -- keep buried tint for cleanup
        elseif want then
            engine.writeColor(e, want)
            s.painted[id] = want
            newTinted[id] = true
        elseif s.tinted[id] then
            if e.default then engine.writeColor(e, e.default) end
            s.painted[id] = nil
        end
    end
    s.tinted = newTinted
end

return Tinter
