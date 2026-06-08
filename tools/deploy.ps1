# Deploys a mod (or all mods) from the TautelliniMods repo into the live game
# folder, VENDORING the shared kit into each mod so every build is
# self-contained (no global Mods\shared dependency).
#
# Usage:
#   powershell -File tools\deploy.ps1 -Mod LockpickSettings
#   powershell -File tools\deploy.ps1 -Mod All
param(
    [Parameter(Mandatory = $true)]
    [string]$Mod,
    [string]$GameRoot = "C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake"
)

$ErrorActionPreference = "Stop"

$RepoRoot  = Split-Path $PSScriptRoot -Parent
$G1RDir    = Join-Path $RepoRoot "G1R"
$KitSource = Join-Path $G1RDir "shared\kit"
$ModsDir   = Join-Path $GameRoot "G1R\Binaries\Win64\ue4ss\Mods"

if (-not (Test-Path $ModsDir)) {
    throw "UE4SS Mods folder not found at $ModsDir. Is UE4SS installed?"
}
if (-not (Test-Path "$KitSource\kit.lua")) {
    throw "Shared kit not found at $KitSource (expected kit.lua)."
}

function Deploy-OneMod($name) {
    $sourceDir = Join-Path $G1RDir $name
    if (-not (Test-Path "$sourceDir\Scripts\main.lua")) {
        throw "No mod found at $sourceDir (expected Scripts\main.lua)"
    }
    $targetDir = Join-Path $ModsDir $name

    # 1. the mod's Scripts, RECURSIVELY (the subfolders core/util/data/features
    #    are required by dotted name; a non-recursive copy silently drops them).
    New-Item -ItemType Directory -Force "$targetDir\Scripts" | Out-Null
    Copy-Item "$sourceDir\Scripts\*" "$targetDir\Scripts\" -Recurse -Force

    # 2. vendor the shared kit under <Mod>\shared\kit\ (the *.lua files only;
    #    the kit's tests\ subfolder never ships). main.lua self-adds this dir to
    #    package.path, so require("kit") resolves it. Self-contained build.
    New-Item -ItemType Directory -Force "$targetDir\shared\kit" | Out-Null
    Copy-Item (Get-ChildItem -File "$KitSource\*.lua") -Destination "$targetDir\shared\kit\" -Force

    # 3. the enabled.txt activation marker (UE4SS starts any mod folder that has
    #    one; no mods.txt entry needed).
    if (Test-Path "$sourceDir\enabled.txt") {
        Copy-Item "$sourceDir\enabled.txt" "$targetDir\" -Force
    }

    $kitVer = (Get-Content "$KitSource\version.lua" | Select-String -Pattern '"([^"]+)"').Matches.Groups[1].Value
    Write-Host "Deployed $name -> $targetDir  (kit $kitVer vendored)"
}

if ($Mod -ieq "All") {
    Get-ChildItem -Directory $G1RDir | Where-Object {
        (Test-Path (Join-Path $_.FullName "Scripts\main.lua")) -and
        (Test-Path (Join-Path $_.FullName "enabled.txt"))
    } | ForEach-Object { Deploy-OneMod $_.Name }
} else {
    Deploy-OneMod $Mod
}

Write-Host "If the game is running, press CTRL+R ingame to hot-reload."
