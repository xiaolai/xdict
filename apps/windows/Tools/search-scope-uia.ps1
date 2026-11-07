# Scope through UI Automation: two ready dictionaries and the scope combo changing the results. It never opens an
# entry: WinUI's provider stops answering FindAll after a WebView2 entry is created (the plan records that instrument
# limit), and the trail is proven by trail-lab without UIA.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'search-scope-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\search-scope\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    $drop = Join-Path $env:LOCALAPPDATA 'XDict\library-fixtures\drop\dropped.mdx'
    foreach ($file in @($tiny, $drop)) { if (-not (Test-Path -LiteralPath $file)) { throw "missing fixture: $file" } }
    $library = Join-Path $folder 'library.json'
    $libraryConfig = Join-Path $folder 'library-config.json'
    @{ output = (Join-Path $folder 'library-result.json'); library = $library; paths = @($tiny, $drop) } |
        ConvertTo-Json | Set-Content -LiteralPath $libraryConfig -Encoding UTF8
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $null = Invoke-XDictTask -Executable $exe -Arguments ('--library-lab "' + $libraryConfig + '"') `
        -Output (Join-Path $folder 'library-result.json') -Seconds 120 -Prefix 'xdict-prep' 

    $launchId = 'scope-' + [Guid]::NewGuid().ToString('N')
    $result = Join-Path $folder 'result.json'
    $quit = Join-Path $env:LOCALAPPDATA ('XDict\launch\' + $launchId + '.quit')
    $wrapper = Join-Path $folder 'run.ps1'
    # Paths travel as data: the driver reads them from a JSON file beside itself, so no apostrophe or quote in a
    # profile folder can end a string literal or become source.
    $driverConfig = Join-Path $folder 'driver-config.json'
    @{ library = $library; exe = $exe; launch = $launchId; tools = $PSScriptRoot; result = $result; quit = $quit } |
        ConvertTo-Json | Set-Content -LiteralPath $driverConfig -Encoding UTF8
    $template = @'
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'driver-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$resultPath = $config.result
$env:XDICT_LIBRARY = $config.library
$app = Start-Process -FilePath $config.exe -ArgumentList ('--launch-id ' + $config.launch) -PassThru
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    . (Join-Path $config.tools 'uia-common.ps1')
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $byId = {
        param($parent, $id)
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    }
    $window = Find-XDictWindow -Root $root -Seconds 60 -ProcessId $app.Id
    $result = [ordered]@{ window = $false; scopeAll = -1; scopeTiny = -1; scopeDropped = -1
        statusAll = ''; statusTiny = ''; statusDropped = ''; error = '' }
    if ($window) {
        $result.window = $true
        # The window exists before the session has opened its dictionaries; a query sent then is answered "loading"
        # with no rows. The old stage raced this and won on a faster start.
        Start-Sleep -Seconds 10
        $search = & $byId $window 'SearchBox'
        $list = & $byId $window 'Results'
        $scope = & $byId $window 'ScopeBox'
        $editCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
        $edit = $search.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
        $value = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        function Set-Query([string]$text) {
            $value.SetValue($text)
            try { $edit.SetFocus() } catch { }
            Start-Sleep -Milliseconds 250
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Start-Sleep -Seconds 2
        }
        function Read-Rows {
            # The status sentence carries the count; WinUI's bulk FindAll stops answering after a list repaints.
            $status = & $byId $window 'StatusText'
            if (-not $status) { return -1 }
            $name = $status.Current.Name
            if ($name -match '(\d+)') { return [int]$Matches[1] }
            # No count is not "no results": the query has not completed, and 0 would satisfy the Tiny assertion.
            return -2
        }
        function Set-Scope([string]$name) {
            $expand = $scope.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
            $expand.Expand()
            Start-Sleep -Milliseconds 400
            $items = $scope.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($item in $items) {
                if ($item.Current.Name -eq $name -and $item.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem) {
                    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                    break
                }
            }
            Start-Sleep -Milliseconds 300
            try { $expand.Collapse() } catch { }
            Start-Sleep -Milliseconds 300
        }
        Set-Query 'dropped'
        $result.scopeAll = Read-Rows
        $status = & $byId $window 'StatusText'
        if ($status) { $result.statusAll = $status.Current.Name }
        Set-Scope 'Tiny'
        Set-Query 'dropped'
        $result.scopeTiny = Read-Rows
        $status = & $byId $window 'StatusText'
        if ($status) { $result.statusTiny = $status.Current.Name }
        Set-Scope 'Dropped'
        Set-Query 'dropped'
        $result.scopeDropped = Read-Rows
        $status = & $byId $window 'StatusText'
        if ($status) { $result.statusDropped = $status.Current.Name }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
catch {
    @{ error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
finally {
    Set-Content -LiteralPath $config.quit -Value '' -Encoding Ascii
    Start-Sleep -Seconds 2
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
'@
    Set-Content -LiteralPath $wrapper -Value $template -Encoding UTF8

    $uia = Invoke-XDictTask -Script $wrapper -Output $result -Seconds 240
    Write-Host ($uia | ConvertTo-Json -Depth 6)
    if ($uia.PSObject.Properties['error'] -and $uia.error) { throw "the scope harness failed: $($uia.error)" }
    if (-not $uia.window) { throw 'the scope run did not open the window' }
    if ($uia.scopeAll -lt 1) { throw 'All dictionaries found no dropped entry' }
    if ([string]::IsNullOrWhiteSpace($uia.statusTiny)) { throw 'the Tiny scope reported no status sentence' }
    if ($uia.scopeTiny -lt 0) { throw 'the Tiny scope did not report a count; the query never completed' }
    if ($uia.scopeTiny -ne 0) { throw 'the Tiny scope still found dropped' }
    if ($uia.scopeDropped -lt 1) { throw 'the Dropped scope found nothing' }
}
