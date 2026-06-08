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

# template -> render size (width, height).
# section.html and card.html are NOT here: they are data-driven and rendered once
# per section / per feature in the dedicated loops below.
$sizes = [ordered]@{
  "hero.html"    = @(1920, 1080)
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

function Render-Uri([string]$uri, [string]$png, [int]$w, [int]$h, [string]$label) {
  & $ChromePath --headless=new --disable-gpu --hide-scrollbars `
    --force-device-scale-factor=1 --window-size="$w,$h" `
    --virtual-time-budget=4000 --run-all-compositor-stages-before-draw `
    --default-background-color=00000000 `
    --screenshot="$png" $uri | Out-Null

  if (Test-Path $png) { Write-Host "rendered $label -> $png ($w x $h)" }
  else { Write-Warning "no output for $label" }
}

foreach ($name in $sizes.Keys) {
  if ($Only -and ($Only -notcontains $name)) { continue }
  $html = Join-Path $tpl $name
  if (-not (Test-Path $html)) { Write-Warning "missing template: $name"; continue }

  $w = $sizes[$name][0]; $h = $sizes[$name][1]
  $png = Join-Path $OutDir ($name -replace '\.html$', '.png')
  Render-Uri ([System.Uri]$html).AbsoluteUri $png $w $h $name
}

$dot   = [char]0x00B7   # middle dot
$arrow = [char]0x2192   # right arrow

# section header strips: one data-driven template, content via query params.
# key -> @(index, title, right-side note). Rendered to out\section-<key>.png.
# The three features live in the FEATURES collapsible as cards (below), not as strips.
$sections = [ordered]@{
  "features"        = @("01", "FEATURES",            "")
  "requirements"    = @("02", "REQUIREMENTS",        "UE4SS EXPERIMENTAL")
  "install"         = @("03", "INSTALLATION",        "TWO ARCHIVES")
  "config"          = @("04", "CONFIGURATION",       "CONFIG.LUA")
  "safety"          = @("05", "SAFETY",              "READ-ONLY $dot SAVE-SAFE")
  "troubleshooting" = @("06", "TROUBLESHOOTING",     "")
}
if (-not $Only -or ($Only -contains "section.html")) {
  $sectionHtml = ([System.Uri](Join-Path $tpl "section.html")).AbsoluteUri
  foreach ($key in $sections.Keys) {
    $i = $sections[$key][0]; $t = $sections[$key][1]; $note = $sections[$key][2]
    $q = "?i=$([uri]::EscapeDataString($i))" +
         "&t=$([uri]::EscapeDataString($t))" +
         "&note=$([uri]::EscapeDataString($note))"
    $png = Join-Path $OutDir "section-$key.png"
    Render-Uri ($sectionHtml + $q) $png 1920 300 "section-$key"
  }
}

# feature cards: one data-driven template, content via query params.
# key -> @(title, body1, body2, cap, capLabel, capSub). Empty cap hides the cap.
# Rendered to out\card-<key>.png, transparent so they sit on the page background.
$cards = [ordered]@{
  "tries"       = @("MORE TRIES",         "More attempts before a pick breaks,", "the same bonus on every skill tier.", "",   "2 / 4 / 6  $arrow  12 / 14 / 16", "always on $dot the bonus is configurable")
  "hint"        = @("NEXT-MOVE HINT",     "The next piece to move lights up,",   "replanned after every move.",         "F7", "toggle anytime, even mid-pick",   "off by default $dot your call when to cheat")
  "connections" = @("CONNECTION DISPLAY", "The pieces wired to your selection",  "light up by drag direction.",         "F8", "toggle anytime",                  "off by default")
}
if (-not $Only -or ($Only -contains "card.html")) {
  $cardHtml = ([System.Uri](Join-Path $tpl "card.html")).AbsoluteUri
  foreach ($key in $cards.Keys) {
    $t  = $cards[$key][0]; $b1 = $cards[$key][1]; $b2 = $cards[$key][2]
    $cap = $cards[$key][3]; $cl = $cards[$key][4]; $cs = $cards[$key][5]
    $q = "?t=$([uri]::EscapeDataString($t))" +
         "&b1=$([uri]::EscapeDataString($b1))" +
         "&b2=$([uri]::EscapeDataString($b2))" +
         "&cap=$([uri]::EscapeDataString($cap))" +
         "&cl=$([uri]::EscapeDataString($cl))" +
         "&cs=$([uri]::EscapeDataString($cs))"
    $png = Join-Path $OutDir "card-$key.png"
    Render-Uri ($cardHtml + $q) $png 720 440 "card-$key"
  }
}
