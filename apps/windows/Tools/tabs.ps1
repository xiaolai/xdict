# Two searches, two entries, two tabs: each tab keeps its own pane, switching selects its state, and closing one
# leaves the other. The tab strip is read through UIA's TabItem elements; the headers are entry keys, not sentences.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'tabs-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\tabs-uia\' + [Guid]::NewGuid().ToString('N'))
    $fixtures = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
    $library = New-XDictUiaLibrary -Folder $folder -Mdx @((Join-Path $fixtures 'tiny\tiny.mdx'))
    $config = Join-Path $folder 'config.json'
    $resultPath = Join-Path $folder 'result.json'
    @{
        mode = 'tabs'; library = $library; result = $resultPath
        exe = (Join-Path (Get-XDictAppOutput) 'XDict.exe')
    } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8
    $result = Invoke-XDictTask -Executable 'powershell.exe' `
        -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'uia-drive.ps1') + '" "' + $config + '"') `
        -Output $resultPath -Seconds 300 -Prefix 'xdict-tabs'
    Write-Host ($result | ConvertTo-Json -Depth 6)
    if ($result.PSObject.Properties['error'] -and $result.error) { throw "the tabs driver failed: $($result.error)" }
    if (-not $result.window) { throw 'the XDict window was not found' }
    if (-not $result.tabColor) { throw 'the colour entry did not open in a tab' }
    if (-not $result.tabHue) { throw 'the hue entry did not open in a second tab' }
    if (-not $result.firstSelected) { throw 'selecting the first tab did not select it' }
    # The visible page's own URL and words, not the tab header: a pane that never switched would keep one URL.
    if ([string]::IsNullOrWhiteSpace($result.colorPage)) { throw 'the colour tab showed no entry page' }
    if ([string]::IsNullOrWhiteSpace($result.huePage)) { throw 'the hue tab showed no entry page' }
    if (-not $result.switchedPanes) { throw 'switching tabs did not switch the entry page' }
    if ($result.colorText -notmatch 'see') { throw "the colour tab's page is '$($result.colorText)'" }
    if ($result.hueText -notmatch 'shade') { throw "the hue tab's page is '$($result.hueText)'" }
    if (-not $result.stateKept) { throw 'returning to the colour tab lost its entry page' }
    if ($result.colorTextAfterSwitch -notmatch 'see') {
        throw "returning to the colour tab showed '$($result.colorTextAfterSwitch)'"
    }
    if ($result.colorPageAfterClose -ne $result.colorPage) {
        throw 'closing the hue tab did not leave the colour page'
    }
    if (-not $result.closed) { throw 'the second tab has no close button' }
    if (-not $result.colorAfterClose) { throw 'closing the second tab removed the first' }
    if ($result.hueAfterClose) { throw 'closing the second tab left it in the strip' }
    Stop-XDictLabProcesses -Name @('XDict')
}
