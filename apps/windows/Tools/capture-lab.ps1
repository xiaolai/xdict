# The live capture path on the Windows E2E host: the production hotkey over a real Notepad selection reaches the
# non-activating panel, Escape dismisses it and the next key stays with Notepad, the tray runs the same lookup, a
# rebinding survives a relaunch, a clash is reported, and an elevated window is refused with its sentence.
[CmdletBinding()]
param([switch]$Full, [switch]$SkipElevated, [string]$Only)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

function Invoke-MainPass {
    # 2. The main pass: the real chord over a Notepad selection.
    if (-not $Only -or $Only -eq 'main') {
    @{ output = (Join-Path $folder 'capture-result.json'); mode = 'main'; settings = $settings; library = $library; text = $html } |
        ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $main = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $config + '"') -Output (Join-Path $folder 'capture-result.json')
    Write-Host ($main | ConvertTo-Json -Depth 6)
    if ($main.PSObject.Properties['error']) { throw "the capture lab failed: $($main.error)" }
    if (-not $main.hotkeyRegistered) { throw 'the shortcut was not registered' }
    if (-not $main.trayVisible) { throw 'the tray icon was not shown' }
    if (-not $main.panelShown) { throw 'the chord produced no panel' }
    if ($main.panelMs -lt 0 -or $main.panelMs -gt 1000) { throw "the panel took $($main.panelMs) ms, over 1.0 s" }
    if ($main.term -ne 'run') { throw "the panel's term is '$($main.term)', expected run" }
    if (-not $main.focusUnchanged) { throw 'the panel took the foreground' }
    if (-not $main.targetForeground) { throw 'the foreground after the panel is not the host app' }
    if ($main.acknowledgement -ne 'Shown') { throw "the entry was not acknowledged: $($main.acknowledgement)" }
    if (-not $main.dismissedByEscape) { throw 'Escape did not dismiss the panel' }
    if (-not $main.targetStillForeground) { throw 'Escape did not return the foreground to Notepad' }
    if (-not $main.hostReceivedKey) { throw 'the key after Escape did not stay with the host app' }
    if (-not $main.panelShownAgain) { throw 'the second chord produced no panel for the click-away case' }
    if (-not $main.dismissedByClickAway) { throw 'a click outside the panel did not dismiss it' }
    if (-not $main.targetAfterClickAway) { throw 'the click-away did not leave the host app foreground' }
    if (-not $main.trayLookupShown) { throw 'the tray item ran no lookup' }
    if ($main.reboundModifiers -ne 7 -or $main.reboundKey -ne 75) { throw 'the rebinding was not kept' }
    if (-not $main.clashReported) { throw 'a taken combination was not reported' }
    if ($main.settingsAfterClash[0] -ne 7 -or $main.settingsAfterClash[1] -ne 75) { throw 'the clash disturbed the working combination' }

    }
}

function Invoke-NotepadPass {
    # 2b. The same path over Notepad (its WinUI menu bar holds focus first; the document is clicked on purpose).
    if (-not $Only -or $Only -eq 'notepad') {
    Stop-XDictLabProcesses -Name @('XDict', 'notepad', 'msedge', 'chrome') -Since $started
    $notepadConfig = Join-Path $folder 'notepad-config.json'
    @{ output = (Join-Path $folder 'notepad-result.json'); mode = 'notepad'; settings = $settings; library = $library; text = $text } |
        ConvertTo-Json | Set-Content -LiteralPath $notepadConfig -Encoding Ascii
    $notepadRun = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $notepadConfig + '"') -Output (Join-Path $folder 'notepad-result.json')
    Write-Host ($notepadRun | ConvertTo-Json -Depth 6)
    if ($notepadRun.PSObject.Properties['error']) { throw "the Notepad pass failed: $($notepadRun.error)" }
    if (-not $notepadRun.panelShown) { throw 'the Notepad chord produced no panel' }
    if ($notepadRun.panelMs -lt 0 -or $notepadRun.panelMs -gt 1000) { throw "the Notepad panel took $($notepadRun.panelMs) ms" }
    if ($notepadRun.term -ne 'run') { throw "the Notepad panel's term is '$($notepadRun.term)', expected run (refusal $($notepadRun.refusal); $($notepadRun.focusInfo))" }
    if ($notepadRun.acknowledgement -ne 'Shown') { throw "the Notepad entry was not acknowledged: $($notepadRun.acknowledgement)" }

    }
}

