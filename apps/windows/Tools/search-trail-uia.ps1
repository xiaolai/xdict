# The trail, live: two entries opened by clicking their result rows, Back enabled after the second visit, then
# Alt+Left moving back to the first. No scope changes: the default scope keeps the rows this check needs.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'search-trail-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    # A stale app from an earlier timed-out run shares the window name and the WebView2 provider; never start over it.
    Get-Process -Name XDict -ErrorAction SilentlyContinue | Stop-Process -Force
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\search-trail\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    if (-not (Test-Path -LiteralPath $tiny)) { throw "the tiny fixture is missing: $tiny" }
    $library = Join-Path $folder 'library.json'
    $config = Join-Path $folder 'library-config.json'
    @{ output = (Join-Path $folder 'library-result.json'); library = $library; paths = @($tiny) } |
        ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $prep = 'xdict-prep-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('--library-lab "' + $config + '"')
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
    # The prep app's own window is also titled XDict; never let UIA attach to the dying lab instance.
    Get-Process -Name XDict -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1

    $launchId = 'trail-' + [Guid]::NewGuid().ToString('N')
    $result = Join-Path $folder 'result.json'
    $quit = Join-Path $env:LOCALAPPDATA ('XDict\launch\' + $launchId + '.quit')
    $wrapper = Join-Path $folder 'run.ps1'
    $template = @'
$ErrorActionPreference = 'Stop'
function Mark([string]$text) { $text | Add-Content -LiteralPath '__LOG__' }
Mark 'phase: start'
$env:XDICT_LIBRARY = '__LIBRARY__'
$app = Start-Process -FilePath '__EXE__' -ArgumentList ('--launch-id ' + '__LAUNCH__') -PassThru
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);' -Name Pointer -Namespace XDictLab
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $byId = {
        param($parent, $id)
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    }
    function Find-All {
        param($parent, $scope, $condition)
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try { return $parent.FindAll($scope, $condition) }
            catch { Start-Sleep -Milliseconds 500 }
        }
        throw 'UIA FindAll kept timing out'
    }
    $window = $null
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $window -and (Get-Date) -lt $deadline) {
        $windows = Find-All $root ([System.Windows.Automation.TreeScope]::Children) ([System.Windows.Automation.Condition]::TrueCondition)
        foreach ($candidate in $windows) { if ($candidate.Current.Name -eq 'XDict') { $window = $candidate; break } }
        if (-not $window) { Start-Sleep -Milliseconds 500 }
    }
    $result = [ordered]@{ window = $false; statusStartup = ''; rowsRun = -1
        backAfterFirst = $null; backAfterSecond = $null; backAfterAltLeft = $null; pane = $false; error = '' }
    Mark ('phase: window=' + ($null -ne $window))
    if ($window) {
        $result.window = $true
        $search = & $byId $window 'SearchBox'
        $list = & $byId $window 'Results'
        $back = & $byId $window 'BackButton'
        if (-not $back) { throw 'the Back button was not found' }
        $editCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
        $edit = $search.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
        function Set-Query([string]$text) {
            $set = $false
            for ($attempt = 0; $attempt -lt 20 -and -not $set; $attempt++) {
                try {
                    $pattern = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                    $pattern.SetValue($text)
                    $set = $true
                }
                catch { Start-Sleep -Milliseconds 500 }
            }
            if (-not $set) { throw 'the search box never accepted a value' }
            try { $edit.SetFocus() } catch { }
            Start-Sleep -Milliseconds 250
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Start-Sleep -Seconds 2
        }
        function Row-Count {
            return @(Find-All $list ([System.Windows.Automation.TreeScope]::Children) ([System.Windows.Automation.Condition]::TrueCondition)).Count
        }
        function Click-Row([int]$index) {
            $rows = @(Find-All $list ([System.Windows.Automation.TreeScope]::Children) ([System.Windows.Automation.Condition]::TrueCondition))
            if ($rows.Count -le $index) { return $false }
            $rect = $rows[$index].Current.BoundingRectangle
            if ($rect.IsEmpty) { return $false }
            [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(
                [int]($rect.X + $rect.Width / 2), [int]($rect.Y + $rect.Height / 2))
            Start-Sleep -Milliseconds 250
            [XDictLab.Pointer]::mouse_event(0x0002, 0, 0, 0, 0)
            [XDictLab.Pointer]::mouse_event(0x0004, 0, 0, 0, 0)
            Start-Sleep -Seconds 3
            return $true
        }
        Mark 'phase: query-run'
        Set-Query 'run'
        Mark 'phase: rows-run'
        $result.rowsRun = Row-Count
        $status = & $byId $window 'StatusText'
        if ($status) { $result.statusStartup = $status.Current.Name }
        if ($result.rowsRun -eq 0) {
            Mark 'phase: retry'
            Set-Query 'run'
            $result.rowsRun = Row-Count
        }
        Mark 'phase: click-1'
        $null = Click-Row 0
        Mark 'phase: back-1'
        $result.backAfterFirst = $back.Current.IsEnabled
        Mark 'phase: click-2'
        $null = Click-Row 1
        Mark 'phase: back-2'
        $result.backAfterSecond = $back.Current.IsEnabled
        try { $edit.SetFocus() } catch { }
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait('%{LEFT}')
        Start-Sleep -Seconds 2
        Mark 'phase: back-3'
        $result.backAfterAltLeft = $back.Current.IsEnabled
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
    $log = Join-Path $folder 'run.log'
    $script = $template.Replace('__LIBRARY__', $library).Replace('__LAUNCH__', $launchId).
        Replace('__EXE__', $exe).Replace('__RESULT__', $result).Replace('__QUIT__', $quit).Replace('__LOG__', $log)
    Set-Content -LiteralPath $wrapper -Value $script -Encoding Ascii

    try {
        $uia = Invoke-XDictTask -Script $wrapper -Output $result -Seconds 240
    }
    catch {
        if (Test-Path -LiteralPath $log) { Write-Host '--- run.log tail ---'; Get-Content -LiteralPath $log -Tail 25 }
        throw
    }
    Write-Host ($uia | ConvertTo-Json -Depth 6)
    if (-not $uia.window) { throw 'the trail run did not open the window' }
    if ($uia.rowsRun -lt 2) { throw 'the run query painted fewer than two rows' }
    if ([string]::IsNullOrWhiteSpace($uia.statusStartup)) { throw 'the window showed no status sentence' }
    if ($uia.backAfterFirst -ne $false) { throw 'Back was enabled after the first visit' }
    if ($uia.backAfterSecond -ne $true) { throw 'Back was not enabled after the second visit' }
    if ($uia.backAfterAltLeft -ne $false) { throw 'Alt+Left did not move the trail back' }
}
finally {
    # A timed-out wrapper leaves its app alive, holding a WebView2 folder; never let it poison the next run.
    Get-Process -Name XDict -ErrorAction SilentlyContinue | Stop-Process -Force
}
