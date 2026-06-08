<#
  Rasterize the brand templates to PNG with headless Chrome/Edge.

  Usage:
    powershell -File brand\render.ps1                 # render all templates
    powershell -File brand\render.ps1 -Only hero.html # render one
    powershell -File brand\render.ps1 -ChromePath "C:\path\to\chrome.exe"

  Output lands in brand\out\ by default. Webfonts load over the network at
  render time; for offline determinism, install JetBrains Mono + Inter locally
  or drop woff2 files into brand\fonts\ and swap the @import in house.css.
#>
param(
  [string]$ChromePath,
  [string]$OutDir = "$PSScriptRoot\out",
  [string[]]$Only
)

$ErrorActionPreference = "Stop"

# template -> render size (width, height)
$sizes = [ordered]@{
  "hero.html"    = @(1920, 1080)
  "section.html" = @(1920, 300)
  "card.html"    = @(720, 440)
  "badge.html"   = @(960, 180)
  "footer.html"  = @(1920, 140)
  "gallery-hint.html"        = @(1920, 1080)
  "gallery-connections.html" = @(1920, 1080)
  "gallery-tries.html"       = @(1920, 1080)
  "gallery-safe.html"        = @(1920, 1080)
  "nexus-header.html"        = @(1300, 372)
}

if (-not $ChromePath) {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  )
  $ChromePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $ChromePath) { throw "Chrome/Edge not found. Pass -ChromePath explicitly." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$tpl = Join-Path $PSScriptRoot "templates"

foreach ($name in $sizes.Keys) {
  if ($Only -and ($Only -notcontains $name)) { continue }
  $html = Join-Path $tpl $name
  if (-not (Test-Path $html)) { Write-Warning "missing template: $name"; continue }

  $w = $sizes[$name][0]; $h = $sizes[$name][1]
  $png = Join-Path $OutDir ($name -replace '\.html$', '.png')
  $uri = ([System.Uri]$html).AbsoluteUri

  & $ChromePath --headless=new --disable-gpu --hide-scrollbars `
    --force-device-scale-factor=1 --window-size="$w,$h" `
    --virtual-time-budget=4000 --run-all-compositor-stages-before-draw `
    --default-background-color=00000000 `
    --screenshot="$png" $uri | Out-Null

  if (Test-Path $png) { Write-Host "rendered $name -> $png ($w x $h)" }
  else { Write-Warning "no output for $name" }
}
