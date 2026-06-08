-- tinter.lua  --  all HighlightColor reads/writes (engine-facing class)
--
-- Owns the resolved palette and the per-tick tinting logic. It does NOT own
-- the per-piece bookkeeping: painted[], tinted[], selectedSig and selectedRow
-- live on the Session (the single state owner) and are read/written through
-- the passed session, exactly as the free function mutated `s` today. Keeping
-- one owner is what preserves the glow-adoption self-correction and avoids the
-- two-blue-pieces bug. Tinter reaches the engine only through the injected
-- pcall-wrapped facade and never touches the Solver.

local setmetatable = setmetatable
local ipairs, pairs = ipairs, pairs

local Tinter = {}
Tinter.__index = Tinter

-- palette: the resolved palette; engine: the pcall-wrapped facade; num: numeric
-- helpers (colorDist2); hintColor(s, palette) and partnerTints(s, palette) are
-- the injected PURE feature policies (nextmove.hint and connections), so the
-- core tint MECHANISM never knows which feature wants what.
function Tinter.new(palette, engine, num, hintColor, partnerTints)
    local self = setmetatable({}, Tinter)
    self.palette = palette
    self.engine = engine
    self.num = num
    self.hintColor = hintColor
    self.partnerTints = partnerTints
    return self
end

-- unified tinting, re-asserted every tick (the game's move FX rewrites the
-- channel). Layers: the hint (green/blue) outranks the partner purple; the
-- currently SELECTED piece is never written (its native brightening must
-- survive), except by the hint, which is the action cue. Restores are deferred
-- while a piece is selected.
function Tinter:retint(s)
    local palette = self.palette
    local engine, num = self.engine, self.num
    local desired = {}
    if s.flags.connections then
        -- the Connection Display feature supplies the partner tint map
        for b, color in pairs(self.partnerTints(s, palette)) do
            desired[b] = color
        end
    end
    local hintId = (s.flags.nextMove and s.nextMove) and s.nextMove.piece or nil
    if hintId then
        -- the Next-Move feature supplies the hint color
        desired[hintId] = self.hintColor(s, palette)
    end
    -- protection keys on the OBSERVED GLOW, never on the tracked selection:
    -- deferring writes/restores for the piece we THOUGHT was selected once
    -- preserved stale hint tints (two blue pieces at once). Reading the truth
    -- per piece is cheap and self-correcting. The hint is exempt from the
    -- guard: it is the action cue and may sit on the selected piece. A measured
    -- color matching the tint WE painted is OUR paint, never the game's glow:
    -- without this check a hint color near the glow signature got "preserved"
    -- as the selected look forever and stale tints piled up across pieces.
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
                            s.selectedRow = id -- adopt the observed truth
                        end
                    end
                end
            end
        end
        if isGlow then
            -- never paint over or "restore" the game's selected look; keep any
            -- buried tint marked so it is cleaned on deselect
            if s.tinted[id] then newTinted[id] = true end
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
