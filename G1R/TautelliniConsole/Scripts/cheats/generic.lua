-- cheats/generic.lua  --  help, set, dumpobj: the reflection power tools.
--
-- `help` lists every registered command (so it needs the registry). `set` and
-- `dumpobj` are thin wrappers over the engine adapter's reflection helpers. PURE
-- of UE4SS globals: engine (and the registry, for help) are injected.

local ipairs, tostring = ipairs, tostring

local generic = {}

-- registry is needed so `help` can enumerate the live command set (including
-- itself and any prefix).
function generic.specs(registry)
    return {
        { name = "help",
          help = "list all commands",
          run = function(p, out, engine)
              out.line("TautelliniConsole commands:")
              for _, ln in ipairs(registry:helpLines()) do out.line("  " .. ln) end
          end },
        { name = "set",
          help = "set <class|object> <property> <value> (writes ALL instances of a class)",
          run = function(p, out, engine)
              if not (p[1] and p[2] and p[3]) then
                  out.line("usage: set <class|object> <property> <value>")
                  return
              end
              local msg = engine.setPropByReflection(p[1], p[2], p[3])
              out.line(msg or ("set " .. tostring(p[1]) .. "." .. tostring(p[2])
                  .. " = " .. tostring(p[3])))
          end },
        { name = "dumpobj",
          help = "dumpobj <name> : print an object's properties",
          run = function(p, out, engine)
              if not p[1] then
                  out.line("usage: dumpobj <object-or-class-name>")
                  return
              end
              engine.dumpProps(p[1], function(line) out.line("  " .. line) end, out)
          end },
    }
end

return generic
