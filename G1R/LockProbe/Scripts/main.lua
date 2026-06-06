-- LockProbe v18: dev-only exploration mod, NOT for shipping.
-- THE selection question, possibly final round. The task's input
-- handlers (UpPressed/DownPressed/LeftPressed/RightPressed) are called
-- by the ENGINE INPUT DISPATCH (UFunction route, hookable per the
-- ClientRestart precedent), not by AngelScript's direct binding table
-- (the path that made AddPiece/AddConnection hooks blind in v7).
-- If these hooks fire on player input, selection tracking becomes
-- device-independent: keyboard AND CONTROLLER trigger the same handler.
-- Usage: open a minigame, press up/down/left/right with KEYBOARD, then
-- with CONTROLLER if available. Watch the log for "HOOK FIRED" lines.
-- No keybinds, no polling; hooks only, all registration pcall'd.

local function log(msg)
    print("[LockProbe] " .. tostring(msg) .. "\n")
end

local counts = {}

for _, fn in ipairs({ "UpPressed", "DownPressed", "LeftPressed", "RightPressed" }) do
    counts[fn] = 0
    local ok, err = pcall(RegisterHook, "/Script/G1R.AbilityTask_LockPick:" .. fn,
        function()
            counts[fn] = counts[fn] + 1
            log("HOOK FIRED: " .. fn .. " (#" .. counts[fn] .. ")")
        end)
    log(fn .. " hook: " .. (ok and "registered" or ("FAILED: " .. tostring(err))))
end

log("v18 loaded. Open a lock, press inputs (keyboard AND controller), "
    .. "watch for HOOK FIRED lines.")
