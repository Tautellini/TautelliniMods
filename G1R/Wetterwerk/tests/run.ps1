# Runs the Wetterwerk Lua test suite under LuaJIT (the UE4SS runtime).
# Usage:  powershell -File G1R\Wetterwerk\tests\run.ps1
#
# Finds luajit on PATH first (e.g. `scoop install luajit`), then falls back to
# the repo-local tools\luajit\luajit.exe (gitignored, see CONTRIBUTING.md).
# Runs check_load.lua then every test_*.lua here. Tests live in tests\, never
# under Scripts\, so deploy.ps1 never ships them. Exit code is the number of
# failing suites (0 = all pass).
$ErrorActionPreference = "Stop"

$here     = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $here "..\..\..")).Path

$luajit = $null
$onPath = Get-Command luajit -ErrorAction SilentlyContinue
if ($onPath) {
    $luajit = $onPath.Source
} else {
    $local = Join-Path $repoRoot "tools\luajit\luajit.exe"
    if (Test-Path $local) { $luajit = $local }
}
if (-not $luajit) {
    throw "luajit not found. Install it (scoop install luajit) or drop a prebuilt luajit.exe + lua51.dll in tools\luajit\. See CONTRIBUTING.md."
}

Write-Host "Using $luajit`n"
$suites = @("check_load.lua")
$suites += (Get-ChildItem -Path $here -Filter "test_*.lua" | Sort-Object Name | ForEach-Object { $_.Name })

$failing = 0
Push-Location $here
try {
    foreach ($s in $suites) {
        Write-Host "=== $s ==="
        & $luajit $s
        if ($LASTEXITCODE -ne 0) { $failing += 1 }
        Write-Host ""
    }
} finally {
    Pop-Location
}

if ($failing -eq 0) {
    Write-Host "ALL SUITES PASSED"
} else {
    Write-Host "$failing suite(s) FAILED"
}
exit $failing
