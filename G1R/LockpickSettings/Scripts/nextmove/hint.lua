-- hint.lua -- the hinted piece's color (PURE: no UE4SS globals, testable).
-- green = turn left, blue = turn right (from screenRight, or inputToAxis if set);
-- neutral when the direction is unknown (never gamble: a refused move costs durability).

local hint = {}

function hint.color(s, palette)
    if not s.nextMove then return palette.hintNeutral end
    local axisDir = (s.nextMove.dir or 1) * s.sign
    if s.inputToAxis then
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
