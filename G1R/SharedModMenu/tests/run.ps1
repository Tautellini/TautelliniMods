# Runs SharedModMenu's pure-Lua tests under LuaJIT (no game, no engine).
# Usage:  powershell -File G1R\SharedModMenu\tests\run.ps1
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
$failing = 0
Push-Location $here
try {
    foreach ($s in (Get-ChildItem -Filter "test_*.lua" | Sort-Object Name)) {
        Write-Host "=== $($s.Name) ==="
        & $luajit $s.Name
        if ($LASTEXITCODE -ne 0) { $failing += 1 }
        Write-Host ""
    }
} finally {
    Pop-Location
}

if ($failing -eq 0) { Write-Host "SHAREDMODMENU: ALL SUITES PASSED" } else { Write-Host "SHAREDMODMENU: $failing suite(s) FAILED" }
exit $failing
