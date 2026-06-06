LockpickSettings for Gothic 1 Remake
1. More tries before your lockpick breaks: 12/14/16 instead of vanilla
   2/4/6, scaling with your Picklock skill tier.
2. Optional next-move hint: press F7 during the minigame and the piece
   to move next is tinted green, recomputed after every move. Works
   with keyboard and controller. Off by default.

Requires UE4SS, experimental build (the game runs UE 5.4.3):
https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest

Install:
1. Install UE4SS into ...\Gothic 1 Remake\G1R\Binaries\Win64
   (dwmapi.dll next to G1R-Win64-Shipping.exe).
2. Copy the LockpickSettings folder from this archive into
   ...\G1R\Binaries\Win64\ue4ss\Mods\
   The included enabled.txt activates the mod automatically;
   no mods.txt editing is needed.
3. Start the game. ...\ue4ss\UE4SS.log should show:
   [LockpickSettings] Loaded: untrained 2->12, trained 4->14,
   master 6->16, next-move hint off (416 lock graphs, toggle: F7)

Configure: edit LockpickSettings\Scripts\config.lua (extraTries = the
bonus, baseTries = vanilla tries per tier, showNextMove = hint state at
game start, nextMoveHotkey = the toggle key). Apply with a game restart
or CTRL+R. Tip: activate the hint at the START of a lock, the mod
cannot know moves made before activation.

Uninstall: delete the LockpickSettings folder, or just its enabled.txt
file to keep the mod around but inactive. Everything returns to vanilla
behavior.

Source: https://github.com/Tautellini/TautelliniMods
