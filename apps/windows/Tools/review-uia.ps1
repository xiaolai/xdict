# Review through UI Automation: the tray-owned app opens the review window over a prepared library; reveal,
# grade, undo and save a note through the window's real controls. The app's --review-lab erases the learning store
# and writes one note so the queue has a card; the harness never calls the model directly.
[CmdletBinding()]
param([switch]$Full)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'review-uia' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    Stop-XDictLabProcesses -Name @('XDict')
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\review-uia\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    if (-not (Test-Path -LiteralPath $tiny)) { throw "the tiny fixture is missing: $tiny" }
    $library = Join-Path $folder 'library.json'
    $libraryConfig = Join-Path $folder 'library-config.json'
    @{ output = (Join-Path $folder 'library-result.json'); library = $library; paths = @($tiny) } |
        ConvertTo-Json | Set-Content -LiteralPath $libraryConfig -Encoding UTF8
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $null = Invoke-XDictTask -Executable $exe -Arguments ('--library-lab "' + $libraryConfig + '"') `
        -Output (Join-Path $folder 'library-result.json') -Seconds 120 -Prefix 'xdict-prep'
    Stop-XDictLabProcesses -Name @('XDict')
    Start-Sleep -Seconds 1

    $resultPath = Join-Path $folder 'result.json'
    $wrapper = Join-Path $folder 'run.ps1'
    # The driver reads its paths from a JSON file beside itself: no path is ever spliced into PowerShell source, where
    # an apostrophe would end the string and any quote would make the rest a command.
    $driverConfig = Join-Path $folder 'driver-config.json'
    $storageName = 'review-' + [Guid]::NewGuid().ToString('N')
    @{ library = $library; exe = $exe; storage = $storageName; result = $resultPath } |
        ConvertTo-Json | Set-Content -LiteralPath $driverConfig -Encoding UTF8
    $template = @'
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'driver-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$resultPath = $config.result
$env:XDICT_LIBRARY = $config.library
$app = Start-Process -FilePath $config.exe -ArgumentList '--review-lab', '--lab-storage', $config.storage -PassThru
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $byId = {
        param($parent, $id)
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    }
    function Find-Review {
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            foreach ($candidate in $root.FindAll([System.Windows.Automation.TreeScope]::Children,
                    [System.Windows.Automation.Condition]::TrueCondition)) {
                if ($candidate.Current.ProcessId -ne $app.Id) { continue }
                if (& $byId $candidate 'ReviewTitle') { return $candidate }
            }
            Start-Sleep -Milliseconds 500
        }
        return $null
    }
    function Invoke-ById([string]$id) {
        $control = & $byId $review $id
        if (-not $control) { return $false }
        $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 700
        return $true
    }
    function Name-ById([string]$id) {
        $control = & $byId $review $id
        if ($control) { return $control.Current.Name }
        return ''
    }
    $result = [ordered]@{ review = $false; word = ''; gloss = $false; graded = ''; undone = ''; note = '';
        noteSaved = ''; error = '' }
    $review = Find-Review
    $result.review = $null -ne $review
    if ($review) {
        $result.word = Name-ById 'ReviewWord'
        if (-not (Invoke-ById 'ReviewShowAnswer')) { throw 'the Show answer button was not found' }
        $result.gloss = $null -ne (& $byId $review 'ReviewGloss')
        if (-not (Invoke-ById 'ReviewGood')) { throw 'the Good answer was not found after the reveal' }
        $result.graded = Name-ById 'ReviewStatus'
        if (-not (Invoke-ById 'ReviewUndo')) { throw 'the Undo button was not found after a grade' }
        $result.undone = Name-ById 'ReviewStatus'
        $note = & $byId $review 'ReviewNote'
        if ($note) {
            try {
                $note.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('review note from UIA')
                Start-Sleep -Milliseconds 400
                if (-not (Invoke-ById 'ReviewSaveNote')) { throw 'the Save note button was not found' }
                $result.noteSaved = Name-ById 'ReviewNoteStatus'
            }
            catch { $result.error = $_.Exception.Message }
        }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
catch {
    @{ error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
finally {
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
'@
    Set-Content -LiteralPath $wrapper -Value $template -Encoding UTF8

    $uia = Invoke-XDictTask -Script $wrapper -Output $resultPath -Seconds 240
    Write-Host ($uia | ConvertTo-Json -Depth 6)
    if ($uia.PSObject.Properties['error'] -and $uia.error) { throw "the review harness failed: $($uia.error)" }
    if (-not $uia.review) { throw 'the review window did not open' }
    if ($uia.word -ne 'run') { throw "the review showed '$($uia.word)', not the seeded word" }
    if (-not $uia.gloss) { throw 'the answer had no gloss control after the reveal' }
    # The sentences are localized; Windows PowerShell reads this file as ANSI, so the Chinese words are built from
    # code points instead of written here (a UTF-8 byte can pair with the closing quote under GBK).
    $recorded = 'Recorded|' + [char]0x5DF2 + [char]0x8BB0 + [char]0x5F55
    $undone = 'Undone|' + [char]0x5DF2 + [char]0x64A4 + [char]0x9500
    $saved = 'Saved|' + [char]0x5DF2 + [char]0x4FDD + [char]0x5B58
    if ($uia.graded -notmatch $recorded) { throw "the grade did not report a record: '$($uia.graded)'" }
    if ($uia.undone -notmatch $undone) { throw "the undo did not report an undo: '$($uia.undone)'" }
    if ($uia.noteSaved -notmatch $saved) { throw "the note did not report a save: '$($uia.noteSaved)'" }
    Stop-XDictLabProcesses -Name @('XDict')
}
