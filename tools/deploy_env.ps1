# tools/deploy_env.ps1
# Sets the live game folder into one of two known environments and deploys the
# mod into it. Reuses tools\deploy.ps1 for the actual mod copy + kit vendoring.
#
#   -Mode dev    full debugging/investigation: text log + GUI console + hot
#                reload, every investigation hook on, all dev mods on, and
#                (with -Probes) the TautelliniDevProbe deployed. debugSolver stays on.
#   -Mode smoke  the CONSUMER environment for release verification: consumer
#                UE4SS settings with only the log window open (no GUI console, no
#                hot reload), ONLY LockpickSettings active (all dev mods and our
#                probes off), and the mod's debugSolver turned off for a clean log.
#                Add -FullUE4SS to also lay down the bundled UE4SS binary (an
#                exact "ships-this" test); the game must be closed for that.
#
# The settings file is rebuilt each run from the bundled consumer base
# (tools\ue4ss) plus the per-mode overrides below, so this script OWNS
# UE4SS-settings.ini and mods.txt. The originals are backed up once to
# tools\.env-backup\ (gitignored) so nothing is ever lost.
#
# Usage:
#   powershell -File tools\deploy_env.ps1 -Mode dev
#   powershell -File tools\deploy_env.ps1 -Mode smoke              (then restart)
#   powershell -File tools\deploy_env.ps1 -Mode smoke -FullUE4SS   (close game first)
#   powershell -File tools\deploy_env.ps1 -Mode dev -DryRun        (print, change nothing)

