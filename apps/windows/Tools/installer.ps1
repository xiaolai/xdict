# Build the unsigned MSI from the release bundle, and sign it only when bundle.ps1's certificate thumbprint is given.
# The install/uninstall check itself belongs on a fresh Windows 11 VM, not on the owner's machine.
[CmdletBinding()]
param([string]$Bundle = '', [string]$Out = '', [string]$CertificateThumbprint = '')
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ([string]::IsNullOrWhiteSpace($Bundle)) { $Bundle = Join-Path $layout.AppRoot 'out\release' }
$version = (& dotnet msbuild (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') `
        -getProperty:Version -p:Configuration=Release -nologo | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0) { throw 'msbuild could not report the version' }
$version = $version.Trim()
# An existing bundle is used only when it is this project's build: every file the install needs, its own version,
# and the provenance the build wrote. "XDict.exe exists" accepted a stale bundle under a newer MSI version.
function Assert-Bundle {
    param([string]$Path, [string]$Version)
    foreach ($required in @('XDict.exe', 'XDictService.exe', 'App.xbf', 'MainWindow.xbf', 'XDict.pri',
            'Provenance.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required))) {
            throw "the bundle at $Path lacks $required; rebuild it with bundle.ps1"
        }
    }
    $fileVersion = (Get-Item -LiteralPath (Join-Path $Path 'XDict.exe')).VersionInfo.FileVersion
    if ($fileVersion -notlike ($Version + '*')) {
        throw "the bundle's XDict.exe is version $fileVersion, but this MSI would be $Version; rebuild the bundle"
    }
    $provenance = Get-Content -LiteralPath (Join-Path $Path 'Provenance.txt') -Raw -Encoding UTF8
    if ($provenance -notmatch ('(?m)^XDict ' + [regex]::Escape($Version) + '\s*$')) {
        throw "the bundle's Provenance.txt does not name $Version; rebuild the bundle"
    }
}
if (Test-Path -LiteralPath (Join-Path $Bundle 'XDict.exe')) {
    Assert-Bundle -Path $Bundle -Version $version
}
else {
    # The auto-built bundle carries the same signature choice: otherwise this MSI is signed around unsigned binaries.
    $bundleArgs = @{ Out = $Bundle }
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $bundleArgs['CertificateThumbprint'] = $CertificateThumbprint
    }
    & (Join-Path $PSScriptRoot 'bundle.ps1') @bundleArgs
    if ($LASTEXITCODE -ne 0) { throw 'the release bundle failed' }
    Assert-Bundle -Path $Bundle -Version $version
}
# A certificate signs the bundle's own executables too, never only the installer around them: an unsigned XDict.exe
# inside a signed MSI is the same unsigned app with a reassuring wrapper.
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    & (Join-Path $PSScriptRoot 'sign.ps1') -CertificateThumbprint $CertificateThumbprint `
        -Path @((Join-Path $Bundle 'XDict.exe'), (Join-Path $Bundle 'XDictService.exe'))
    if ($LASTEXITCODE -ne 0) { throw 'signing the bundle failed' }
}
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $layout.AppRoot ('out\XDict-' + $version + '-x64.msi') }
$wix = (Get-Command wix -ErrorAction SilentlyContinue)
if (-not $wix) { throw 'WiX is not installed: dotnet tool install --global wix' }
# -arch x64 is the installer's platform: without it WiX resolves ProgramFiles64Folder to the x86 view, as 0.1.6
# and 0.2.0 did. The upgrade test starts from that x86 install.
& $wix.Source build (Join-Path $PSScriptRoot 'installer.wxs') -arch x64 -d Version=$version -d PublishDir=$Bundle -o $Out
if ($LASTEXITCODE -ne 0) { throw 'the MSI build failed' }
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    & (Join-Path $PSScriptRoot 'sign.ps1') -Path $Out -CertificateThumbprint $CertificateThumbprint
    if ($LASTEXITCODE -ne 0) { throw 'signing the MSI failed' }
}
Write-Host ('installer: ' + $Out)
