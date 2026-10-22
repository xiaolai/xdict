# The trail through the window's own methods, after real searches: run -> open, cafe -> open, Back. This exercises the
# entry open after a search (the path that hung) without UI Automation's WebView2 traversal.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'trail-lab' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\trail-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    if (-not (Test-Path -LiteralPath $tiny)) { throw "the tiny fixture is missing: $tiny" }
    $library = Join-Path $folder 'library.json'
    $libraryConfig = Join-Path $folder 'library-config.json'
    @{ output = (Join-Path $folder 'library-result.json'); library = $library; paths = @($tiny) } |
        ConvertTo-Json | Set-Content -LiteralPath $libraryConfig -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $null = Invoke-XDictTask -Executable $exe -Arguments ('--library-lab "' + $libraryConfig + '"') `
        -Output (Join-Path $folder 'library-result.json') -Seconds 120 -Prefix 'xdict-prep' 

    $config = Join-Path $folder 'config.json'
    $result = Join-Path $folder 'result.json'
    @{ output = $result; library = $library } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $uia = Invoke-XDictTask -Executable $exe -Arguments ('--trail-lab "' + $config + '"') -Output $result `
        -Seconds 180 -Prefix 'xdict-trail-lab'
    Write-Host ($uia | ConvertTo-Json -Depth 4)
    if ($uia.runRows -lt 1 -or $uia.cafeRows -lt 1) { throw 'a search painted no rows' }
    if (-not $uia.openedFirst -or -not $uia.openedSecond) { throw 'an entry did not open' }
    if ($uia.firstBack) { throw 'Back was enabled after the first visit' }
    if (-not $uia.secondBack) { throw 'Back was not enabled after the second visit' }
    if ($uia.afterBack) { throw 'Back did not move back to the first visit' }
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
}
