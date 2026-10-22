# Build the unsigned MSI from the release bundle, and sign it only when bundle.ps1's certificate thumbprint is given.
# The install/uninstall check itself belongs on a fresh Windows 11 VM, not on the owner's machine.
[CmdletBinding()]
param([string]$Bundle = '', [string]$Out = '', [string]$CertificateThumbprint = '')
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ([string]::IsNullOrWhiteSpace($Bundle)) { $Bundle = Join-Path $layout.AppRoot 'out\release' }
if (-not (Test-Path -LiteralPath (Join-Path $Bundle 'XDict.exe'))) {
    # The auto-built bundle carries the same signature choice: otherwise this MSI is signed around unsigned binaries.
    $bundleArgs = @{ Out = $Bundle }
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $bundleArgs['CertificateThumbprint'] = $CertificateThumbprint
    }
    & (Join-Path $PSScriptRoot 'bundle.ps1') @bundleArgs
    if ($LASTEXITCODE -ne 0) { throw 'the release bundle failed' }
}
$version = (& dotnet msbuild (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') `
        -getProperty:Version -p:Configuration=Release -nologo | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0) { throw 'msbuild could not report the version' }
$version = $version.Trim()
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $layout.AppRoot ('out\XDict-' + $version + '-x64.msi') }
$wix = (Get-Command wix -ErrorAction SilentlyContinue)
if (-not $wix) { throw 'WiX is not installed: dotnet tool install --global wix' }
& $wix.Source build (Join-Path $PSScriptRoot 'installer.wxs') -d Version=$version -d PublishDir=$Bundle -o $Out
if ($LASTEXITCODE -ne 0) { throw 'the MSI build failed' }
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    & (Join-Path $PSScriptRoot 'sign.ps1') -Path $Out -CertificateThumbprint $CertificateThumbprint
    if ($LASTEXITCODE -ne 0) { throw 'signing the MSI failed' }
}
Write-Host ('installer: ' + $Out)