function Invoke-SuspendedPass {
    # 2b2. The panel with the dictionary service suspended: it must be on screen within the same second.
    if (-not $Only -or $Only -eq 'suspended') {
    Stop-XDictLabProcesses -Name @('XDict', 'notepad', 'msedge', 'chrome') -Since $started
    $suspendedConfig = Join-Path $folder 'suspended-config.json'
    @{ output = (Join-Path $folder 'suspended-result.json'); mode = 'suspended'; settings = $settings; library = $library; text = $html } |
        ConvertTo-Json | Set-Content -LiteralPath $suspendedConfig -Encoding Ascii
    $suspended = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $suspendedConfig + '"') -Output (Join-Path $folder 'suspended-result.json')
    Write-Host ($suspended | ConvertTo-Json -Depth 6)
    if (-not $suspended.panelShown) { throw 'the panel did not show with the service suspended' }
    if ($suspended.panelMs -lt 0 -or $suspended.panelMs -gt 1000) { throw "the suspended-service panel took $($suspended.panelMs) ms" }
    if ($suspended.term -ne 'run') { throw "the suspended-service panel's term is '$($suspended.term)'" }

    }
}

function Invoke-WordAndPdfPass {
    # 2c. Word, when it is installed: a .docx with the same sentence, its document selected through UIA.
    if (-not $Only -or $Only -eq 'word') {
    $wordExe = $null
    foreach ($candidate in @('C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE',
            'C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE')) {
        if (Test-Path -LiteralPath $candidate) { $wordExe = $candidate; break }
    }
    if ($wordExe) {
        Stop-XDictLabProcesses -Name @('XDict', 'notepad', 'msedge', 'chrome', 'WINWORD') -Since $started
        $docx = Join-Path $folder 'selection.docx'
        $pdf = Join-Path $folder 'selection.pdf'
        $makeDoc = Join-Path $folder 'make-doc.ps1'
        @'
$ErrorActionPreference = 'Stop'
$word = New-Object -ComObject Word.Application
$word.Visible = $false
try {
    $document = $word.Documents.Add()
    $document.Content.Text = 'The run reader selects this sentence.'
    $document.SaveAs2('__DOCX__', 16)
    $document.ExportAsFixedFormat('__PDF__', 17)
    $document.Close($false)
}
finally { $word.Quit() }
'@.Replace('__DOCX__', $docx).Replace('__PDF__', $pdf) | Set-Content -LiteralPath $makeDoc -Encoding Ascii
        $makeTask = 'xdict-make-doc-' + [Guid]::NewGuid().ToString('N')
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $makeDoc + '"')
        $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        try {
            Register-ScheduledTask -TaskName $makeTask -Action $action -Principal $principal | Out-Null
            Start-ScheduledTask -TaskName $makeTask
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            while (-not (Test-Path -LiteralPath $docx) -or -not (Test-Path -LiteralPath $pdf)) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'Word produced no document' }
                Start-Sleep -Milliseconds 500
            }
        }
        finally { Unregister-ScheduledTask -TaskName $makeTask -Confirm:$false -ErrorAction SilentlyContinue }
        # Word opened through COM: the Start screen and its first-run prompt are not in the way of the document.
        $wordHost = Join-Path $folder 'word-host.ps1'
        $ready = Join-Path $folder 'word-ready.txt'
        $stop = Join-Path $folder 'word-stop.txt'
        @'
