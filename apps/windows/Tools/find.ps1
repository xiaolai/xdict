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
    } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8
    $result = Invoke-XDictTask -Executable 'powershell.exe' `
        -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'uia-drive.ps1') + '" "' + $config + '"') `
        -Output $resultPath -Seconds 240 -Prefix 'xdict-find'
    Write-Host ($result | ConvertTo-Json -Depth 6)
    if ($result.PSObject.Properties['error'] -and $result.error) { throw "the find driver failed: $($result.error)" }
    if (-not $result.window) { throw 'the XDict window was not found' }
    if (-not $result.tabColor) { throw 'the colour entry did not open in a tab' }
    if ([string]::IsNullOrWhiteSpace($result.findPage)) { throw 'the entry page was not found for the find check' }
    if (-not $result.findVisible) { throw 'Ctrl+F did not show the find bar over the entry' }
    if ($result.findValue -ne 'color') { throw "the find field holds '$($result.findValue)', not color" }
    # The typed text is not evidence that the entry was searched: the page's selection is.
    if ($result.findSelection -like 'unavailable:*') { throw ('the page selection could not be read: ' + $result.findSelection) }
    if ([string]::IsNullOrWhiteSpace($result.findSelection)) { throw 'the find selected nothing in the entry' }
    if ($result.findSelection.Trim() -ne 'color') { throw "the find selected '$($result.findSelection)', not color" }
    if (-not $result.findFollows) {
        throw "the find did not follow a second term (first '$($result.findSelection)', second '$($result.findSecond)')"
    }
    if ($result.findAbsent -eq 'zzzz') { throw 'the page selection took a term the entry does not hold' }
    if (-not $result.findClosed) { throw 'Escape did not close the find bar' }
    Stop-XDictLabProcesses -Name @('XDict')
}
