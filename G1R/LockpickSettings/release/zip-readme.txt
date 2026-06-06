EasyLockpicking for Gothic 1 Remake
More tries before your lockpick breaks: 12/14/16 instead of vanilla 2/4/6,
scaling with your Picklock skill tier.

Requires UE4SS, experimental build (the game runs UE 5.4.3):
https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest

Install:
1. Install UE4SS into ...\Gothic 1 Remake\G1R\Binaries\Win64
   (dwmapi.dll next to G1R-Win64-Shipping.exe).
2. Copy the EasyLockpicking folder from this archive into
   ...\G1R\Binaries\Win64\ue4ss\Mods\
3. Add this line to ...\ue4ss\Mods\mods.txt (above the Keybinds entry):
   EasyLockpicking : 1
4. Start the game. ...\ue4ss\UE4SS.log should show:
   [EasyLockpicking] Loaded: untrained 2->12, trained 4->14, master 6->16

Configure: edit EasyLockpicking\Scripts\config.lua (extraTries = the bonus,
baseTries = vanilla tries per tier). Apply with a game restart or CTRL+R.

Uninstall: delete the EasyLockpicking folder or set its mods.txt entry to 0.
Lockpicking returns to vanilla behavior.

Source: https://github.com/Tautellini/TautelliniMods
