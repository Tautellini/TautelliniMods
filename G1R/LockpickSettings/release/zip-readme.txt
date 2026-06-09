LockpickSettings for Gothic 1 Remake
1. More tries before your lockpick breaks: 12/14/16 instead of vanilla
   2/4/6, scaling with your Picklock skill tier.
2. Optional next-move hint: press F7 during the minigame and the piece
   to move next lights up (green = turn it left, blue = turn it right),
   recomputed after every move. The colors calibrate themselves from
   your first move. Works with keyboard and controller. Off by default.
3. Optional connection display: press F8 and the pieces connected to
   your currently selected piece light up (purple = moves the same
   direction as the selected piece, red = moves opposite). Shows the
   authored layout: connections the game removed at runtime (skill,
   master perk) keep showing until one of your moves disproves them.
   Off by default.
4. Optional auto-solve: press F6 and the mod plays the next move for
   you; press Shift+F6 to run full auto and clear the whole lock,
   stopping by itself the moment it opens (Shift+F6 again cancels). It
   moves as fast as each press is honored and re-plans if a move is
   refused. Ctrl+F6 is an EXPERIMENTAL "super fast" mode that solves
   almost instantly. Auto-solve still earns the lockpicking achievement.
   Needs the next-move feature; the keys are configurable.

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
   [LockpickSettings] Loaded 3.0.8 (kit 1.0.0): untrained 2->12, trained 4->14,
   master 6->16, next-move hint off (416 lock graphs from bundled, toggle: F7),
   connection display off, toggle: F8, auto-solve: F6 step, SHIFT+F6 full-auto,
   CONTROL+F6 fast
   The lock graphs ship with the mod ("from bundled"). This makes the mod
   independent of the game build at runtime, but it is NOT automatically
   compatible with a new game version or with other mods that change lock
   layouts; those need a mod update.

Configure: edit LockpickSettings\Scripts\config.lua (extraTries = the
bonus added on top of the vanilla 2/4/6, giving 12/14/16 by default;
showNextMove /
showConnections = the assists' state at game start, nextMoveHotkey /
connectionsHotkey = the toggle keys, autoSolveStepHotkey /
autoSolveFullHotkey / autoSolveFullModifier = the auto-solve keys,
hintColorLeft / hintColorRight /
partnerColorSame / partnerColorOpposite = the colors). debugSolver
defaults to on so bug reports include a full solver trace in
UE4SS.log; set debugSolver = false for quiet play (it will likely
default to off in a later release). Apply
changes with a game restart or CTRL+R. Both
assists can be toggled at any time, even mid-pick: the mod follows
every lock from its start, the keys only switch the highlights.

Uninstall: delete the LockpickSettings folder, or just its enabled.txt
file to keep the mod around but inactive. Everything returns to vanilla
behavior.

Source: https://github.com/Tautellini/TautelliniMods
