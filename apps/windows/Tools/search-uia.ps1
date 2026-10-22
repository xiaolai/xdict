# The main window through UI Automation: the production app starts in the interactive session with a prepared library,
# a UIA client in that session reads the tree, types into the search box, presses Enter and reads the results, then
# quits the app. UIA ids come from x:Name, so the check does not depend on the UI language.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'search-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\search-uia\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    if (-not (Test-Path -LiteralPath $tiny)) { throw "the tiny fixture is missing: $tiny" }
    $library = Join-Path $folder 'library.json'

    # 1. Register the fixture into a private library through the library window lab.
    $libraryConfig = Join-Path $folder 'library-config.json'
    @{ output = (Join-Path $folder 'library-result.json'); library = $library; paths = @($tiny) } |
        ConvertTo-Json | Set-Content -LiteralPath $libraryConfig -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $libraryTask = 'xdict-library-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('--library-lab "' + $libraryConfig + '"')
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $libraryTask -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $libraryTask
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        $libraryOutput = Join-Path $folder 'library-result.json'
        while (-not (Test-Path -LiteralPath $libraryOutput)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'the library preparation produced no result' }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $libraryTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $library)) { throw 'the private library was not written' }

    # 2. The in-session client: read the tree, type, read the results, quit the app.
    $launchId = 'uia-' + [Guid]::NewGuid().ToString('N')
    $result = Join-Path $folder 'result.json'
    $quit = Join-Path $env:LOCALAPPDATA ('XDict\launch\' + $launchId + '.quit')
    $wrapper = Join-Path $folder 'run.ps1'
    $template = @'
$ErrorActionPreference = 'Stop'
$env:XDICT_LIBRARY = '__LIBRARY__'
$launchId = '__LAUNCH__'
$app = Start-Process -FilePath '__EXE__' -ArgumentList ('--launch-id ' + $launchId) -PassThru
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $byId = {
        param($parent, $id)
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    }
    $window = $null
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $window -and (Get-Date) -lt $deadline) {
        $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($candidate in $windows) {
            if ($candidate.Current.Name -eq 'XDict') { $window = $candidate; break }
        }
        if (-not $window) { Start-Sleep -Milliseconds 500 }
    }
    $result = [ordered]@{ window = ($null -ne $window); ids = @(); roles = @{}; items = @(); statusNoMatch = '' }
    if ($window) {
        foreach ($id in 'SearchBox', 'ScopeBox', 'Results', 'BackButton', 'ForwardButton', 'ReturnButton', 'LibraryButton') {
            $element = & $byId $window $id
            if ($element) {
                $result.ids += $id
                $result.roles[$id] = $element.Current.ControlType.ProgrammaticName
            }
        }
        $search = & $byId $window 'SearchBox'
        $list = & $byId $window 'Results'
        if ($search) {
            $editCondition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit)
            $edit = $search.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
            $target = $search
            if ($edit) { $target = $edit }
            $value = $target.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $value.SetValue('cafe')
            try { $target.SetFocus() } catch { }
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Start-Sleep -Seconds 3
            if ($list) {
                $rows = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($row in $rows) { if ($row.Current.Name) { $result.items += $row.Current.Name } }
            }
            $value.SetValue('zzzz')
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Start-Sleep -Seconds 2
            $status = & $byId $window 'StatusText'
            if ($status) { $result.statusNoMatch = $status.Current.Name }
        }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
}
catch {
    ('ERROR: ' + ($_ | Out-String)) | Add-Content -LiteralPath '__LOG__'
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

    $uia = Invoke-XDictTask -Script $wrapper -Output $result -Seconds 180
    Write-Host ($uia | ConvertTo-Json -Depth 6)
    if ($uia.PSObject.Properties['error'] -and $uia.error) { throw "the search harness failed: $($uia.error)" }
    if (-not $uia.window) { throw 'the XDict window was not found through UIA' }
    $expectedRoles = @{
        SearchBox = 'ControlType.Group'; ScopeBox = 'ControlType.ComboBox'; Results = 'ControlType.List'
        BackButton = 'ControlType.Button'; ForwardButton = 'ControlType.Button'; ReturnButton = 'ControlType.Button'
        LibraryButton = 'ControlType.Button'
    }
    foreach ($id in $expectedRoles.Keys) {
        if ($uia.ids -notcontains $id) { throw "the UIA tree has no $id" }
        if ($uia.roles.$id -ne $expectedRoles[$id]) { throw "$id is $($uia.roles.$id), expected $($expectedRoles[$id])" }
    }
    if ([string]::IsNullOrWhiteSpace($uia.statusNoMatch)) { throw 'the no-match state was not announced' }
    if ($uia.statusNoMatch -match '^\d') { throw 'a miss announced a result count, not its state' }
    $cafe = 'caf' + [char]0x00E9
    $found = @($uia.items | Where-Object { $_ -like ('*' + $cafe + '*') })
    if ($found.Count -lt 1) { throw "typing cafe and pressing Enter painted no $cafe result" }

    # 3. The states announced: a ready dictionary, an unimported one and one whose file is gone.
    $statesLibrary = Join-Path $folder 'states.json'
    $parsed = Get-Content -LiteralPath $library -Raw -Encoding UTF8 | ConvertFrom-Json
    $records = New-Object System.Collections.Generic.List[object]
    if ($parsed -is [System.Array]) { foreach ($record in $parsed) { $records.Add($record) } }
    else { $records.Add($parsed) }
    $unimportedPath = Join-Path $folder 'unimported.mdx'
    Copy-Item -LiteralPath $tiny -Destination $unimportedPath
    $unimportedId = [Guid]::NewGuid().ToString('N')
    $records.Add([pscustomobject]@{
        edition = ''; lineage = ''; title = 'Unimported'; displayName = 'Unimported'; enabled = $true
        order = $records.Count; searchLanguage = 'en'; explainLanguage = 'en'
        files = @([pscustomobject]@{ id = $unimportedId; name = $unimportedId; role = 'mdx'; order = 0
            path = $unimportedPath; identity = $null })
    })
    $missingId = [Guid]::NewGuid().ToString('N')
    $records.Add([pscustomobject]@{
        edition = ''; lineage = ''; title = 'Missing'; displayName = 'Missing'; enabled = $true
        order = $records.Count; searchLanguage = 'en'; explainLanguage = 'en'
        files = @([pscustomobject]@{ id = $missingId; name = $missingId; role = 'mdx'; order = 0
            path = (Join-Path $folder 'absent.mdx'); identity = $null })
    })
    $records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statesLibrary -Encoding UTF8

    $statesLaunch = 'uia-states-' + [Guid]::NewGuid().ToString('N')
    $statesResult = Join-Path $folder 'states-result.json'
    $statesQuit = Join-Path $env:LOCALAPPDATA ('XDict\launch\' + $statesLaunch + '.quit')
    $statesWrapper = Join-Path $folder 'states.ps1'
    $statesTemplate = @'
$ErrorActionPreference = 'Stop'
$env:XDICT_LIBRARY = '__LIBRARY__'
$app = Start-Process -FilePath '__EXE__' -ArgumentList ('--launch-id ' + '__LAUNCH__') -PassThru
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $window = $null
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $window -and (Get-Date) -lt $deadline) {
        $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($candidate in $windows) { if ($candidate.Current.Name -eq 'XDict') { $window = $candidate; break } }
        if (-not $window) { Start-Sleep -Milliseconds 500 }
    }
    Start-Sleep -Seconds 3
    $status = $null
    if ($window) {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'StatusText')
        $status = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    }
    @{ window = ($null -ne $window); status = $(if ($status) { $status.Current.Name } else { '' }) } |
        ConvertTo-Json | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
}
finally {
    Set-Content -LiteralPath '__QUIT__' -Value '' -Encoding Ascii
    Start-Sleep -Seconds 2
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
'@
    $statesScript = $statesTemplate.Replace('__LIBRARY__', $statesLibrary).Replace('__LAUNCH__', $statesLaunch).
        Replace('__EXE__', $exe).Replace('__RESULT__', $statesResult).Replace('__QUIT__', $statesQuit)
    Set-Content -LiteralPath $statesWrapper -Value $statesScript -Encoding Ascii
    $states = Invoke-XDictTask -Script $statesWrapper -Output $statesResult -Seconds 180
    Write-Host ($states | ConvertTo-Json -Depth 4)
    if ($states.PSObject.Properties['error'] -and $states.error) { throw "the states harness failed: $($states.error)" }
    if (-not $states.window) { throw 'the states run did not open the window' }
    if ($states.status -notlike '*needsImport*') { throw 'the unimported state was not announced' }
    if ($states.status -notlike '*missing*') { throw 'the missing state was not announced' }
}
