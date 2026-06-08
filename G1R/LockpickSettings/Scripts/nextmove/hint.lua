-- hint.lua  --  Next-Move feature: the hinted piece's color (PURE).
--
-- The hint color encodes the SCREEN direction of the suggested move: green =
-- move the piece left, blue = move it right. The mapping comes from a measured
-- input-to-axis calibration when present, else the stage geometry; while
-- neither is known the neutral color marks the piece without gambling on a
-- direction (a refused move costs durability). No engine, separately testable.

local hint = {}

function hint.color(s, palette)
    if not s.nextMove then return palette.hintNeutral end
    local axisDir = (s.nextMove.dir or 1) * s.sign
    if s.inputToAxis then
        -- measured from observed moves: input * inputToAxis = piece axis
        -- direction; overrides the geometric rule when present
        local pressRight = axisDir * s.inputToAxis > 0
        return pressRight and palette.hintRight or palette.hintLeft
    end
    if s.screenRight then
        local pressRight = axisDir * s.screenRight > 0
        return pressRight and palette.hintRight or palette.hintLeft
    end
    return palette.hintNeutral
end

return hint
