# Sequential: these controls mutate the same host copy and must never overlap.
$ErrorActionPreference = 'Stop'
foreach ($control in 'generation','deadline','reopen','sandbox','bulk','credits','identity','idle','paths') {
    & (Join-Path $PSScriptRoot 'service-controls.ps1') -Control $control
    if ($LASTEXITCODE -ne 0) { throw "control $control failed to restore" }
}
Write-Host 'service controls: pass (all checks turned red, sources restored)'
