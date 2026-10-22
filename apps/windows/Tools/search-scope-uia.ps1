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
        ConvertTo-Json | Set-Content -LiteralPath $libraryConfig -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $prep = 'xdict-prep-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('--library-lab "' + $libraryConfig + '"')
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $prep -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $prep
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        $prepared = Join-Path $folder 'library-result.json'
        while (-not (Test-Path -LiteralPath $prepared)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'the library preparation produced no result' }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $prep -Confirm:$false -ErrorAction SilentlyContinue
    }

    $launchId = 'scope-' + [Guid]::NewGuid().ToString('N')
    $result = Join-Path $folder 'result.json'
    $quit = Join-Path $env:LOCALAPPDATA ('XDict\launch\' + $launchId + '.quit')
    $wrapper = Join-Path $folder 'run.ps1'
    $template = @'
$ErrorActionPreference = 'Stop'
$env:XDICT_LIBRARY = '__LIBRARY__'
$app = Start-Process -FilePath '__EXE__' -ArgumentList ('--launch-id ' + '__LAUNCH__') -PassThru
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    . '__TOOLS__\uia-common.ps1'
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $byId = {
        param($parent, $id)
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    }
    $window = Find-XDictWindow $root 60
    $result = [ordered]@{ window = $false; scopeAll = -1; scopeTiny = -1; scopeDropped = -1
        error = '' }
    if ($window) {
        $result.window = $true
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
            $items = @($list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))
            return $items.Count
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
        Set-Scope 'Tiny'
        Set-Query 'dropped'
        $result.scopeTiny = Read-Rows
        Set-Scope 'Dropped'
        Set-Query 'dropped'
        $result.scopeDropped = Read-Rows
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
}
catch {
    @{ error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
}
finally {
    Set-Content -LiteralPath '__QUIT__' -Value '' -Encoding Ascii
    Start-Sleep -Seconds 2
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
'@
    $script = $template.Replace('__LIBRARY__', $library).Replace('__LAUNCH__', $launchId).
        Replace('__EXE__', $exe).Replace('__TOOLS__', $PSScriptRoot).Replace('__RESULT__', $result).Replace('__QUIT__', $quit)
    Set-Content -LiteralPath $wrapper -Value $script -Encoding UTF8

    $uia = Invoke-XDictTask -Script $wrapper -Output $result -Seconds 240
    Write-Host ($uia | ConvertTo-Json -Depth 6)
    if ($uia.PSObject.Properties['error'] -and $uia.error) { throw "the scope harness failed: $($uia.error)" }
    if (-not $uia.window) { throw 'the scope run did not open the window' }
    if ($uia.scopeAll -lt 1) { throw 'All dictionaries found no dropped entry' }
    if ($uia.scopeTiny -ne 0) { throw 'the Tiny scope still found dropped' }
    if ($uia.scopeDropped -lt 1) { throw 'the Dropped scope found nothing' }
}
