# Hover on the Windows E2E host (plan-windows-parity WS-P8): the key's rest reads the word under the pointer through
# UI Automation into the non-activating panel, the double-tap gesture reads it with the key up, the same rest without
# the key asks nothing, a window of ours under the pointer is read before the app behind it — and the Debug-only fault
# that skips that read shows the behind word, which is the rule's red-once control. Thresholds are declared here, once.
[CmdletBinding()]
param([switch]$Full)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

# Predeclared thresholds. A read is one UI Automation hit test plus the constructor; the panel includes the rest.
$MaxReadMs = 900
$MaxPanelMs = 1500
$MaxHookMicroseconds = 5000
$MaxIdleCpuPercent = 1.0

Invoke-XDictGate -Name 'hover' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\hover-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $library = Join-Path $folder 'library.json'
    $text = Join-Path $folder 'words.txt'
    # Two paragraphs: the first holds the word the gesture asks; the second puts `gamma` under the panel's term, so
    # the own-window case has a different word behind it to be red against.
    Set-Content -LiteralPath $text -Encoding UTF8 -Value @(
        'The run reader selects this sentence.',
        '',
        'alpha beta gamma delta epsilon zeta')
    # No dictionary: the hover stage proves the acquisition and the panel, not the entry draw. An entry view would
    # build a WebView2 on this process's UI thread, and the own-window read (which is this process's UI Automation)
    # would then wait on that same thread — a property of the harness, not of hover.
    Set-Content -LiteralPath $library -Value '[]' -Encoding UTF8
    Stop-XDictLabProcesses -Name @('XDict', 'notepad') -Since $started
    # Notepad is single-instance on Windows 11: a stale lab Notepad would take the file as a tab and the read would
    # look at another document. Lab-owned Notepads (their command line names this run's folder) are ended; **any other
    # Notepad is the person's**, and the stage refuses rather than touch it.
    $notepads = @(Get-CimInstance Win32_Process -Filter "Name='notepad.exe'" -ErrorAction SilentlyContinue)
    foreach ($stale in @($notepads | Where-Object { $_.CommandLine -like '*XDict\hover-lab*' })) {
        Stop-Process -Id $stale.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $foreign = @(Get-CimInstance Win32_Process -Filter "Name='notepad.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -notlike '*XDict\hover-lab*' })
    if ($foreign.Count -gt 0) {
        throw 'Notepad is open on the host; hover''s target must be the only instance. Close it and rerun.'
    }

    function Invoke-HoverPass([string]$Mode) {
        Stop-XDictLabProcesses -Name @('XDict', 'notepad') -Since $started
        Start-Sleep -Milliseconds 400
        $config = Join-Path $folder ($Mode + '-config.json')
        $result = Join-Path $folder ($Mode + '-result.json')
        @{ output = $result; mode = $Mode; settings = (Join-Path $folder ($Mode + '-capture.json'));
           library = $library; text = $text } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
        $run = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $config + '"') -Output $result `
            -Seconds 180 -Prefix ('xdict-hover-' + $Mode)
        Write-Host ($run | ConvertTo-Json -Depth 6)
        if ($run.PSObject.Properties['error']) { throw "the $Mode hover pass failed: $($run.error)" }
        return $run
    }

    function Assert-HoverCommon($run, [string]$Mode) {
        if (-not $run.hoverRunning) { throw "$Mode`: hover did not start" }
        if ($run.hoverStartFailed) { throw "$Mode`: Windows refused the pointer or key hooks" }
        if (-not $run.hoverShown) { throw "$Mode`: the rest produced no panel (outcome $($run.hoverLastOutcome))" }
        if ($run.hoverTerm -ne 'run') { throw "$Mode`: the term is '$($run.hoverTerm)', expected run" }
        if (-not $run.hoverFocusUnchanged) { throw "$Mode`: the panel took the foreground" }
        if ($run.hoverAck -ne 'Shown') { throw "$Mode`: the entry was not acknowledged: $($run.hoverAck)" }
        if (-not $run.hoverDismissedByEscape) { throw "$Mode`: Escape did not dismiss the panel" }
        if ($run.hoverPanelWithoutKey) { throw "$Mode`: a rest without the key produced a panel" }
        if ($run.hoverHookMicroseconds -gt $MaxHookMicroseconds) {
            throw ("$Mode`: a hook callback took $($run.hoverHookMicroseconds) us, over $MaxHookMicroseconds")
        }
        if ($run.hoverLastReadMs -gt $MaxReadMs) { throw "$Mode`: the read took $($run.hoverLastReadMs) ms, over $MaxReadMs" }
        if ($run.hoverPanelMs -lt 0 -or $run.hoverPanelMs -gt $MaxPanelMs) {
            throw "$Mode`: the panel took $($run.hoverPanelMs) ms, over $MaxPanelMs"
        }
        if ($run.hoverReadsStarted -ne 1) { throw "$Mode`: one rest started $($run.hoverReadsStarted) reads" }
        if ($run.hoverIdleCpuPercent -gt $MaxIdleCpuPercent) {
            throw "$Mode`: idle CPU is $($run.hoverIdleCpuPercent) %, over $MaxIdleCpuPercent"
        }
    }

    $hold = Invoke-HoverPass 'hover'
    Assert-HoverCommon $hold 'hover'
    if ($hold.hoverModifierDowns -lt 1) { throw 'hover: the key press reached no hook' }

    $double = Invoke-HoverPass 'hover-double'
    Assert-HoverCommon $double 'hover-double'
    if ($double.hoverGesture -ne 'DoubleTap') { throw 'hover-double: the gesture was not the double tap' }

    $own = Invoke-HoverPass 'hover-own'
    if ($own.PSObject.Properties['error']) { throw "the own-window pass failed: $($own.error)" }
    if (-not $own.ownPanel) { throw 'hover-own: the selection did not present a panel' }
    if ($own.ownHoverTerm -ne 'run') {
        throw "hover-own: the panel's own word was '$($own.ownHoverTerm)', expected run"
    }
    if ($own.ownBehindWord -ne 'gamma' -or $own.ownHoverTerm -eq $own.ownBehindWord) {
        throw "hover-own: the word behind ($($own.ownBehindWord)) was not distinct from the panel's ($($own.ownHoverTerm))"
    }
    if ($own.ownLastSource -ne 'XDict.exe') { throw "hover-own: the word came from $($own.ownLastSource), not XDict" }
    if ($own.ownReadMs -gt $MaxReadMs) { throw "hover-own: the read took $($own.ownReadMs) ms, over $MaxReadMs" }

    $skip = Invoke-HoverPass 'hover-own-skip'
    if ($skip.ownHoverTerm -ne 'gamma') {
        throw "hover-own-skip: the fault did not show the behind word (got '$($skip.ownHoverTerm)')"
    }
    if ($skip.ownLastSource -eq 'XDict.exe') { throw 'hover-own-skip: the fault still read XDict’s own window' }

    Stop-XDictLabProcesses -Name @('XDict', 'notepad') -Since $started
    Write-Host ("hover thresholds: read <= {0} ms, panel <= {1} ms, hook <= {2} us, idle CPU <= {3} %" -f `
        $MaxReadMs, $MaxPanelMs, $MaxHookMicroseconds, $MaxIdleCpuPercent)
}
