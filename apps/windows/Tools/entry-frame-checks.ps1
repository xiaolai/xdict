$ErrorActionPreference = 'Stop'
foreach ($mode in 'frame-write','frame-relaunch','bridge') {
    & (Join-Path $PSScriptRoot 'entry-native.ps1') -Mode $mode
    if ($LASTEXITCODE -ne 0) { throw "native $mode failed" }
}
