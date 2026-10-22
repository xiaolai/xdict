# Five fail-closed controls, sequentially in the interactive session. Each must show the reader-facing refusal.
$ErrorActionPreference = 'Stop'
foreach ($fault in 'scheme','filter','navigation','csp','crash') {
    & (Join-Path $PSScriptRoot 'entry-native.ps1') -Mode ('fault-' + $fault)
    if ($LASTEXITCODE -ne 0) { throw "fault $fault did not refuse rendering" }
}
Write-Host 'entry faults: pass (5/5 refused with the protection sentence)'