$word = New-Object -ComObject Word.Application
$word.Visible = $true
$word.Documents.Open('__DOCX__') | Out-Null
Set-Content -LiteralPath '__READY__' -Value 'ready' -Encoding Ascii
while (-not (Test-Path -LiteralPath '__STOP__')) { Start-Sleep -Milliseconds 500 }
$word.Quit()
'@.Replace('__DOCX__', $docx).Replace('__READY__', $ready).Replace('__STOP__', $stop) |
            Set-Content -LiteralPath $wordHost -Encoding Ascii
        $hostTask = 'xdict-word-host-' + [Guid]::NewGuid().ToString('N')
        $hostAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $wordHost + '"')
        $hostPrincipal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $hostTask -Action $hostAction -Principal $hostPrincipal | Out-Null
        Start-ScheduledTask -TaskName $hostTask
        $hostDeadline = [DateTime]::UtcNow.AddSeconds(90)
        while (-not (Test-Path -LiteralPath $ready)) {
            if ([DateTime]::UtcNow -gt $hostDeadline) { throw 'Word opened no document window' }
            Start-Sleep -Milliseconds 500
        }
        try {
            $wordConfig = Join-Path $folder 'word-config.json'
            @{ output = (Join-Path $folder 'word-result.json'); mode = 'word'; settings = $settings; library = $library; text = $docx } |
                ConvertTo-Json | Set-Content -LiteralPath $wordConfig -Encoding Ascii
            $wordRun = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $wordConfig + '"') -Output (Join-Path $folder 'word-result.json')
        }
        finally {
            Set-Content -LiteralPath $stop -Value 'stop' -Encoding Ascii
            Start-Sleep -Seconds 2
            Unregister-ScheduledTask -TaskName $hostTask -Confirm:$false -ErrorAction SilentlyContinue
            Stop-XDictLabProcesses -Name @('WINWORD') -Since $started
        }
        Write-Host ($wordRun | ConvertTo-Json -Depth 6)
        if (-not $wordRun.panelShown -or $wordRun.term -ne 'run') {
            # Only a reader that exposes no text is an environment gap (Office unactivated overlays a sign-in
            # dialog); a run that fails any other way is a regression, never a skip.
            if ($wordRun.refusal -notin @('noTextPattern', 'noSelection')) {
                throw ("the Word capture regressed: term '$($wordRun.term)' refusal '$($wordRun.refusal)' -- $($wordRun.focusInfo)")
            }
            Write-Host ("WORD NOT MEASURED (the reader exposes no text): term '$($wordRun.term)' refusal '$($wordRun.refusal)'")
        }
        elseif ($wordRun.acknowledgement -ne 'Shown') { throw "the Word entry was not acknowledged: $($wordRun.acknowledgement)" }

        # 2d. A PDF in Edge's built-in reader, the word selected through the reader's own text pattern.
        Stop-XDictLabProcesses -Name @('XDict', 'msedge', 'chrome', 'WINWORD') -Since $started
        $pdfConfig = Join-Path $folder 'pdf-config.json'
        @{ output = (Join-Path $folder 'pdf-result.json'); mode = 'pdf'; settings = $settings; library = $library; text = $pdf } |
            ConvertTo-Json | Set-Content -LiteralPath $pdfConfig -Encoding Ascii
        $pdfRun = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $pdfConfig + '"') -Output (Join-Path $folder 'pdf-result.json')
        Write-Host ($pdfRun | ConvertTo-Json -Depth 6)
        if (-not $pdfRun.panelShown -or $pdfRun.term -ne 'run') {
            if ($pdfRun.refusal -notin @('noTextPattern', 'noSelection')) {
                throw ("the PDF capture regressed: term '$($pdfRun.term)' refusal '$($pdfRun.refusal)' -- $($pdfRun.focusInfo)")
            }
            Write-Host ("PDF NOT MEASURED (the viewer exposes no text): term '$($pdfRun.term)' refusal '$($pdfRun.refusal)'")
        }
    }
    else { Write-Host 'WORD NOT MEASURED: Word is not installed on this host' }
    }
}

function Invoke-RelaunchPass {
    # 3. A relaunch reads the rebinding back and the new chord works.
    if (-not $Only -or $Only -eq 'relaunch') {
    Stop-XDictLabProcesses -Name @('XDict', 'notepad', 'msedge', 'chrome') -Since $started
    Start-Sleep -Seconds 1
    $relaunchConfig = Join-Path $folder 'relaunch-config.json'
    @{ output = (Join-Path $folder 'relaunch-result.json'); mode = 'relaunch'; settings = $settings; library = $library; text = $html } |
        ConvertTo-Json | Set-Content -LiteralPath $relaunchConfig -Encoding Ascii
    $relaunch = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $relaunchConfig + '"') -Output (Join-Path $folder 'relaunch-result.json')
    Write-Host ($relaunch | ConvertTo-Json -Depth 6)
    if ($relaunch.PSObject.Properties['error']) { throw "the relaunch pass failed: $($relaunch.error)" }
    if ($relaunch.settingsModifiers -ne 7 -or $relaunch.settingsKey -ne 75) { throw 'the rebinding did not survive the relaunch' }
    if (-not $relaunch.panelShown -or $relaunch.term -ne 'run') { throw 'the rebound chord did not look up the selection' }
    }
}

