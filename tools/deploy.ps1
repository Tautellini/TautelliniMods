# Deploys a mod from the TautelliniMods repo into the live game folder.
# Usage:  powershell -File tools\deploy.ps1 -Mod LockpickSettings
param(
    [Parameter(Mandatory = $true)]
    [string]$Mod,
    [string]$GameRoot = "C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake"
)

$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$SourceDir  = Join-Path $RepoRoot "G1R\$Mod"
$ModsDir    = Join-Path $GameRoot "G1R\Binaries\Win64\ue4ss\Mods"
$TargetDir  = Join-Path $ModsDir $Mod

if (-not (Test-Path "$SourceDir\Scripts\main.lua")) {
    throw "No mod found at $SourceDir (expected Scripts\main.lua)"
}
if (-not (Test-Path $ModsDir)) {
    throw "UE4SS Mods folder not found at $ModsDir. Is UE4SS installed?"
}

# Copy the deployable payload: Scripts plus the enabled.txt activation
# marker (UE4SS starts any mod folder that contains enabled.txt, so no
# mods.txt entry is needed). Docs/specs stay in the repo.
New-Item -ItemType Directory -Force "$TargetDir\Scripts" | Out-Null
Copy-Item "$SourceDir\Scripts\*" "$TargetDir\Scripts\" -Force
if (Test-Path "$SourceDir\enabled.txt") {
    Copy-Item "$SourceDir\enabled.txt" "$TargetDir\" -Force
}

Write-Host "Deployed $Mod -> $TargetDir"
Write-Host "If the game is running, press CTRL+R ingame to hot-reload."
