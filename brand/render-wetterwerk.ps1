<#
  Rasterize the Wetterwerk brand templates to PNG with headless Chrome/Edge.
  Same engine as render.ps1, pointed at templates\wetterwerk\ and the "Azur"
  (light-blue) theme, with weather section / card content.

  Usage:
    powershell -File brand\render-wetterwerk.ps1                  # render all
    powershell -File brand\render-wetterwerk.ps1 -Only hero.html  # render one
    powershell -File brand\render-wetterwerk.ps1 -ChromePath "C:\path\to\chrome.exe"

  Output lands in brand\out\wetterwerk\ by default.
#>
param(
  [string]$ChromePath,
  [string]$OutDir = "$PSScriptRoot\out\wetterwerk",
  [string[]]$Only
)

$ErrorActionPreference = "Stop"

# template -> render size (width, height).
# section.html and card.html are NOT here: they are data-driven and rendered once
# per section / per feature in the dedicated loops below.
$sizes = [ordered]@{
  "hero.html"             = @(1920, 1080)
  "hero-cards.html"       = @(1920, 1080)
  "badge.html"            = @(960, 180)
  "footer.html"           = @(1920, 140)
  "gallery-control.html"  = @(1920, 1080)
  "gallery-presets.html"  = @(1920, 1080)
  "gallery-values.html"   = @(1920, 1080)
  "gallery-safe.html"     = @(1920, 1080)
  "nexus-header.html"     = @(1300, 372)
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
$tpl = Join-Path $PSScriptRoot "templates\wetterwerk"

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
$sections = [ordered]@{
  "features"        = @("01", "FEATURES",        "")
  "install"         = @("02", "INSTALLATION",    "TWO DOWNLOADS")
  "config"          = @("03", "USING THE MENU",  "GUI CONSOLE TAB")
  "safety"          = @("04", "SAFETY",          "READS + RESTORES")
  "compatibility"   = @("05", "COMPATIBILITY",   "ONE UE4SS BUILD")
  "troubleshooting" = @("06", "TROUBLESHOOTING", "")
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
$cards = [ordered]@{
  "control" = @("WEATHER CONTROL",     "Set any sky condition on command", "from the in-game menu tab.",       "",   "prev / next / hold + presets",     "restores the game's cycle on exit")
  "presets" = @("PRESETS",             "Switch to any of the game's",       "weather states from the tab.",     "",   "click a preset, or hold one",      "the dynamic cycle, paused")
  "values"  = @("EVERY VALUE EXPOSED", "Cloud, fog, rain, wind, thunder.",  "Drag any single value live.",      "",   "every reflected sky value",        "filtered, with a caution group")
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

# eyebrow-less gallery variants for embedding inside the description body
# (the [ WETTERWERK ] eyebrow is clutter there). Same templates, ?eyebrow=0.
$bareGalleries = @("gallery-control", "gallery-presets", "gallery-values", "gallery-safe")
if (-not $Only -or ($Only -contains "galleries-bare")) {
  foreach ($g in $bareGalleries) {
    $base = ([System.Uri](Join-Path $tpl "$g.html")).AbsoluteUri
    Render-Uri ($base + "?eyebrow=0")          (Join-Path $OutDir "$g-bare.png")     1920 1080 "$g-bare"
    Render-Uri ($base + "?eyebrow=0&invert=1") (Join-Path $OutDir "$g-bare-inv.png") 1920 1080 "$g-bare-inv"
  }
}
