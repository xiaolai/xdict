# The Windows release: a committed tree, its build gates, then the signed-or-unsigned bundle, the MSI and its
# validation. E2E never gates a release (AGENTS.md, 2026-10-24): Tools\e2e.ps1 runs on demand and records what ran,
# and a release reads none of it. The build gates are the same scripts a developer runs, so a gate that already
# passed on this tree reports its cached pass.
[CmdletBinding()]
param([string]$CertificateThumbprint = '')
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
Assert-XDictCommittedTree -Root $layout.RepoRoot
$ran = New-Object System.Collections.Generic.List[string]
& (Join-Path $PSScriptRoot 'notices.ps1')
if ($LASTEXITCODE -ne 0) { throw 'notices generation failed' }
# The notices are generated from the shipped set; one that differs from the committed file would ship uncommitted.
Assert-XDictCommittedTree -Root $layout.RepoRoot -After 'regenerating the notices'
$ran.Add('notices')
foreach ($gate in @('build.ps1', 'test.ps1', 'contract.ps1', 'conformance.ps1')) {
    & (Join-Path $PSScriptRoot $gate)
    if ($LASTEXITCODE -ne 0) { throw ('the {0} gate failed' -f $gate) }
    $ran.Add($gate)
}
$bundle = @{}
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $bundle['CertificateThumbprint'] = $CertificateThumbprint
}
& (Join-Path $PSScriptRoot 'bundle.ps1') @bundle
if ($LASTEXITCODE -ne 0) { throw 'the bundle failed' }
$ran.Add('bundle.ps1')
& (Join-Path $PSScriptRoot 'installer.ps1') @bundle
if ($LASTEXITCODE -ne 0) { throw 'the installer failed' }
$ran.Add('installer.ps1')
$version = (& dotnet msbuild (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') -getProperty:Version -p:Configuration=Release -nologo | Select-Object -Last 1).Trim()
$msi = Join-Path $layout.AppRoot ('out\XDict-' + $version + '-x64.msi')
& (Join-Path $PSScriptRoot 'verify-msi.ps1') -Msi $msi
if ($LASTEXITCODE -ne 0) { throw 'the MSI did not validate' }
$ran.Add('verify-msi.ps1')
Write-Host ('release ran: ' + ($ran -join ', ') + '; no E2E evidence read')
Write-Host ("release: {0}" -f $msi)
