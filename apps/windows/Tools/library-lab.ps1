# The library window's add path, driven in the interactive session by the production app: the scheduled task starts
# XDict.exe with --library-lab, the window adds the generated tiny fixture through the same method the pickers and the
# drop call, and the app writes the resulting record. A picture-free UI check; the OS picker dialog itself is not driven.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'library-lab' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\library-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $config = Join-Path $folder 'config.json'
    $output = Join-Path $folder 'result.json'
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    if (-not (Test-Path -LiteralPath $tiny)) { throw "the tiny fixture is missing: $tiny" }
    @{ output = $output; library = (Join-Path $folder 'library.json'); paths = @($tiny) } |
        ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $result = Invoke-XDictTask -Executable $exe -Arguments ('--library-lab "' + $config + '"') -Output $output `
        -Seconds 120 -Prefix 'library-lab'
    Write-Host ($result | ConvertTo-Json -Depth 5)
    if ($result.count -lt 1) { throw 'the library window added no dictionary' }
    if (-not ($result.editions[0] -like 'mdx-sha256-v1:*')) { throw 'the library record has no edition' }
}
