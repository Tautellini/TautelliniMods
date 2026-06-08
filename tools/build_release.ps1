# tools/build_release.ps1
# Builds the release artifacts for a mod from the single source tree:
#
#   <Mod>-<ver>-manual.zip    mod only; extract into ...\Win64\ue4ss\Mods
#   <Mod>-<ver>-complete.zip  mod + bundled UE4SS; extract into the GAME ROOT
#   <Mod>-<ver>-vortex.zip    FOMOD installer (Vortex/MO2): hero image, config
#                             presets, installs UE4SS only if it is missing
#
# Layout is "copy-paste into the game root": every install path is relative to
# the game root (...\Gothic 1 Remake), e.g. G1R\Binaries\Win64\ue4ss\Mods\<Mod>.
# Vortex deploys G1R mods to the game root, so the FOMOD destinations match.
#
# UE4SS for the complete/vortex builds is read from tools\ue4ss\ (gitignored;
# populate it from a tested experimental UE4SS install: dwmapi.dll plus the
# ue4ss\ folder). Without it, the manual zip and a UE4SS-less FOMOD still build.
#
# Usage: powershell -File tools\build_release.ps1 [-Mod LockpickSettings]

param(
    [string]$Mod = "LockpickSettings"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$ModSrc     = Join-Path $RepoRoot "G1R\$Mod"
$ScriptsSrc = Join-Path $ModSrc "Scripts"
$KitSrc     = Join-Path $RepoRoot "G1R\shared\kit"
$UE4SSSrc   = Join-Path $PSScriptRoot "ue4ss"
$ReadmeSrc  = Join-Path $ModSrc "release\zip-readme.txt"
$HeroSrc    = Join-Path $ModSrc "nexus-page\images\hero.png"
$WarnSrc    = Join-Path $ModSrc "nexus-page\images\fomod-ue4ss-warning.png"
$OutDir     = Join-Path $ModSrc "release\build"

if (-not (Test-Path "$ScriptsSrc\main.lua")) { throw "mod not found at $ModSrc (need Scripts\main.lua)" }

$ver = ([regex]'ModVersion = "([^"]+)"').Match((Get-Content "$ScriptsSrc\main.lua" -Raw)).Groups[1].Value
if (-not $ver) { throw "could not read ModVersion from main.lua" }

# game-root-relative install paths
$Win64   = "G1R\Binaries\Win64"
$ModDest = "$Win64\ue4ss\Mods\$Mod"

$haveUE4SS = (Test-Path (Join-Path $UE4SSSrc "dwmapi.dll")) -and (Test-Path (Join-Path $UE4SSSrc "ue4ss"))
if (-not $haveUE4SS) {
    Write-Warning "tools\ue4ss\ not populated (need dwmapi.dll + ue4ss\). The complete zip is skipped and the FOMOD will not bundle UE4SS."
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

# Stage the mod payload as <parent>\<Mod>\... (Scripts recursively, the vendored
# kit, enabled.txt, readme). withConfig=$false drops config.lua (the FOMOD picks
# a preset variant for it).
function Copy-ModPayload([string]$parent, [bool]$withConfig) {
    $dest = Join-Path $parent $Mod
    New-Item -ItemType Directory -Force (Join-Path $dest "Scripts") | Out-Null
    Copy-Item "$ScriptsSrc\*" (Join-Path $dest "Scripts") -Recurse -Force
    if (-not $withConfig) { Remove-Item (Join-Path $dest "Scripts\config.lua") -Force }
    New-Item -ItemType Directory -Force (Join-Path $dest "shared\kit") | Out-Null
    Copy-Item (Get-ChildItem -File "$KitSrc\*.lua") -Destination (Join-Path $dest "shared\kit") -Force
    if (Test-Path "$ModSrc\enabled.txt") { Copy-Item "$ModSrc\enabled.txt" $dest -Force }
    if (Test-Path $ReadmeSrc) { Copy-Item $ReadmeSrc (Join-Path $dest "readme.txt") -Force }
}

function Copy-UE4SS([string]$win64Dir) {
    New-Item -ItemType Directory -Force $win64Dir | Out-Null
    Copy-Item "$UE4SSSrc\*" $win64Dir -Recurse -Force
}

function Write-Lua([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Zip([string]$stageDir, [string]$zipName) {
    $zip = Join-Path $OutDir $zipName
    if (Test-Path $zip) { Remove-Item $zip -Force }
    # Add entries by hand so separators are forward slashes. CreateFromDirectory
    # on .NET Framework (PS 5.1) writes backslashes, which the zip spec and Vortex
    # reject, the FOMOD would not be detected.
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

# the installer-exposed config options (everything else stays in config.lua)
$triesOpts = 5, 10, 15, 20
$bools = @($false, $true)

# Generate a config.lua variant by substituting the exposed values in the base.
function New-ConfigVariant([string]$baseText, [int]$tries, [bool]$hint, [bool]$conn) {
    $t = $baseText
    $t = [regex]::Replace($t, 'extraTries\s*=\s*\d+', "extraTries = $tries")
    $t = [regex]::Replace($t, 'showNextMove\s*=\s*(?:true|false)', "showNextMove = " + $hint.ToString().ToLower())
    $t = [regex]::Replace($t, 'showConnections\s*=\s*(?:true|false)', "showConnections = " + $conn.ToString().ToLower())
    return $t
}

Write-Host "Building $Mod $ver  (UE4SS bundled: $haveUE4SS)`n"

# ---- 1. manual.zip : mod only, extract into ue4ss\Mods ----
$s = New-Stage "manual"
Copy-ModPayload $s $true
Zip $s "$Mod-$ver-manual.zip"

# ---- 2. complete.zip : mod + UE4SS, extract into the game root ----
if ($haveUE4SS) {
    $s = New-Stage "complete"
    # NOTE: do not name this $win64; PowerShell vars are case-insensitive and it
    # would clobber the relative $Win64 the FOMOD generation below relies on.
    $completeWin64 = Join-Path $s $Win64
    Copy-UE4SS $completeWin64
    $modsParent = Join-Path $completeWin64 "ue4ss\Mods"
    New-Item -ItemType Directory -Force $modsParent | Out-Null
    Copy-ModPayload $modsParent $true
    Zip $s "$Mod-$ver-complete.zip"
}

# ---- 3. vortex.zip : FOMOD (hero image, config presets, conditional UE4SS) ----
$s = New-Stage "vortex"
$fomod = Join-Path $s "fomod"
New-Item -ItemType Directory -Force (Join-Path $fomod "images") | Out-Null
if (Test-Path $HeroSrc) {
    Copy-Item $HeroSrc (Join-Path $fomod "images\hero.png") -Force
} else {
    Write-Warning "hero image not found at $HeroSrc; the FOMOD wizard will show a broken image"
}
if (Test-Path $WarnSrc) {
    Copy-Item $WarnSrc (Join-Path $fomod "images\warning.png") -Force
} elseif ($haveUE4SS) {
    Write-Warning "UE4SS warning image not found at $WarnSrc; the UE4SS page will show no image"
}

# mod payload WITH the default config.lua under mod\<Mod>; a chosen preset
# overwrites config.lua below, and the mod is required-installed so it always
# lands even if the optional config/UE4SS choices do nothing.
Copy-ModPayload (Join-Path $s "mod") $true

# config preset variants under configs\
$configsDir = Join-Path $s "configs"
New-Item -ItemType Directory -Force $configsDir | Out-Null
$baseConfig = Get-Content "$ScriptsSrc\config.lua" -Raw
foreach ($t in $triesOpts) { foreach ($h in $bools) { foreach ($c in $bools) {
    $fname = "config_t${t}_h$([int]$h)_c$([int]$c).lua"
    Write-Lua (Join-Path $configsDir $fname) (New-ConfigVariant $baseConfig $t $h $c)
} } }

# UE4SS payload under ue4ss\ (installed to the game root, only if missing)
if ($haveUE4SS) {
    $u = Join-Path $s "ue4ss"
    New-Item -ItemType Directory -Force $u | Out-Null
    Copy-Item "$UE4SSSrc\*" $u -Recurse -Force
}

# info.xml
$info = @"
<?xml version="1.0" encoding="utf-8"?>
<fomod>
  <Name>$Mod</Name>
  <Author>Tautellini</Author>
  <Version>$ver</Version>
  <Website>https://github.com/Tautellini/TautelliniMods</Website>
  <Description>More tries, an optional next-move hint, and a connection display for the Gothic 1 Remake lockpicking minigame.$(if ($haveUE4SS) { ' Can install the experimental UE4SS for you if it is missing (opt-in during install).' })</Description>
</fomod>
"@
[System.IO.File]::WriteAllText((Join-Path $fomod "info.xml"), $info, (New-Object System.Text.UTF8Encoding($false)))

# ModuleConfig.xml
$x = New-Object System.Collections.Generic.List[string]
$x.Add('<?xml version="1.0" encoding="utf-8"?>')
$x.Add('<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://qconsulting.ca/fo3/ModConfig5.0.xsd">')
$x.Add("  <moduleName>$Mod $ver</moduleName>")
$x.Add('  <moduleImage path="fomod\images\hero.png" showImage="true" showFade="true" height="-1"/>')
# NOTE schema order on <config>: moduleName, moduleImage, moduleDependencies,
# requiredInstallFiles, installSteps, conditionalFileInstalls. requiredInstallFiles
# MUST precede installSteps or the FOMOD fails schema validation.
# the mod ALWAYS installs. No conditional gating: Vortex does not reliably
# evaluate fileDependency on a raw game file, which once left nothing deployed.
$x.Add('  <requiredInstallFiles>')
$x.Add("    <folder source=`"mod\$Mod`" destination=`"$ModDest`" priority=`"0`"/>")
$x.Add('  </requiredInstallFiles>')
$x.Add('  <installSteps order="Explicit">')
if ($haveUE4SS) {
    # ONE opt-in checkbox, always shown (no fileDependency auto-detect). When the
    # box is ticked the plugin's OWN <files> install UE4SS directly: the most
    # reliable FOMOD path, no flags and no raw-game-file checks. Untick = no
    # UE4SS (you already have it, or will install it yourself). The mod is
    # required and installs either way.
    $x.Add('    <installStep name="UE4SS">')
    $x.Add('      <optionalFileGroups order="Explicit">')
    $x.Add('        <group name="UE4SS (this mod needs it, please read)" type="SelectAny">')
    $x.Add('          <plugins order="Explicit">')
    $x.Add('            <plugin name="Install the bundled UE4SS too (tick ONLY if you do not already have UE4SS)">')
    $x.Add('              <description>This mod needs UE4SS. RECOMMENDED: install UE4SS yourself from   https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest   (the regular zip, not zDEV), so it stays even if you remove this mod. Tick this box ONLY if you do not have UE4SS and want it bundled in: your mod manager WILL REMOVE the bundled UE4SS when you uninstall this mod, which can break other UE4SS mods. If you already have UE4SS, leave this unticked.</description>')
    if (Test-Path $WarnSrc) { $x.Add('              <image path="fomod\images\warning.png"/>') }
    $x.Add("              <files><folder source=`"ue4ss`" destination=`"$Win64`" priority=`"0`"/></files>")
    $x.Add('              <typeDescriptor><type name="Optional"/></typeDescriptor>')
    $x.Add('            </plugin>')
    $x.Add('          </plugins>')
    $x.Add('        </group>')
    $x.Add('      </optionalFileGroups>')
    $x.Add('    </installStep>')
}
$x.Add("    <installStep name=`"Configure $Mod`">")
$x.Add('      <optionalFileGroups order="Explicit">')
$x.Add('        <group name="Extra lockpick tries" type="SelectExactlyOne">')
$x.Add('          <plugins order="Explicit">')
foreach ($t in $triesOpts) {
    $type = if ($t -eq 10) { "Recommended" } else { "Optional" }
    $x.Add("            <plugin name=`"+$t tries`">")
    $x.Add("              <description>Durability rises to $($t+2) / $($t+4) / $($t+6) tries (untrained / trained / master).</description>")
    $x.Add("              <conditionFlags><flag name=`"tries`">$t</flag></conditionFlags>")
    $x.Add("              <typeDescriptor><type name=`"$type`"/></typeDescriptor>")
    $x.Add('            </plugin>')
}
$x.Add('          </plugins>')
$x.Add('        </group>')
$x.Add('        <group name="Assists active at startup" type="SelectAny">')
$x.Add('          <plugins order="Explicit">')
$x.Add('            <plugin name="Next-move hint on at start (toggle F7)">')
$x.Add('              <description>Start each lock with the next-move hint already painted. You can always toggle it with F7 in game.</description>')
$x.Add('              <conditionFlags><flag name="hint">on</flag></conditionFlags>')
$x.Add('              <typeDescriptor><type name="Optional"/></typeDescriptor>')
$x.Add('            </plugin>')
$x.Add('            <plugin name="Connection display on at start (toggle F8)">')
$x.Add('              <description>Start each lock with the connection display already painted. Toggle with F8 in game.</description>')
$x.Add('              <conditionFlags><flag name="conn">on</flag></conditionFlags>')
$x.Add('              <typeDescriptor><type name="Optional"/></typeDescriptor>')
$x.Add('            </plugin>')
$x.Add('          </plugins>')
$x.Add('        </group>')
$x.Add('      </optionalFileGroups>')
$x.Add('    </installStep>')
$x.Add('  </installSteps>')
$x.Add('  <conditionalFileInstalls>')
$x.Add('    <patterns>')
# the chosen tries/assist preset overwrites the default config.lua (priority 1).
# Flag-only, no fileDependency. If the manager does not apply these option flags,
# the default config that shipped with the mod simply stays, so it still works.
foreach ($t in $triesOpts) { foreach ($h in $bools) { foreach ($c in $bools) {
    $hv = if ($h) { "on" } else { "" }
    $cv = if ($c) { "on" } else { "" }
    $fname = "config_t${t}_h$([int]$h)_c$([int]$c).lua"
    $x.Add('      <pattern>')
    $x.Add('        <dependencies operator="And">')
    $x.Add("          <flagDependency flag=`"tries`" value=`"$t`"/>")
    $x.Add("          <flagDependency flag=`"hint`" value=`"$hv`"/>")
    $x.Add("          <flagDependency flag=`"conn`" value=`"$cv`"/>")
    $x.Add('        </dependencies>')
    $x.Add('        <files>')
    $x.Add("          <file source=`"configs\$fname`" destination=`"$ModDest\Scripts\config.lua`" priority=`"1`"/>")
    $x.Add('        </files>')
    $x.Add('      </pattern>')
} } }
$x.Add('    </patterns>')
$x.Add('  </conditionalFileInstalls>')
$x.Add('</config>')
[System.IO.File]::WriteAllText((Join-Path $fomod "ModuleConfig.xml"), ($x -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# Validate the FOMOD against the schema so an invalid installer never ships
# again (a misordered <config> child once failed in Vortex at install time).
$xsd = Join-Path $PSScriptRoot "fomod\ModConfig5.0.xsd"
if (Test-Path $xsd) {
    $verr = New-Object System.Collections.Generic.List[string]
    $rs = New-Object System.Xml.XmlReaderSettings
    $rs.ValidationType = [System.Xml.ValidationType]::Schema
    $rs.Schemas.Add($null, $xsd) | Out-Null
    $rs.add_ValidationEventHandler([System.Xml.Schema.ValidationEventHandler] { param($snd, $ev) $verr.Add("L$($ev.Exception.LineNumber): $($ev.Message)") })
    $xr = [System.Xml.XmlReader]::Create((Join-Path $fomod "ModuleConfig.xml"), $rs)
    while ($xr.Read()) { }
    $xr.Close()
    if ($verr.Count -gt 0) { throw ("FOMOD ModuleConfig.xml failed schema validation:`n  " + ($verr -join "`n  ")) }
    Write-Host "  FOMOD schema: valid"
} else {
    Write-Warning "FOMOD schema not found at $xsd; skipping validation"
}

Zip $s "$Mod-$ver-vortex.zip"

Remove-Item -Recurse -Force $work
Write-Host "`nArtifacts in $OutDir"
