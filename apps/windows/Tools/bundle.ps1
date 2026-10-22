# Stage the release bundle: XDict.exe self-contained, XDictService.exe beside it, a provenance line, and a signature
# only when the owner's certificate thumbprint is given. The certificate is the owner's purchase; nothing here signs.
[CmdletBinding()]
param(
    [string]$Out = '',
    [string]$CertificateThumbprint = ''
)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $layout.AppRoot 'out\release' }

& (Join-Path $PSScriptRoot 'build.ps1') -Release

$outParent = Join-Path $layout.AppRoot 'out'
$fullOut = [System.IO.Path]::GetFullPath($Out)
if (-not $fullOut.StartsWith($outParent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to clear ${fullOut}: a bundle's -Out must be under $outParent"
}
if (Test-Path -LiteralPath $fullOut) { Remove-Item -LiteralPath $fullOut -Recurse -Force }
New-Item -ItemType Directory -Force -Path $fullOut | Out-Null

dotnet publish (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') -c Release -r win-x64 --self-contained true `
    -p:WindowsAppSDKSelfContained=true -o $fullOut
if ($LASTEXITCODE -ne 0) { throw 'the release publish failed' }

$service = Join-Path $layout.AppRoot 'service\target\release\xdict-service.exe'
if (-not (Test-Path -LiteralPath $service)) { throw "the release service is not built: $service" }
Copy-Item -LiteralPath $service -Destination (Join-Path $fullOut 'XDictService.exe') -Force

$appVersion = (& dotnet msbuild (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') `
        -getProperty:Version -p:Configuration=Release -nologo | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0) { throw 'msbuild could not report the version' }
$appVersion = $appVersion.Trim()
$contract = (Get-Content -LiteralPath (Join-Path $layout.RepoRoot 'apps\windows\contract\contract.json') -Raw |
    ConvertFrom-Json).contract
$lines = @(
    ('XDict {0}' -f $appVersion),
    ('contract {0}' -f $contract),
    ('built {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')),
    ('host {0}' -f $env:COMPUTERNAME),
    ('os {0}' -f ((Get-CimInstance Win32_OperatingSystem | ForEach-Object { $_.Caption + ' ' + $_.Version + ' build ' + $_.BuildNumber }) -join '')),
    ('dotnet {0}' -f (& dotnet --version)),
    ('rustc {0}' -f (& rustc --version))
)
Set-Content -LiteralPath (Join-Path $fullOut 'Provenance.txt') -Value $lines -Encoding Utf8

if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    Write-Host 'unsigned bundle: pass -CertificateThumbprint to sign (the certificate is the owner''s purchase)'
}
else {
    & (Join-Path $PSScriptRoot 'sign.ps1') -CertificateThumbprint $CertificateThumbprint `
        -Path @((Join-Path $fullOut 'XDict.exe'), (Join-Path $fullOut 'XDictService.exe'))
    if ($LASTEXITCODE -ne 0) { throw 'signing failed' }
}
Write-Host ("bundle: {0}" -f $fullOut)
