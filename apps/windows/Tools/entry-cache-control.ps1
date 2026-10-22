# The external CSS/JS/fonts embedded by the Windows build must invalidate its own gate key.
. (Join-Path $PSScriptRoot 'gates.ps1')
$root = Join-Path $env:TEMP ('xdict-cache-control-' + [Guid]::NewGuid().ToString('N'))
try {
    $app = Join-Path $root 'apps\windows'
    $project = Join-Path $app 'XDict.App'
    $styles = Join-Path $root 'apps\apple\Sources\XDictEntryView\Style'
    New-Item -ItemType Directory -Force -Path $project,$styles | Out-Null
    '<Project><ItemGroup><EmbeddedResource Include="../../apple/Sources/XDictEntryView/Style/frame.js" /></ItemGroup></Project>' | Set-Content -LiteralPath (Join-Path $project 'XDict.App.csproj') -Encoding Ascii
    $asset = Join-Path $styles 'frame.js'
    'original' | Set-Content -LiteralPath $asset -Encoding Ascii
    $layout = [pscustomobject]@{ AppRoot = $app; RepoRoot = $root }
    $before = Get-XDictTreeHash -Roots (Get-XDictBuildInputs -Layout $layout)
    'changed external reading code' | Set-Content -LiteralPath $asset -Encoding Ascii
    $after = Get-XDictTreeHash -Roots (Get-XDictBuildInputs -Layout $layout)
    if ($before -eq $after) { throw 'the Windows build would carry an obsolete reading asset' }
    Write-Host 'external reading build-cache control: pass'
}
finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
