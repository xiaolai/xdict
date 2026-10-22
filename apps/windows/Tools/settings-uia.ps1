# Settings through UI Automation: the main window's Settings button opens one window whose three routes are named,
# selectable, and each shows its own controls. A route is also reached by keyboard from the navigation pane.
[CmdletBinding()]
param([switch]$Full, [int]$Scale = 0)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name ('settings-uia' + $(if ($Scale -gt 0) { '-' + $Scale } else { '' })) -Inputs (Get-XDictLabInputs -Layout $layout) -Extra @([string]$Scale) -Full:$Full -Action {
    $previousScale = $null
    if ($Scale -gt 0) {
        $read = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Accessibility')
        if ($read) { $previousScale = $read.GetValue('TextScaleFactor'); $read.Close() }
        $write = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility', $true)
        $write.SetValue('TextScaleFactor', $Scale, 'DWord')
        $write.Close()
        Write-Host "text scale set to $Scale (was $previousScale)"
        Start-Sleep -Seconds 1
    }
    try {
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\settings-uia\' + [Guid]::NewGuid().ToString('N'))
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
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
    Start-Sleep -Seconds 1

    $launchId = 'settings-' + [Guid]::NewGuid().ToString('N')
    $result = Join-Path $folder 'result.json'
    $quit = Join-Path $env:LOCALAPPDATA ('XDict\launch\' + $launchId + '.quit')
    $wrapper = Join-Path $folder 'run.ps1'
    $template = @'
$ErrorActionPreference = 'Stop'
$env:XDICT_LIBRARY = '__LIBRARY__'
$env:XDICT_SETTINGS = '__SETTINGS__'
$app = Start-Process -FilePath '__EXE__' -ArgumentList ('--launch-id ' + '__LAUNCH__') -PassThru
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
    function Find-Window([string]$id) {
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            foreach ($candidate in $root.FindAll([System.Windows.Automation.TreeScope]::Children,
                    [System.Windows.Automation.Condition]::TrueCondition)) {
                if ($candidate.Current.ProcessId -ne $app.Id) { continue }
                if (& $byId $candidate $id) { return $candidate }
            }
            Start-Sleep -Milliseconds 500
        }
        return $null
    }
    $result = [ordered]@{ main = $false; settings = $false; routes = @(); routeControls = @{}
        keyboardRoute = ''; error = '' }
    $main = Find-Window 'SearchBox'
    $result.main = $null -ne $main
    if ($main) {
        $button = & $byId $main 'LibraryButton'
        $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Seconds 2
    }
    $settings = Find-Window 'SettingsNav'
    $result.settings = $null -ne $settings
    if ($settings) {
        foreach ($id in 'SettingsDictionaries', 'SettingsReading', 'SettingsGeneral') {
            $item = & $byId $settings $id
            if ($item) { $result.routes += $id }
        }
        $controls = @{ SettingsDictionaries = 'AddFileButton'; SettingsReading = 'SettingsZoom'; SettingsGeneral = 'SettingsTheme' }
        foreach ($route in $controls.Keys) {
            $item = & $byId $settings $route
            if (-not $item) { continue }
            try { $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() }
            catch { try { $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { } }
            Start-Sleep -Milliseconds 600
            $control = & $byId $settings $controls[$route]
            $result.routeControls[$route] = $null -ne $control
        }
        # Keyboard: focus the first route and walk down with the Down key; the selected route must change. Synthetic
        # input is denied while another process holds the foreground (UIPI), so a denial is recorded, not fatal.
        $first = & $byId $settings 'SettingsDictionaries'
        try { $first.SetFocus() } catch { }
        Start-Sleep -Milliseconds 300
        try {
            [System.Windows.Forms.SendKeys]::SendWait('{DOWN}')
            Start-Sleep -Milliseconds 600
            $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
            $result.keyboardRoute = $focused.Current.AutomationId + ':' + $focused.Current.ControlType.ProgrammaticName
        }
        catch {
            $result.keyboardRoute = 'denied: ' + $_.Exception.Message
        }
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
    $settingsPath = Join-Path $folder 'app-settings.json'
    $script = $template.Replace('__LIBRARY__', $library).Replace('__SETTINGS__', $settingsPath).
        Replace('__LAUNCH__', $launchId).Replace('__EXE__', $exe).Replace('__RESULT__', $result).Replace('__QUIT__', $quit)
    Set-Content -LiteralPath $wrapper -Value $script -Encoding UTF8

    $uia = Invoke-XDictTask -Script $wrapper -Output $result -Seconds 240
    Write-Host ($uia | ConvertTo-Json -Depth 6)
    if ($uia.PSObject.Properties['error'] -and $uia.error) { throw "the settings harness failed: $($uia.error)" }
    if (-not $uia.main) { throw 'the main window was not found' }
    if (-not $uia.settings) { throw 'the Settings window did not open' }
    foreach ($id in 'SettingsDictionaries', 'SettingsReading', 'SettingsGeneral') {
        if ($uia.routes -notcontains $id) { throw "the Settings navigation has no $id" }
    }
    foreach ($route in 'SettingsDictionaries', 'SettingsReading', 'SettingsGeneral') {
        if (-not $uia.routeControls.$route) { throw "the $route route showed not its own control" }
    }
    if ($uia.keyboardRoute -eq '') { throw 'the keyboard did not move the route selection' }
    # A denied synthetic-key probe means the route was never exercised; passing it would make the check unfailable.
    if ($uia.keyboardRoute -like 'denied:*') { throw ('the keyboard route was not exercised: ' + $uia.keyboardRoute) }
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
    }
    finally {
        if ($Scale -gt 0) {
            $restore = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility', $true)
            # Absent before the run means Windows' own default; deleting the value is the restore, not leaving the test's.
            if ($null -ne $previousScale) {
                $restore.SetValue('TextScaleFactor', $previousScale, 'DWord')
                Write-Host "text scale restored to $previousScale"
            }
            else {
                $restore.DeleteValue('TextScaleFactor', $false)
                Write-Host 'text scale restored (it was absent before the run)'
            }
            $restore.Close()
        }
    }
}
