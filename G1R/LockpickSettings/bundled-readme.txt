LockpickSettings for Gothic 1 Remake

Features (all but the durability boost are off by default; keys configurable):
1. More durability: extra tries per skill tier (default 7/14/26 vs vanilla 2/4/6).
2. Next-move hint (F7): the piece to move next lights up (green = turn left,
   blue = turn right), recomputed each move. Keyboard and controller.
3. Connection display (F8): the selected piece's partners light up (purple = same
   direction, red = opposite), matching your lockpicking precision.
4. Auto-solve (F6): solves the current lock in a couple of seconds (F6 again
   cancels). Shift+F6 toggles full-auto on every lock. Still earns the achievement.

Requires UE4SS (experimental build; the game runs UE 5.4.3):
https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest

Install:
1. Install UE4SS into ...\Gothic 1 Remake\G1R\Binaries\Win64
   (dwmapi.dll next to G1R-Win64-Shipping.exe).
2. Copy the LockpickSettings folder into ...\G1R\Binaries\Win64\ue4ss\Mods\
   (the included enabled.txt activates it; no mods.txt edit needed).
3. Start the game; ...\ue4ss\UE4SS.log shows a "[LockpickSettings] Loaded" line.

The lock data ships with the mod, so it works offline but is NOT auto-compatible
with a new game version or other lock-changing mods (those need a mod update).

Configure: edit LockpickSettings\Scripts\config.lua (each setting is documented
there). Changes apply on a game restart. Values you change in the SharedModMenu or
via the hotkeys are saved to saved_settings.lua and override config.lua; delete that
file to reset.

Uninstall: delete the LockpickSettings folder (or just its enabled.txt to keep it
inactive). Everything returns to vanilla.

Source: https://github.com/Tautellini/TautelliniMods
