# The All page: with Scope All, one word the two twin dictionaries both carry is opened once and must paint both
# dictionaries' sections, each in its own frame. The sections are read by their fixture titles, not by a sentence.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'all-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\all-uia\' + [Guid]::NewGuid().ToString('N'))
    $fixtures = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
    $library = New-XDictUiaLibrary -Folder $folder -Mdx @(
        (Join-Path $fixtures 'twin-a\twin-a.mdx'),
        (Join-Path $fixtures 'twin-b\twin-b.mdx'))
    $config = Join-Path $folder 'config.json'
    $resultPath = Join-Path $folder 'result.json'
    @{
        mode = 'all'; library = $library; result = $resultPath
        exe = (Join-Path (Get-XDictAppOutput) 'XDict.exe')
    } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $result = Invoke-XDictTask -Executable 'powershell.exe' `
        -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'uia-drive.ps1') + '" "' + $config + '"') `
        -Output $resultPath -Seconds 300 -Prefix 'xdict-all'
    Write-Host ($result | ConvertTo-Json -Depth 6)
    if ($result.PSObject.Properties['error'] -and $result.error) { throw "the All page driver failed: $($result.error)" }
    if (-not $result.window) { throw 'the XDict window was not found' }
    if (-not $result.twinA) { throw 'the All page has no Twin A section' }
    if (-not $result.tabWord) { throw 'the All page did not open under the word' }
    # The second frame sits below the fold and WinUI's UIA provider does not expose it; the page's own count is the
    # evidence that both frames finished loading (it increments only after each pane answered its entry).
    if ($result.status -notmatch '(^|\D)2(\D|$)') {
        throw "the All page did not announce two sections: '$($result.status)'"
    }
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
}
