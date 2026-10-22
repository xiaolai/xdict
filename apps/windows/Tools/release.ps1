# The Windows release: evidence first, then notices, the signed-or-unsigned bundle, the MSI and its validation.
# Evidence is the latest E2E report for this exact tree, passed, and within 14 days — the ledger rule, in one file.
[CmdletBinding()]
param([string]$CertificateThumbprint = '', [switch]$SkipEvidence)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$tree = Get-XDictTreeHash -Roots @($layout.AppRoot, (Join-Path $layout.RepoRoot 'core'), (Join-Path $layout.RepoRoot 'conformance')) -Exclude @('\\bin\\', '\\obj\\', '\\target\\')
# Evidence may come from several reports for this tree — the UIA stages run over SSH and the rest detached, each
# context with its own limits — but between them every stage must have passed on this exact tree, within 14 days.
$reports = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'XDict\e2e') -Filter report.json -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
if ($SkipEvidence) { Write-Host 'evidence skipped by -SkipEvidence: this is not releasable evidence' }
else {
    $covered = @{}
    $used = New-Object System.Collections.Generic.List[string]
    foreach ($file in $reports) {
        $report = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($report.tree -ne $tree -or $report.failed -gt 0) { continue }
        if (((Get-Date) - $file.LastWriteTime).TotalDays -gt 14) { continue }
        foreach ($stage in $report.stages) { if ($stage.pass) { $covered[$stage.name] = $true } }
        $used.Add($file.FullName)
    }
    $required = Get-XDictE2EStageNames
    $missing = @($required | Where-Object { -not $covered.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw ("no passing evidence for: " + ($missing -join ', ') + "; run Tools\e2e.ps1") }
    Write-Host ("evidence: all 15 stages passed on this tree, from " + $used.Count + " report(s): " + ($used -join '; '))
}
& (Join-Path $PSScriptRoot 'notices.ps1')
if ($LASTEXITCODE -ne 0) { throw 'notices generation failed' }
$bundle = @{}
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $bundle['CertificateThumbprint'] = $CertificateThumbprint
}
& (Join-Path $PSScriptRoot 'bundle.ps1') @bundle
if ($LASTEXITCODE -ne 0) { throw 'the bundle failed' }
& (Join-Path $PSScriptRoot 'installer.ps1') @bundle
if ($LASTEXITCODE -ne 0) { throw 'the installer failed' }
$version = (& dotnet msbuild (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') -getProperty:Version -p:Configuration=Release -nologo | Select-Object -Last 1).Trim()
$msi = Join-Path $layout.AppRoot ('out\XDict-' + $version + '-x64.msi')
& (Join-Path $PSScriptRoot 'verify-msi.ps1') -Msi $msi
if ($LASTEXITCODE -ne 0) { throw 'the MSI did not validate' }
Write-Host ("release: {0}" -f $msi)
