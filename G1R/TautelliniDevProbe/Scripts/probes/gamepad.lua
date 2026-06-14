-- probes/gamepad.lua  --  find a working way to READ controller state from Lua.
--
-- SHELVED 2026-06-14 (not in main.lua's MODULES). CONCLUSION: input polling from Lua is a dead
-- end on this build. We CAN read every gamepad FKey + its InputAction out of the 57 Enhanced
-- Input mapping contexts, but IsInputKeyDown / GetInputAnalogKeyState fail "Array failed
-- invariants check" with ANY FKey-by-value param (real one from the engine OR a constructed
-- one). The only untested route left was Enhanced Input GetActionValue(UInputAction*) (a UObject
-- param, not an FKey); not pursued. Kept as a record + starting point if resumed.
--
-- UE4SS RegisterKeyBind is keyboard/mouse ONLY, so gamepad nav needs input read via
-- reflection. MEASURED 2026-06-14: APlayerController:IsInputKeyDown/etc ERR "Array failed
-- invariants" with a Lua-CONSTRUCTED FKey (table or string), FKey can't be built from Lua. So
-- we hunt for a REAL FKey: the game maps the pad via Enhanced Input, whose InputMappingContexts
-- (57 loaded) hold real FKeys. NOTE on this build TArray indexing is 1-BASED (index 0 ->
-- "out of range"), and FKey.KeyName is an FName USERDATA needing :ToString() (tostring gives
-- the pointer). Both bit the earlier rounds.
--
-- F3 = DISCOVER: walk every IMC's Mappings, log counts + a sample of ALL key names + the gamepad
-- ones, grab the real FKeys, and test polling them. F10 = SCAN the discovered keys. Inert until
-- pressed; the scan is one gen-guarded LoopAsync.

local rawget, rawset, pcall, ipairs, pairs, type, tostring, tonumber =
      rawget, rawset, pcall, ipairs, pairs, type, tostring, tonumber
local math, string, table = math, string, table

return function(ctx)
    local log = ctx.makeLog("gamepad")
    local isValid, firstLive, onGameThread, fullName = ctx.isValid, ctx.firstLive, ctx.onGameThread, ctx.fullName
    local FindAllOf = ctx.FindAllOf
    local LoopAsync = rawget(_G, "LoopAsync")

    local function getPC() return firstLive("GothicPlayerController") or firstLive("PlayerController") end

    local G = rawget(_G, "__devprobe_gamepad")
    if not G then G = {}; rawset(_G, "__devprobe_gamepad", G) end

    -- read mapping[i].Key.KeyName -> string (or nil + an error tag for diagnostics)
    local function keyNameOf(m)
        local kn, e
        local ok, err = pcall(function()
            local fn = m.Key and m.Key.KeyName
            kn = fn and fn:ToString() -- FName userdata -> string (tostring gives the pointer)
        end)
        if not ok then e = "ERR:" .. tostring(err) end
        return kn, e
    end

    local function discover()
        local pc = getPC()
        if not isValid(pc) then log("discover: no PlayerController (be in-game)"); return end
        local ok, imcs = pcall(function() return FindAllOf("InputMappingContext") end)
        local nimc = (ok and imcs) and #imcs or 0
        log("discover: " .. nimc .. " InputMappingContext(s)")
        if not (ok and imcs) then return end

        local seen, found, detailed = {}, {}, 0
        for idx, imc in ipairs(imcs) do
            if isValid(imc) then
                local maps; local okM = pcall(function() maps = imc.Mappings end)
                local count = 0; if okM and maps then pcall(function() count = #maps end) end
                if count > 0 and detailed < 2 then -- deep-log the first couple so we see the shape
                    detailed = detailed + 1
                    log("  IMC " .. fullName(imc) .. " : " .. count .. " mappings")
                    for i = 1, math.min(count, 4) do
                        local okI, m = pcall(function() return maps[i] end)
                        if not okI then
                            log("    maps[" .. i .. "] INDEX ERR: " .. tostring(m))
                        else
                            local kn, e = keyNameOf(m)
                            log("    mapping[" .. i .. "] (type " .. type(m) .. ") -> KeyName="
                                .. tostring(kn) .. (e and ("  " .. e) or ""))
                        end
                    end
                end
                if okM and maps then
                    for i = 1, count do
                        local okI, m = pcall(function() return maps[i] end)
                        if okI and m ~= nil then
                            local kn = keyNameOf(m)
                            if kn then
                                seen[kn] = true
                                if string.find(kn, "Gamepad", 1, true) and not found[kn] then
                                    pcall(function() found[kn] = m.Key end)
                                end
                            end
                        end
                    end
                end
            end
        end

        local names = {}; for k in pairs(seen) do names[#names + 1] = k end; table.sort(names)
        local sample = {}; for i = 1, math.min(#names, 25) do sample[i] = names[i] end
        log("discover: " .. #names .. " unique key(s). sample: " .. table.concat(sample, ", "))

        local gp = {}; for kn in pairs(found) do gp[#gp + 1] = kn end; table.sort(gp)
        log("discover: gamepad keys: " .. (#gp > 0 and table.concat(gp, ", ") or "NONE"))
        local working = {}
        for _, kn in ipairs(gp) do
            local key = found[kn]
            local okD, down = pcall(function() return pc:IsInputKeyDown(key) end)
            local okA, ax = pcall(function() return pc:GetInputAnalogKeyState(key) end)
            log("  " .. kn .. " [real FKey] -> "
                .. (okD and ("down=" .. tostring(down)) or ("down:ERR " .. tostring(down))) .. ", "
                .. (okA and ("analog=" .. tostring(ax)) or ("analog:ERR " .. tostring(ax))))
            if okD or okA then working[kn] = key end
        end
        G.realKeys = working
        local nw = 0; for _ in pairs(working) do nw = nw + 1 end
        log("discover done. " .. nw .. " pollable. If a held button shows down=true / analog!=0, it works.")
    end

    local function scanOnce()
        local pc = getPC()
        if not isValid(pc) or not G.realKeys then return end
        local hits = {}
        for kn, key in pairs(G.realKeys) do
            local v
            if pcall(function() v = pc:IsInputKeyDown(key) end) and v == true then
                hits[#hits + 1] = kn
            else
                local av
                if pcall(function() av = pc:GetInputAnalogKeyState(key) end) and type(av) == "number" and math.abs(av) > 0.3 then
                    hits[#hits + 1] = kn .. "=" .. string.format("%.2f", av)
                end
            end
        end
        if #hits > 0 then log("INPUT: " .. table.concat(hits, "   ")) end
    end

    local function startScan()
        if not G.realKeys then log("scan: run F3 discover first"); return end
        G.scanning = true; G.gen = (tonumber(G.gen) or 0) + 1
        local myGen = G.gen
        log("SCAN ON. Press buttons / move sticks; F10 again to stop.")
        if type(LoopAsync) ~= "function" then log("LoopAsync missing"); G.scanning = false; return end
        LoopAsync(120, function()
            if not G.scanning or G.gen ~= myGen then return true end
            onGameThread(function() pcall(scanOnce) end)
            return false
        end)
    end
    local function toggleScan()
        if G.scanning then G.scanning = false; G.gen = (tonumber(G.gen) or 0) + 1; log("SCAN OFF")
        else startScan() end
    end

    return {
        name = "gamepad",
        keys = {
            { key = "F3",  desc = "discover real gamepad FKeys + test (hold a button)", fn = discover },
            { key = "F10", desc = "toggle scan of discovered keys", fn = toggleScan },
        },
    }
end
