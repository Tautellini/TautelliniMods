-- core/registry.lua  --  the command registry. Holds command specs and applies
-- the configured prefix to their names. PURE: no UE4SS globals, unit-testable.
--
-- A spec is { name = string, help = string, run = function(params, out, engine) }.
-- The registry never registers anything itself (that is main.lua's job in the
-- tail); it only stores specs, computes full (prefixed) names, and formats help.

local ipairs, table, setmetatable = ipairs, table, setmetatable

local registry = {}
registry.__index = registry

function registry.new(prefix)
    return setmetatable({ prefix = prefix or "", specs = {} }, registry)
end

function registry:add(spec)
    self.specs[#self.specs + 1] = spec
    return self
end

function registry:addAll(list)
    if list then
        for _, spec in ipairs(list) do self:add(spec) end
    end
    return self
end

function registry:all()
    return self.specs
end

function registry:fullName(spec)
    return self.prefix .. spec.name
end

-- one "name  -  help" line per command, sorted for stable output.
function registry:helpLines()
    local lines = {}
    for _, spec in ipairs(self.specs) do
        lines[#lines + 1] = self.prefix .. spec.name .. "  -  " .. (spec.help or "")
    end
    table.sort(lines)
    return lines
end

return registry
