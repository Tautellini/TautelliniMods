-- core/output.lua  --  a tiny output sink that mirrors a command's results to
-- BOTH the console output device (Ar, visible in the native ~ console) and the
-- UE4SS log (print, visible in the UE4SS console window). Covers both
-- front-ends. PURE: it touches Ar only through the passed handle, names no
-- globals, so it loads under bare LuaJIT.

local tostring, pcall = tostring, pcall

local output = {}

-- ar  : the console FOutputDevice handed to the command handler, or nil.
-- log : the kit logger (adds the mod tag + newline), or nil.
function output.make(ar, log)
    local function line(msg)
        msg = tostring(msg)
        if log then log(msg) end
        if ar then pcall(function() ar:Log(msg) end) end
    end
    return { line = line }
end

return output
