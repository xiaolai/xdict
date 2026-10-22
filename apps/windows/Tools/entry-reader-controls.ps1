$ErrorActionPreference = 'Stop'
foreach ($mode in 'frame-large-red','frame-large','display-red','display') {
    & (Join-Path $PSScriptRoot 'entry-native.ps1') -Mode $mode
    if ($mode.EndsWith('-red')) {
        if ($LASTEXITCODE -eq 0) { throw "negative control $mode unexpectedly passed" }
    }
    elseif ($LASTEXITCODE -ne 0) { throw "$mode failed" }
}
