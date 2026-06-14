# Runs the shared kit's test gate under Lua 5.4 (the UE4SS runtime), with NO mod present.
# UE4SS (build 968+) runs PUC Lua 5.4, NOT LuaJIT; testing on 5.4 catches the integer/float
# and GC differences LuaJIT's Lua 5.1 would hide.
# Usage:  powershell -File G1R\shared\kit\tests\run.ps1
$ErrorActionPreference = "Stop"

$here     = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $here "..\..\..\..")).Path

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

if ($failing -eq 0) { Write-Host "KIT: ALL SUITES PASSED" } else { Write-Host "KIT: $failing suite(s) FAILED" }
exit $failing
