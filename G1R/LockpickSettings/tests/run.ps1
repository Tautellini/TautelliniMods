# Runs the LockpickSettings Lua test suite under Lua 5.4 (the UE4SS runtime).
# Usage:  powershell -File G1R\LockpickSettings\tests\run.ps1
#
# UE4SS (build 968+) runs PUC Lua 5.4, NOT LuaJIT. Test against 5.4: LuaJIT's Lua 5.1
# semantics (no integer/float split, different GC) can hide real 5.4 bugs. Prefers the
# repo-local tools\lua54\lua.exe, then `lua` on PATH. Runs check_load.lua then every
# test_*.lua here. Tests live in tests\, never under Scripts\, so deploy.ps1 never ships
# them. Exit code is the number of failing suites (0 = all pass).
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
$suites = @("check_load.lua")
$suites += (Get-ChildItem -Path $here -Filter "test_*.lua" | Sort-Object Name | ForEach-Object { $_.Name })

$failing = 0
Push-Location $here
try {
    foreach ($s in $suites) {
        Write-Host "=== $s ==="
        & $lua $s
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
