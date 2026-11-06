# Find in the entry through the window: open a word, press Ctrl+F in the WebView, type, press Enter and Escape, and
# read the find bar's own state. The controls are found by UIA id, so the stage is language-independent.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'find-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\find-uia\' + [Guid]::NewGuid().ToString('N'))
    $fixtures = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
    $library = New-XDictUiaLibrary -Folder $folder -Mdx @((Join-Path $fixtures 'tiny\tiny.mdx'))
    $config = Join-Path $folder 'config.json'
    $resultPath = Join-Path $folder 'result.json'
    @{
        mode = 'find'; library = $library; result = $resultPath
        exe = (Join-Path (Get-XDictAppOutput) 'XDict.exe')
    } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $result = Invoke-XDictTask -Executable 'powershell.exe' `
        -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'uia-drive.ps1') + '" "' + $config + '"') `
        -Output $resultPath -Seconds 240 -Prefix 'xdict-find'
    Write-Host ($result | ConvertTo-Json -Depth 6)
    if ($result.PSObject.Properties['error'] -and $result.error) { throw "the find driver failed: $($result.error)" }
    if (-not $result.window) { throw 'the XDict window was not found' }
    if (-not $result.tabColor) { throw 'the colour entry did not open in a tab' }
    if (-not $result.findVisible) { throw 'Ctrl+F did not show the find bar over the entry' }
    if ($result.findValue -ne 'color') { throw "the find field holds '$($result.findValue)', not color" }
    if (-not $result.findClosed) { throw 'Escape did not close the find bar' }
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
}
