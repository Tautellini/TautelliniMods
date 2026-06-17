-- cheats/time.lua  --  time: print the clock, or set it absolutely.
--
-- `time` prints the current clock as HH:MM. `time 8:30` (or `time 8`) sets it to
-- exactly that via GameTimeSubsystem:SetCurrentClockTime, verified by SleepProbe.
-- Accepted limitation: a raw clock set does NOT snap NPCs to their new daily
-- routine (they resume over time); that is the separate SleepAnywhere problem.
-- PURE of UE4SS globals: engine is injected.

local require, string, math, ipairs, tonumber, tostring =
    require, string, math, ipairs, tonumber, tostring
local args = require("util.args")

local time = {}

-- tracked so a bare `freezetime` flips and the menu toggle reflects state.
local freezeOn = false

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
        { name = "skiptime",
          help = "advance the clock by N seconds (3600 = 1h)",
          run = function(p, out, engine)
              local secs = tonumber(p[1])
              if not secs then out.line("usage: skiptime <seconds> (3600 = 1h)"); return end
              out.line(engine.skipTime(secs) and ("skiptime: +" .. secs .. "s")
                  or "skiptime: failed (no GameTimeSubsystem?)")
          end },
        { name = "freezetime",
          help = "freeze/unfreeze the day-night clock [on|off]",
          run = function(p, out, engine)
              local verb = args.toggleVerb(p[1])
              if verb == nil then out.line("usage: freezetime [on|off]"); return end
              local want
              if verb == "toggle" then want = not freezeOn else want = (verb == "on") end
              if engine.freezeTime(want) then
                  freezeOn = want
                  out.line("freezetime: " .. (want and "ON (clock stopped)" or "OFF"))
              else
                  out.line("freezetime: failed (no GameTimeSubsystem?)")
              end
          end },
        { name = "timescale",
          help = "game speed: 1 = normal, 2 = double, 0.5 = half",
          run = function(p, out, engine)
              local v = tonumber(p[1])
              if not v or v <= 0 then out.line("usage: timescale <value> (1 = normal, 2 = 2x)"); return end
              out.line(engine.setTimeDilation(v) and ("timescale: " .. v) or "timescale: failed")
          end },
    }
end

-- preset hours offered as one-click buttons alongside the slider.
local PRESETS = { 8, 12, 20 }

-- SharedModMenu section: a slider that jumps the clock to the top of the chosen
-- hour, plus a button per preset hour (minute precision stays console-only via
-- `time HH:MM`).
function time.menu(engine)
    local items = {
        { name = "Hour (0-23)", kind = "num", min = 0, max = 23, step = 1,
          get = function()
              local c = engine.readClock()
              return c and c.hour or 0
          end,
          set = function(v)
              v = math.floor((v or 0) + 0.5)
              if v < 0 then v = 0 elseif v > 23 then v = 23 end
              engine.setClock(v, 0, 0.0)
          end },
    }
    for _, h in ipairs(PRESETS) do
        items[#items + 1] = {
            name = string.format("Set %02d:00", h), kind = "action",
            set = function() engine.setClock(h, 0, 0.0) end,
        }
    end
    items[#items + 1] = {
        name = "Freeze Clock", kind = "bool",
        get = function() return freezeOn end,
        set = function(v)
            v = v and true or false
            if engine.freezeTime(v) then freezeOn = v end
        end,
    }
    items[#items + 1] = {
        name = "Game Speed", kind = "num", min = 0.25, max = 4, step = 0.25,
        get = function() return 1 end, -- write-only: no live getter for dilation
        set = function(v) engine.setTimeDilation(v) end,
    }
    return { title = "Time", items = items }
end

return time
