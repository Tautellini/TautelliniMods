-- log.make("[Tag]") returns a logger that prefixes the tag. UE4SS routes print
-- to its log; the trailing newline matches the project's house format.
local print, tostring = print, tostring

local log = {}

function log.make(tag)
    return function(msg)
        print(tag .. " " .. tostring(msg) .. "\n")
    end
end

return log
