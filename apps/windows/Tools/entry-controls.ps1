$ErrorActionPreference = 'Stop'
foreach ($layer in 'filter','csp','navigation') {
    foreach ($state in 'off','on') {
        & (Join-Path $PSScriptRoot 'entry-native.ps1') -Mode ('control-' + $layer + '-' + $state)
        if ($LASTEXITCODE -ne 0) { throw "isolated $layer-$state failed" }
    }
}