param(
    [ValidateSet('dev', 'smoke')][string]$Mode = 'dev',
    [string]$Mod = 'LockpickSettings',
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake',
    [switch]$FullUE4SS,
    [switch]$Probes,
    [switch]$GuiConsole,   # dev: opt in to UE4SS's ImGui overlay (see caveat below)
    [switch]$HotReload,    # dev: opt in to CTRL+R hot reload
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------- knobs ----
# Per-mode UE4SS-settings.ini overrides (applied on top of the bundled consumer
# base). The dev defaults MATCH the proven working dev env: the text log + every
# investigation hook, but the ImGui GUI overlay and hot reload OFF.
#   - GuiConsoleEnabled (the ImGui overlay) hooks D3D present and can interact
#     with Frame Generation, which has caused GPU freezes here; enable it only
#     when you need live object inspection, with -GuiConsole (and FG off).
#   - EnableHotReloadSystem (CTRL+R) re-runs main.lua and re-registers hooks,
#     which accumulate per reload; full restart is safer. Opt in with -HotReload.
$DevOverrides = [ordered]@{ ConsoleEnabled = 1; GuiConsoleEnabled = 0; EnableHotReloadSystem = 0 }
$SmokeOverrides = [ordered]@{ ConsoleEnabled = 1; GuiConsoleEnabled = 0; EnableHotReloadSystem = 0 }
if ($GuiConsole) { $DevOverrides['GuiConsoleEnabled'] = 1 }
if ($HotReload) { $DevOverrides['EnableHotReloadSystem'] = 1 }
# hooks the investigations rely on; ensured =1 in dev (the consumer base already
# carries the few the shipped mod needs)
$InvestigationHooks = @(
    'HookProcessInternal', 'HookProcessLocalScriptFunction', 'HookInitGameState',
    'HookLoadMap', 'HookCallFunctionByNameWithArguments', 'HookBeginPlay',
    'HookEndPlay', 'HookLocalPlayerExec', 'HookAActorTick', 'HookEngineTick',
    'HookGameViewportClientTick', 'HookUObjectProcessEvent', 'HookProcessConsoleExec',
    'HookUStructLink'
)
# our consolidated dev probe; removed from the live folder in smoke so only the mod runs
$OurProbes = @('TautelliniDevProbe')

$DevModsTxt = @'
ActorDumperMod : 1
BPML_GenericFunctions : 1
BPModLoaderMod : 1
CheatManagerEnablerMod : 1
ConsoleCommandsMod : 1
ConsoleEnablerMod : 1
EventViewerMod : 1
Keybinds : 1
KismetDebuggerMod : 1
LineTraceMod : 1
LockpickSettings : 1
SplitScreenMod : 1
jsbLuaProfilerMod : 1
shared : 1
'@

$SmokeModsTxt = @'
; consumer set + the mod under test. Dev / investigation mods explicitly OFF so a
; smoke test reflects what an end user actually runs.
BPModLoaderMod : 1
BPML_GenericFunctions : 1
Keybinds : 1
ConsoleEnablerMod : 1
ConsoleCommandsMod : 1
CheatManagerEnablerMod : 1
LockpickSettings : 1
ActorDumperMod : 0
EventViewerMod : 0
KismetDebuggerMod : 0
jsbLuaProfilerMod : 0
LineTraceMod : 0
SplitScreenMod : 0
shared : 1
'@

# ----------------------------------------------------------------- paths ----
$RepoRoot = Split-Path $PSScriptRoot -Parent
$Win64 = Join-Path $GameRoot 'G1R\Binaries\Win64'
$UE4SSDir = Join-Path $Win64 'ue4ss'
$SettingsPath = Join-Path $UE4SSDir 'UE4SS-settings.ini'
$ModsTxt = Join-Path $UE4SSDir 'Mods\mods.txt'
$ModsDir = Join-Path $UE4SSDir 'Mods'
$BundledUE4SS = Join-Path $PSScriptRoot 'ue4ss'
$BundledSettings = Join-Path $BundledUE4SS 'ue4ss\UE4SS-settings.ini'
$BundledUE4SSVerF = Join-Path $PSScriptRoot 'ue4ss.version'
$BundledUE4SSVer = if (Test-Path $BundledUE4SSVerF) { (Get-Content $BundledUE4SSVerF -Raw).Trim() } else { 'experimental' }
$BackupDir = Join-Path $PSScriptRoot '.env-backup'

if (-not (Test-Path $UE4SSDir)) { throw "UE4SS not found at $UE4SSDir. Is the game/UE4SS installed at -GameRoot?" }
if (-not (Test-Path $BundledSettings)) { throw "Bundled consumer UE4SS settings not found at $BundledSettings (populate tools\ue4ss\)." }

# ----------------------------------------------------------------- helpers ----
function Do-Or-Say([string]$msg, [scriptblock]$action) {
    if ($DryRun) { Write-Host "  [dry] $msg" } else { Write-Host "  $msg"; & $action }
}

# Set one ini key in-place, preserving every other line; append if absent.
function Set-IniKey([string]$Path, [string]$Key, [string]$Value) {
    $text = Get-Content -Raw -LiteralPath $Path
    $pat = "(?m)^(\s*$([regex]::Escape($Key))\s*=).*$"
    if ($text -match $pat) { $text = [regex]::Replace($text, $pat, ('${1} ' + $Value)) }
    else { $text = $text.TrimEnd() + "`r`n$Key = $Value`r`n" }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Backup-Once([string]$src) {
    if (-not (Test-Path $src)) { return }
    $dest = Join-Path $BackupDir (Split-Path $src -Leaf)
    if (Test-Path $dest) { return }   # keep the FIRST (original) backup only
    Do-Or-Say "backup $([System.IO.Path]::GetFileName($src)) -> tools\.env-backup\" {
        New-Item -ItemType Directory -Force $BackupDir | Out-Null
        Copy-Item $src $dest -Force
    }
}

$gameRunning = [bool](Get-Process -Name 'G1R-Win64-Shipping' -ErrorAction SilentlyContinue)

Write-Host "deploy_env: $Mode$(if($DryRun){' (dry run)'})  ->  $UE4SSDir"
if ($gameRunning) { Write-Host "  note: the game is running; binary swaps are skipped, settings/mods apply on next launch or CTRL+R" }

# --------------------------------------------------------------- 1. backup ----
Backup-Once $SettingsPath
Backup-Once $ModsTxt
if ($FullUE4SS) { Backup-Once (Join-Path $Win64 'dwmapi.dll'); Backup-Once (Join-Path $UE4SSDir 'UE4SS.dll') }

# ------------------------------------------------ 2. UE4SS-settings.ini ----
# rebuild from the consumer base, then apply the mode overrides
$overrides = if ($Mode -eq 'dev') { $DevOverrides } else { $SmokeOverrides }
Do-Or-Say "write UE4SS-settings.ini from consumer base" { Copy-Item $BundledSettings $SettingsPath -Force }
foreach ($k in $overrides.Keys) {
    Do-Or-Say "  set $k = $($overrides[$k])" { Set-IniKey $SettingsPath $k $overrides[$k] }
}
if ($Mode -eq 'dev') {
    foreach ($h in $InvestigationHooks) {
        Do-Or-Say "  ensure $h = 1" { Set-IniKey $SettingsPath $h 1 }
    }
}

# ----------------------------------------------------------- 3. mods.txt ----
$modsContent = if ($Mode -eq 'dev') { $DevModsTxt } else { $SmokeModsTxt }
Do-Or-Say "write mods.txt ($Mode set)" {
    [System.IO.File]::WriteAllText($ModsTxt, ($modsContent -replace "`r?`n", "`r`n").TrimEnd() + "`r`n",
        (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------ 4. our probe mods ----
if ($Mode -eq 'smoke') {
    foreach ($p in $OurProbes) {
        $pd = Join-Path $ModsDir $p
        if (Test-Path $pd) { Do-Or-Say "remove probe $p (smoke is mod-only)" { Remove-Item -Recurse -Force $pd } }
    }
} elseif ($Probes) {
    Do-Or-Say "deploy TautelliniDevProbe (dev -Probes)" {
        & (Join-Path $PSScriptRoot 'deploy.ps1') -Mod 'TautelliniDevProbe' -GameRoot $GameRoot | Out-Null
    }
}

# -------------------------------------- 5. bundled UE4SS binary (opt-in) ----
if ($FullUE4SS) {
    if ($gameRunning) {
        Write-Warning "  -FullUE4SS skipped: close the game first (UE4SS.dll/dwmapi.dll are locked while it runs)."
    } else {
        Do-Or-Say "lay down bundled UE4SS binary v$BundledUE4SSVer (dwmapi.dll + UE4SS.dll)" {
            Copy-Item (Join-Path $BundledUE4SS 'dwmapi.dll') (Join-Path $Win64 'dwmapi.dll') -Force
            Copy-Item (Join-Path $BundledUE4SS 'ue4ss\UE4SS.dll') (Join-Path $UE4SSDir 'UE4SS.dll') -Force
        }
    }
}

# ----------------------------------------------------------- 6. the mod ----
Do-Or-Say "deploy $Mod via deploy.ps1" {
    & (Join-Path $PSScriptRoot 'deploy.ps1') -Mod $Mod -GameRoot $GameRoot | Out-Null
}
# smoke: quiet the verbose solver trace so the log shows only banner + key events
if ($Mode -eq 'smoke') {
    $cfg = Join-Path $ModsDir "$Mod\Scripts\config.lua"
    if (Test-Path $cfg) {
        Do-Or-Say "set debugSolver = false (clean consumer log)" {
            $t = Get-Content -Raw $cfg
            $t = [regex]::Replace($t, 'debugSolver\s*=\s*(?:true|false)', 'debugSolver = false')
            [System.IO.File]::WriteAllText($cfg, $t, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
}

Write-Host ""
if ($Mode -eq 'dev') {
    $extras = @(); if ($GuiConsole) { $extras += 'GUI console' }; if ($HotReload) { $extras += 'hot reload' }
    $extraStr = if ($extras.Count) { ' + ' + ($extras -join ' + ') } else { '' }
    Write-Host "Done (dev). Debug env: text log + all investigation hooks + all dev mods$extraStr."
    if (-not $GuiConsole) { Write-Host "  (GUI overlay off; add -GuiConsole to enable it, with Frame Generation off.)" }
} else {
    Write-Host "Done (smoke). Consumer env: log window only, LockpickSettings only, dev mods off, debugSolver off."
}
if (-not $DryRun) { Write-Host "Restart the game (or CTRL+R if hot reload is on) to load this environment." }
