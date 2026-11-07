# Explore through its own window: open it, ask the tiny dictionary for words ending in "olour" (the driver's query is
# 'olour'), read a page of rows and open the first row, which must add the entry to the reader's tabs. The rows'
# reason labels are the shell's, so the stage asserts the word and the open, not a sentence.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'explore-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\explore-uia\' + [Guid]::NewGuid().ToString('N'))
    $fixtures = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
    $library = New-XDictUiaLibrary -Folder $folder -Mdx @((Join-Path $fixtures 'tiny\tiny.mdx'))
    $config = Join-Path $folder 'config.json'
    $resultPath = Join-Path $folder 'result.json'
    @{
        mode = 'explore'; library = $library; result = $resultPath
        exe = (Join-Path (Get-XDictAppOutput) 'XDict.exe')
    } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8
    $result = Invoke-XDictTask -Executable 'powershell.exe' `
        -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'uia-drive.ps1') + '" "' + $config + '"') `
        -Output $resultPath -Seconds 300 -Prefix 'xdict-explore'
    Write-Host ($result | ConvertTo-Json -Depth 6)
    if ($result.PSObject.Properties['error'] -and $result.error) { throw "the Explore driver failed: $($result.error)" }
    if (-not $result.window) { throw 'the XDict window was not found' }
    if (-not $result.exploreWindow) { throw 'the Explore window did not open' }
    $rows = @($result.rows)
    if ($rows.Count -lt 1) { throw 'Explore answered no row for words ending in olour' }
    if (-not ($rows | Where-Object { $_ -match '(?i)colour' })) { throw 'the Explore page has no colour row' }
    if (-not $result.tabColour) { throw 'opening the Explore row did not add its entry to the reader' }
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
}
