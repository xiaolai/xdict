# Every non-GUI gate in order: build, unit tests, contract fixtures, IPC conformance, capture suite. The launch stage
# is evidence for the E2E host and runs on request (Tools\launch.ps1). -Full ignores the cache for every gate.
[CmdletBinding()]
param([switch]$Full)

$ErrorActionPreference = 'Stop'
foreach ($name in 'build.ps1', 'test.ps1', 'contract.ps1', 'conformance.ps1', 'capture.ps1') {
    & (Join-Path $PSScriptRoot $name) -Full:$Full
    if ($LASTEXITCODE -ne 0) { throw "$name failed" }
}
Write-Host 'all gates: pass'
