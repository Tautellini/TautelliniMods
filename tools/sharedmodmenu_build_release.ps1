# tools/sharedmodmenu_build_release.ps1
# Builds the release artifacts for SharedModMenu, or any simple Lua mod, from the single source
# tree. Mirrors deploy.ps1's vendoring: a mod marked with a .nokit file ships the standalone
# bridge as Scripts\modmenu.lua (no shared kit); any other mod vendors the full kit.
#
#   <Mod>-<ver>-manual.zip   the mod; extract into ...\Win64\ue4ss\Mods so you get Mods\<Mod>\...
#   modmenu.lua              (.nokit mods only) the standalone integration file, for authors to
#                            grab without unzipping
#
# Output: G1R\<Mod>\release\<ver>\ (only the generated artifacts are overwritten; hand-written
# notes in that folder are left alone). Version is read from the mod's main.lua ModVersion.
#
# Usage: powershell -File tools\sharedmodmenu_build_release.ps1 [-Mod SharedModMenu]

param([string]$Mod = "SharedModMenu")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ModSrc   = Join-Path $RepoRoot "G1R\$Mod"
$KitSrc   = Join-Path $RepoRoot "G1R\shared\kit"
if (-not (Test-Path "$ModSrc\Scripts\main.lua")) { throw "mod not found at $ModSrc (need Scripts\main.lua)" }

$ver = ([regex]'ModVersion = "([^"]+)"').Match((Get-Content "$ModSrc\Scripts\main.lua" -Raw)).Groups[1].Value
if (-not $ver) { throw "could not read ModVersion from $Mod's main.lua" }
$nokit  = Test-Path "$ModSrc\.nokit"
$OutDir = Join-Path $ModSrc "release\$ver"
New-Item -ItemType Directory -Force $OutDir | Out-Null

# stage <Mod>\... in TEMP (kept off the repo tree)
$stage = Join-Path $env:TEMP ("rel_" + [guid]::NewGuid().ToString("N"))
$ms    = Join-Path $stage $Mod
New-Item -ItemType Directory -Force "$ms\Scripts" | Out-Null
Copy-Item "$ModSrc\Scripts\*" "$ms\Scripts\" -Recurse -Force
if ($nokit) {
    Copy-Item "$KitSrc\menu.lua" "$ms\Scripts\modmenu.lua" -Force
} else {
    New-Item -ItemType Directory -Force "$ms\shared\kit" | Out-Null
    Copy-Item (Get-ChildItem -File "$KitSrc\*.lua") -Destination "$ms\shared\kit" -Force
}
if (Test-Path "$ModSrc\enabled.txt") { Copy-Item "$ModSrc\enabled.txt" $ms -Force }
if (Test-Path "$ModSrc\README.md")   { Copy-Item "$ModSrc\README.md" $ms -Force }

# zip with forward-slash entries (CreateFromDirectory on PS 5.1 writes backslashes, which some
# tools reject); the <Mod>\ folder is the zip root so it extracts straight into Mods\.
$zip = Join-Path $OutDir "$Mod-$ver-manual.zip"
if (Test-Path $zip) { [System.IO.File]::Delete($zip) }
$base = (Resolve-Path $stage).Path.TrimEnd('\') + '\'
$ar = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in (Get-ChildItem -Recurse -File $stage)) {
        $rel = $f.FullName.Substring($base.Length).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ar, $f.FullName, $rel) | Out-Null
    }
} finally { $ar.Dispose() }

if ($nokit) { Copy-Item "$KitSrc\menu.lua" (Join-Path $OutDir "modmenu.lua") -Force }
[System.IO.Directory]::Delete($stage, $true)

Write-Host "Built $Mod $ver  ($(if ($nokit) { 'kit-free + modmenu.lua' } else { 'kit vendored' }))  -> $OutDir"
Get-ChildItem $OutDir -File | ForEach-Object { Write-Host ("  {0,-34} {1,9:N0} bytes" -f $_.Name, $_.Length) }
