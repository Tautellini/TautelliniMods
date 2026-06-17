# tools/lockpicksettings_build_release.ps1
# Builds the LockpickSettings release artifacts from the single source tree:
#   <Mod>-<ver>-manual.zip    mod only; extract into ...\Win64\ue4ss\Mods
#   <Mod>-<ver>-complete.zip  mod + bundled UE4SS; extract into the GAME ROOT
#   <Mod>-<ver>-vortex.zip    mod only, foldered from the GAME ROOT
#                             (G1R\Binaries\Win64\ue4ss\Mods\<Mod>). Installs via
#                             Vortex's default installer, no FOMOD/custom script.
#                             UE4SS is NOT bundled (mod managers can't deploy the
#                             proxy DLL reliably); install it separately.
#
# UE4SS for the complete build comes from tools\ue4ss\ (gitignored: dwmapi.dll +
# the ue4ss\ folder, from a tested experimental install). Without it the complete
# zip is skipped; manual and vortex still build. tools\ue4ss.version (tracked)
# records the bundled build id (the DLL carries none).
#
# Usage: powershell -File tools\lockpicksettings_build_release.ps1

param(
    [string]$Mod = "LockpickSettings",
    [string]$OutDir = ""   # defaults to <Mod>\release\build; override to dodge a locked artifact
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$ModSrc     = Join-Path $RepoRoot "G1R\$Mod"
$ScriptsSrc = Join-Path $ModSrc "Scripts"
$KitSrc     = Join-Path $RepoRoot "G1R\shared\kit"
$UE4SSSrc   = Join-Path $PSScriptRoot "ue4ss"
$UE4SSVerF  = Join-Path $PSScriptRoot "ue4ss.version"
$UE4SSVer   = if (Test-Path $UE4SSVerF) { (Get-Content $UE4SSVerF -Raw).Trim() } else { "experimental" }
$ReadmeSrc  = Join-Path $ModSrc "bundled-readme.txt"
if (-not $OutDir) { $OutDir = Join-Path $ModSrc "release\build" }

if (-not (Test-Path "$ScriptsSrc\main.lua")) { throw "mod not found at $ModSrc (need Scripts\main.lua)" }

$ver = ([regex]'ModVersion = "([^"]+)"').Match((Get-Content "$ScriptsSrc\main.lua" -Raw)).Groups[1].Value
if (-not $ver) { throw "could not read ModVersion from main.lua" }

# game-root-relative install paths
$Win64   = "G1R\Binaries\Win64"

$haveUE4SS = (Test-Path (Join-Path $UE4SSSrc "dwmapi.dll")) -and (Test-Path (Join-Path $UE4SSSrc "ue4ss"))
if (-not $haveUE4SS) {
    Write-Warning "tools\ue4ss\ not populated (need dwmapi.dll + ue4ss\); the complete zip is skipped."
}

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$work = Join-Path $OutDir "_stage"

function New-Stage([string]$name) {
    $p = Join-Path $work $name
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    New-Item -ItemType Directory -Force $p | Out-Null
    return $p
}

# Stage the mod as <parent>\<Mod>\... (Scripts recursively, the vendored kit,
# enabled.txt, readme). Release builds flip debugSolver OFF in the STAGED config
# (the source stays ON for verbose dev logs); it logs synchronously on the game
# thread, so it adds latency during lock interactions.
function Copy-ModPayload([string]$parent) {
    $dest = Join-Path $parent $Mod
    New-Item -ItemType Directory -Force (Join-Path $dest "Scripts") | Out-Null
    Copy-Item "$ScriptsSrc\*" (Join-Path $dest "Scripts") -Recurse -Force
    $cfgPath = Join-Path $dest "Scripts\config.lua"
    $cfg = [regex]::Replace((Get-Content $cfgPath -Raw),
        'debugSolver\s*=\s*(?:true|false)', 'debugSolver = false')
    [System.IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Force (Join-Path $dest "shared\kit") | Out-Null
    Copy-Item (Get-ChildItem -File "$KitSrc\*.lua") -Destination (Join-Path $dest "shared\kit") -Force
    if (Test-Path "$ModSrc\enabled.txt") { Copy-Item "$ModSrc\enabled.txt" $dest -Force }
    if (Test-Path $ReadmeSrc) { Copy-Item $ReadmeSrc (Join-Path $dest "readme.txt") -Force }
}

function Copy-UE4SS([string]$win64Dir) {
    New-Item -ItemType Directory -Force $win64Dir | Out-Null
    Copy-Item "$UE4SSSrc\*" $win64Dir -Recurse -Force
    Write-Lua (Join-Path $win64Dir "ue4ss\UE4SS-VERSION.txt") "RE-UE4SS $UE4SSVer  (bundled with $Mod $ver)`r`n"
}

function Write-Lua([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# Add entries by hand so separators are forward slashes (CreateFromDirectory on
# PS 5.1 writes backslashes, which the zip spec and Vortex reject).
function Zip([string]$stageDir, [string]$zipName) {
    $zip = Join-Path $OutDir $zipName
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $base = (Resolve-Path $stageDir).Path.TrimEnd('\') + '\'
    $archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in (Get-ChildItem -Recurse -File $stageDir)) {
            $rel = $f.FullName.Substring($base.Length).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $rel) | Out-Null
        }
    } finally { $archive.Dispose() }
    Write-Host ("  {0,-40} {1,10:N0} bytes" -f $zipName, (Get-Item $zip).Length)
}

Write-Host "Building $Mod $ver  (UE4SS bundled: $(if ($haveUE4SS) { $UE4SSVer } else { 'no' }))`n"

# ---- 1. manual.zip : mod only, extract into ue4ss\Mods ----
$s = New-Stage "manual"
Copy-ModPayload $s
Zip $s "$Mod-$ver-manual.zip"

# ---- 2. complete.zip : mod + UE4SS, extract into the game root ----
if ($haveUE4SS) {
    $s = New-Stage "complete"
    $completeWin64 = Join-Path $s $Win64
    Copy-UE4SS $completeWin64
    $modsParent = Join-Path $completeWin64 "ue4ss\Mods"
    New-Item -ItemType Directory -Force $modsParent | Out-Null
    Copy-ModPayload $modsParent
    Zip $s "$Mod-$ver-complete.zip"
}

# ---- 3. vortex.zip : mod only, foldered from the game root (no FOMOD) ----
# The zip root is G1R\Binaries\Win64\ue4ss\Mods\<Mod>\..., the path Vortex deploys
# to the game root, so Vortex's default installer drops the mod in the right place
# with no custom install script.
$s = New-Stage "vortex"
$vortexMods = Join-Path $s "$Win64\ue4ss\Mods"
New-Item -ItemType Directory -Force $vortexMods | Out-Null
Copy-ModPayload $vortexMods
Zip $s "$Mod-$ver-vortex.zip"

Remove-Item -Recurse -Force $work
Write-Host "`nArtifacts in $OutDir"