function Invoke-ElevatedPass {
    # 4. An elevated window is refused with its sentence, never read.
    if ((-not $SkipElevated) -and (-not $Only -or $Only -eq 'elevated')) {
        Stop-XDictLabProcesses -Name @('XDict', 'notepad', 'msedge', 'chrome') -Since $started
        $elevatedTask = 'xdict-elevated-target-' + [Guid]::NewGuid().ToString('N')
        # The elevated target closes itself: a medium-integrity process cannot close an elevated window, and a
        # leftover elevated window would hold the foreground and deny the next stage's synthetic input.
        $elevatedScript = Join-Path $folder 'elevated-target.ps1'
        @'
$notepad = Start-Process -FilePath 'notepad.exe' -ArgumentList '"__TEXT__"' -PassThru
Start-Sleep -Seconds 180
try { if (-not $notepad.HasExited) { Stop-Process -Id $notepad.Id -Force } } catch { }
'@.Replace('__TEXT__', $text) | Set-Content -LiteralPath $elevatedScript -Encoding Ascii
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $elevatedScript + '"')
        $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
        $registered = $false
        try {
            try {
                Register-ScheduledTask -TaskName $elevatedTask -Action $action -Principal $principal | Out-Null
                Start-ScheduledTask -TaskName $elevatedTask
                $registered = $true
            }
            catch {
                # A process started by a scheduled task cannot register a Highest task (0x80070005). The elevated case
                # has its own evidence from an SSH session; this run records that it could not be reached here.
                Write-Host 'ELEVATED NOT MEASURED: a Highest task cannot be registered from this context'
            }
            if ($registered) {
                Start-Sleep -Seconds 3
                $elevatedConfig = Join-Path $folder 'elevated-config.json'
                @{ output = (Join-Path $folder 'elevated-result.json'); mode = 'elevated'; settings = $settings; library = $library; text = $text } |
                    ConvertTo-Json | Set-Content -LiteralPath $elevatedConfig -Encoding Ascii
                $elevated = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $elevatedConfig + '"') -Output (Join-Path $folder 'elevated-result.json')
                Write-Host ($elevated | ConvertTo-Json -Depth 6)
                if ($elevated.PSObject.Properties['error']) { throw ('the elevated capture failed: ' + $elevated.error) }
                elseif ($elevated.refusal -ne 'elevated') { throw "an elevated window was not refused: $($elevated.refusal)" }
            }
        }
        finally { Unregister-ScheduledTask -TaskName $elevatedTask -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

Invoke-XDictGate -Name 'capture-lab' -Inputs (Get-XDictLabInputs -Layout $layout) `
    -Extra @([string]$Only, [string]$SkipElevated) -Full:$Full -Action {
    Write-Host (Get-PSDrive C | Format-Table Name,Used,Free -AutoSize | Out-String)
    Get-Service sshd -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType | Format-Table -AutoSize | Out-String | Write-Host
    # A Surface on Modern Standby suspends the session mid-run; keep the machine awake for this run and no longer.
    Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);' -Name Power -Namespace XDictLab
    $stayAwake = [System.Convert]::ToUInt32('80000003', 16)
    $notNeeded = [System.Convert]::ToUInt32('80000000', 16)
    $null = [XDictLab.Power]::SetThreadExecutionState($stayAwake)
    try {
    Stop-XDictLabProcesses -Name @('XDict', 'notepad', 'msedge', 'chrome') -Since $started
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\capture-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    if (-not (Test-Path -LiteralPath $tiny)) { throw "the tiny fixture is missing: $tiny" }
    $library = Join-Path $folder 'library.json'
    $text = Join-Path $folder 'selection.txt'
    Set-Content -LiteralPath $text -Value 'The run reader selects this sentence.' -Encoding UTF8
    $html = Join-Path $folder 'selection.html'
    Set-Content -LiteralPath $html -Encoding UTF8 -Value @'
<!doctype html><html><head><meta charset="utf-8"><title>XDict capture lab</title></head>
<body style="font: 20px sans-serif; padding: 40px"><p id="line">The run reader selects this sentence.</p>
<script>
  function applySelection() {
    const line = document.getElementById('line');
    const text = line.firstChild.textContent;
    const start = text.indexOf('run');
    const range = document.createRange();
    range.setStart(line.firstChild, start);
    range.setEnd(line.firstChild, start + 3);
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }
  applySelection();
  // A click focuses the page but collapses the selection; the fixture puts it back, as a reader's drag would have.
  document.addEventListener('click', () => setTimeout(applySelection, 100));
</script></body></html>
'@
    $settings = Join-Path $folder 'capture.json'
    $config = Join-Path $folder 'capture-config.json'
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'

    # 1. A private library through the library lab.
    $libraryConfig = Join-Path $folder 'library-config.json'
    @{ output = (Join-Path $folder 'library-result.json'); library = $library; paths = @($tiny) } |
        ConvertTo-Json | Set-Content -LiteralPath $libraryConfig -Encoding Ascii
    $prepared = Invoke-XDictTask -Executable $exe -Arguments ('--library-lab "' + $libraryConfig + '"') -Output (Join-Path $folder 'library-result.json')
    if (-not (Test-Path -LiteralPath $library)) { throw 'the private library was not written' }
    Stop-XDictLabProcesses -Name @('XDict') -Since $started

    Invoke-MainPass

    Invoke-NotepadPass

    Invoke-SuspendedPass

    Invoke-WordAndPdfPass

    Invoke-RelaunchPass

    Invoke-ElevatedPass

    Stop-XDictLabProcesses -Name @('XDict', 'notepad', 'msedge', 'chrome') -Since $started
    }
    finally { $null = [XDictLab.Power]::SetThreadExecutionState($notNeeded) }
}
