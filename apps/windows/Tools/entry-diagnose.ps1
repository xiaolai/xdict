$ErrorActionPreference = 'Stop'
foreach ($mode in 'corpus-ldoce','word') {
    & (Join-Path $PSScriptRoot 'entry-native.ps1') -Mode $mode
    Write-Host ($mode + ' exit=' + $LASTEXITCODE)
}
