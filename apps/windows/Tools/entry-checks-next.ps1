$ErrorActionPreference = 'Stop'
foreach ($mode in 'control-navigation-on','hostile-red','frame-large-red','frame-large') {
    & (Join-Path $PSScriptRoot 'entry-native.ps1') -Mode $mode
    $expectedRed = $mode.EndsWith('-red')
    if ($expectedRed -and $LASTEXITCODE -eq 0) { throw "negative control $mode unexpectedly passed" }
    if (-not $expectedRed -and $LASTEXITCODE -ne 0) { throw "$mode failed" }
}
