# The acknowledgements, generated from the shipped set: every Rust crate the service builds, every NuGet package the
# app restores (transitive included) with its own licence expression, and the components that ship as runtime or data.
[CmdletBinding()]
param([string]$Out = '')
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $layout.AppRoot 'XDict.App\Notices.txt' }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('XDict - acknowledgements')
$lines.Add('')
$lines.Add('XDict itself is licensed under the ISC licence.')
$lines.Add('')
$lines.Add('Rust crates (the dictionary service):')
$cargoOut = Join-Path $env:TEMP ('xdict-cargo-' + [Guid]::NewGuid().ToString('N') + '.json')
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & cargo metadata --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml') --format-version 1 --locked > $cargoOut 2>$null
    $cargoCode = $LASTEXITCODE
}
finally { $ErrorActionPreference = $previous }
if ($cargoCode -ne 0) { throw 'cargo metadata failed for the service' }
$packages = (Get-Content -LiteralPath $cargoOut -Raw | ConvertFrom-Json).packages | Sort-Object name
Remove-Item -LiteralPath $cargoOut -Force -ErrorAction SilentlyContinue
foreach ($package in $packages) {
    $licence = if ($package.PSObject.Properties['license'] -and $package.license) { $package.license } else { 'see the crate' }
    $lines.Add(('  {0} {1} - {2}' -f $package.name, $package.version, $licence))
}
$lines.Add('')
$lines.Add('.NET and the Windows App SDK (the app):')
$listOut = Join-Path $env:TEMP ('xdict-list-' + [Guid]::NewGuid().ToString('N') + '.json')
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & dotnet list (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') package --include-transitive --format json > $listOut 2>$null
    $listCode = $LASTEXITCODE
}
finally { $ErrorActionPreference = $previous }
if ($listCode -eq 0) {
    $json = Get-Content -LiteralPath $listOut -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $listOut -Force -ErrorAction SilentlyContinue
    foreach ($framework in $json.projects[0].frameworks) {
        foreach ($package in ($framework.topLevelPackages + $framework.transitivePackages | Sort-Object id)) {
            if ($null -eq $package) { continue }
            $nuspec = Join-Path $env:USERPROFILE ('.nuget\packages\' + $package.id.ToLowerInvariant() + '\' + $package.resolvedVersion + '\' + $package.id.ToLowerInvariant() + '.nuspec')
            $licence = 'see the package'
            if (Test-Path -LiteralPath $nuspec) {
                [xml]$spec = Get-Content -LiteralPath $nuspec -Raw
                $metadataNode = if ($spec.package.PSObject.Properties['metadata']) { $spec.package.metadata } else { $null }
                if ($null -ne $metadataNode) {
                    $licenceNode = if ($metadataNode.PSObject.Properties['license']) { $metadataNode.license } else { $null }
                    $urlNode = if ($metadataNode.PSObject.Properties['licenseUrl']) { $metadataNode.licenseUrl } else { $null }
                    if ($null -ne $licenceNode) {
                        $text = if ($licenceNode.PSObject.Properties['#text']) { $licenceNode.'#text' } else { '' }
                        $kind = if ($licenceNode.PSObject.Properties['type']) { $licenceNode.type } else { '' }
                        $licence = ($text + $kind).Trim()
                    }
                    elseif ($null -ne $urlNode) { $licence = $urlNode }
                }
            }
            $lines.Add(('  {0} {1} - {2}' -f $package.id, $package.resolvedVersion, $licence))
        }
    }
}
else {
    Remove-Item -LiteralPath $listOut -Force -ErrorAction SilentlyContinue
    throw 'dotnet list failed: the notices would ship without the .NET and Windows App SDK acknowledgements'
}
$lines.Add('')
$lines.Add('Components shipped as runtime or data:')
$lines.Add('  Microsoft Windows App SDK runtime - Microsoft, the Windows App SDK licence.')
$lines.Add('  Microsoft Edge WebView2 Runtime - Microsoft, the WebView2 Runtime licence.')
$lines.Add('  Charis SIL - SIL International, the SIL Open Font License 1.1 (the licence text ships with the fonts).')
$lines.Add('  UI Automation and the Windows Runtime - Microsoft, the Windows licence terms.')
$lines.Add('')
$lines.Add('MDict is a format by Bugu; XDict''s reader is clean-room and ships no dictionary content.')
$text = ($lines -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($Out, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('notices: ' + $Out)
