# Runs SharedModMenu's pure-Lua tests under Lua 5.4 (the UE4SS runtime; no game, no engine).
# UE4SS (build 968+) runs PUC Lua 5.4, NOT LuaJIT; test against 5.4 so 5.1-only behaviour
# never masks a real bug.
# Usage:  powershell -File G1R\SharedModMenu\tests\run.ps1
$ErrorActionPreference = "Stop"

$here     = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $here "..\..\..")).Path

$lua = $null
$local = Join-Path $repoRoot "tools\lua54\lua.exe"
if (Test-Path $local) {
    $lua = $local
} else {
    $onPath = Get-Command lua -ErrorAction SilentlyContinue
    if ($onPath) { $lua = $onPath.Source }
}
if (-not $lua) {
    throw "Lua 5.4 not found. Build it: download lua.org/ftp/lua-5.4.7.tar.gz into tools\, extract, compile src\*.c (except luac.c) to tools\lua54\lua.exe with cl or gcc. See CONTRIBUTING.md."
}

Write-Host "Using $lua`n"
$failing = 0
Push-Location $here
try {
    foreach ($s in (Get-ChildItem -Filter "test_*.lua" | Sort-Object Name)) {
        Write-Host "=== $($s.Name) ==="
        & $lua $s.Name
        if ($LASTEXITCODE -ne 0) { $failing += 1 }
        Write-Host ""
    }
} finally {
    Pop-Location
}

if ($failing -eq 0) { Write-Host "SHAREDMODMENU: ALL SUITES PASSED" } else { Write-Host "SHAREDMODMENU: $failing suite(s) FAILED" }
exit $failing
