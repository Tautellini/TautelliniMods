-- cheats/time.lua  --  time: print the clock, or set it absolutely.
--
-- `time` prints the current clock as HH:MM. `time 8:30` (or `time 8`) sets it to
-- exactly that via GameTimeSubsystem:SetCurrentClockTime, verified by SleepProbe.
-- Accepted limitation: a raw clock set does NOT snap NPCs to their new daily
-- routine (they resume over time); that is the separate SleepAnywhere problem.
-- PURE of UE4SS globals: engine is injected.

local require, string = require, string
local args = require("util.args")

local time = {}

function time.specs()
    return {
        { name = "time",
          help = "print the clock, or 'time 8:30' to set it (24h, absolute)",
          run = function(p, out, engine)
              if p[1] == nil then
                  local c = engine.readClock()
                  if c then
                      out.line(string.format("time: %02d:%02d", c.hour, c.minute))
                  else
                      out.line("time: no GameTimeSubsystem (be in-game)")
                  end
                  return
              end
              local h, m = args.parseClock(p[1])
              if not h then
                  out.line("usage: time HH:MM (e.g. time 8:30), 24h, hour 0-23 minute 0-59")
                  return
              end
              if engine.setClock(h, m, 0.0) then
                  out.line(string.format("time set to %02d:%02d "
                      .. "(NPCs resume their routine over time, they do not snap)", h, m))
              else
                  out.line("time: set failed (no GameTimeSubsystem?)")
              end
          end },
    }
end

return time
