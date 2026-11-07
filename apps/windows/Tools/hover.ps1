# Hover on the Windows E2E host (plan-windows-parity WS-P8): the key's rest reads the word under the pointer through
# UI Automation into the non-activating panel, the double-tap gesture reads it with the key up, the same rest without
# the key asks nothing, a window of ours under the pointer is read before the app behind it — and the Debug-only fault
# that skips that read shows the behind word, which is the rule's red-once control.
#
# The read's fallbacks and refusals have their own passes, each a deterministic surface the lab makes (CaptureLab):
# pixels only (OCR), a dpi-unaware window (a scaled, DPI-virtualized surface), no OCR language, a stalled UIA provider,
# a stalled capture, and an elevated window (refused with its notice). Thresholds are declared here, once.
[CmdletBinding()]
param([switch]$Full, [switch]$SkipElevated)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

# Predeclared thresholds. A read is one UI Automation hit test plus the constructor; the panel includes the rest.
$MaxReadMs = 900
$MaxPanelMs = 1500
$MaxHookMicroseconds = 5000
$MaxIdleCpuPercent = 1.0
# The pixels fallback costs one window capture plus recognition (measured 190-290 ms on mbp16).
$MaxOcrReadMs = 2000
# The deadlines HoverReader declares: UiaDeadline 1.5 s, OcrDeadline 2.5 s. A stalled pass must exceed its deadline
# and stay inside the next one, so a change to either constant shows here.
$UiaDeadlineMs = 1500
$OcrDeadlineMs = 2500
$StallCeilingMs = 4000

Invoke-XDictGate -Name 'hover' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\hover-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $library = Join-Path $folder 'library.json'
    # **Named for this run.** Notepad restores its tabs, and a tab is found by the file name it shows: a name that
    # every run reuses cannot tell this run's fixture from a restored one (measured 2026-11-07).
    $runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $text = Join-Path $folder ('words-' + $runId + '.txt')
    # The pixels passes draw this whole file as one word, so it holds the word alone.
    $pixelsText = Join-Path $folder ('pixels-' + $runId + '.txt')
    # Two paragraphs: the first holds the word the gesture asks; the second puts `gamma` under the panel's term, so
    # the own-window case has a different word behind it to be red against.
    Set-Content -LiteralPath $text -Encoding UTF8 -Value @(
        'The run reader selects this sentence.',
        '',
        'alpha beta gamma delta epsilon zeta')
    Set-Content -LiteralPath $pixelsText -Value 'Hover' -Encoding UTF8 -NoNewline
    # No dictionary: the hover stage proves the acquisition and the panel, not the entry draw. An entry view would
    # build a WebView2 on this process's UI thread, and the own-window read (which is this process's UI Automation)
    # would then wait on that same thread — a property of the harness, not of hover.
    Set-Content -LiteralPath $library -Value '[]' -Encoding UTF8
    # Any previous run's lab app is ours too; the marker names the shared hover-lab root, not this run's folder.
    Stop-XDictLabProcesses -Name @('XDict', 'notepad') -Marker 'XDict\hover-lab'
    # Notepad is single-instance on Windows 11: a stale lab Notepad would take the file as a tab and the read would
    # look at another document. Lab-owned Notepads (their command line names this run's folder) are ended; **any other
    # Notepad is the person's**, and the stage refuses rather than touch it.
    function Expand-NotepadCommand([string]$CommandLine) {
        # Windows 11's packaged Notepad carries the document in a base64 UTF-16 /SESSION: argument, so the path is
        # not visible to a match on the command line itself.
        if ($CommandLine -and $CommandLine -match '/SESSION:([A-Za-z0-9+/=]+)') {
            try { return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) }
            catch { return $CommandLine }
        }
        return $CommandLine
    }
    $notepads = @(Get-CimInstance Win32_Process -Filter "Name='notepad.exe'" -ErrorAction SilentlyContinue |
        Select-Object ProcessId, @{ Name = 'CommandLine'; Expression = { Expand-NotepadCommand $_.CommandLine } })
    foreach ($stale in @($notepads | Where-Object { $_.CommandLine -like '*XDict\hover-lab*' })) {
        Stop-Process -Id $stale.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $foreign = @($notepads | Where-Object { $_.CommandLine -notlike '*XDict\hover-lab*' })
    if ($foreign.Count -gt 0) {
        throw 'Notepad is open on the host; hover''s target must be the only instance. Close it and rerun.'
    }

    function Invoke-HoverPass([string]$Mode, [string]$PassText = $text, [string]$Press = '', [switch]$KeepNotepad) {
        # The elevated pass owns its Notepad: the launcher started it and the launcher ends it, so the pass must not
        # stop it here (this session can kill an elevated process, and doing so leaves the lab without a target).
        # A browser a failed capture pass left behind is a lab window over the surface: the read would name it.
        $stopNames = if ($KeepNotepad) { @('XDict', 'msedge', 'chrome') } else { @('XDict', 'notepad', 'msedge', 'chrome') }
        Stop-XDictLabProcesses -Name $stopNames -Marker $folder
        Start-Sleep -Milliseconds 400
        $config = Join-Path $folder ($Mode + '-config.json')
        $result = Join-Path $folder ($Mode + '-result.json')
        $body = @{ output = $result; mode = $Mode; settings = (Join-Path $folder ($Mode + '-capture.json'));
                   library = $library; text = $PassText }
        if ($Press) { $body.press = $Press }
        $body | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8
        $run = Invoke-XDictTask -Executable $exe -Arguments ('--capture-lab "' + $config + '"') -Output $result `
            -Seconds 180 -Prefix ('xdict-hover-' + $Mode)
        Write-Host ($run | ConvertTo-Json -Depth 6)
        if ($run.PSObject.Properties['error']) { throw "the $Mode hover pass failed: $($run.error)" }
        return $run
    }

    function Assert-SpecialCommon($run, [string]$Mode) {
        if (-not $run.specialRunning) { throw "$Mode`: hover did not start" }
        if ($run.specialStartFailed) { throw "$Mode`: Windows refused the pointer or key hooks" }
        if ($run.specialHookMicroseconds -gt $MaxHookMicroseconds) {
            throw ("$Mode`: a hook callback took $($run.specialHookMicroseconds) us, over $MaxHookMicroseconds")
        }
        if ($run.specialEvents -lt 1) { throw "$Mode`: the key never reached a hook" }
    }

    # The pixels surface: the pointer is over the lab's wordless window, and a cloaked overlay covers the same point.
    # Both facts are asserted, so a pass cannot turn green by reading the overlay or the desktop instead.
    function Assert-PixelsSurface($run, [string]$Mode) {
        # The lab's own overlay, above the surface and cloaked by DWM. Its read-back is asserted first: an overlay
        # that failed to cloak would leave the skip rule unexercised while some other window satisfied the search.
        if (-not $run.overlayCloaked) {
            throw "$Mode`: the lab's overlay was not cloaked (set result $($run.overlaySet), window '$($run.overlayWindow)')"
        }
        if ([string]::IsNullOrEmpty($run.cloakedAbove)) {
            throw "$Mode`: no cloaked window above the target covered the point; the skip rule was not exercised"
        }
        if ($run.pointWindow -notmatch '^XDict\.exe/XDictCaptureLabPixels/') {
            throw "$Mode`: the window under the point was '$($run.pointWindow)', not the lab's pixels window"
        }
    }

    # A negative pass expects no word at all, and the product is right to read the first ordinary app behind the
    # surface. Any app there makes the fixture — not the product — the thing that failed, so it is named.
    function Assert-NothingBehind($run, [string]$Mode) {
        if (-not [string]::IsNullOrEmpty($run.behindWindow)) {
            throw "$Mode`: '$($run.behindWindow)' is behind the surface and would answer; close it and rerun"
        }
    }

    function Assert-OcrWord($run, [string]$Mode) {
        if (-not $run.specialShown) { throw "$Mode`: no panel (outcome $($run.specialOutcome))" }
        if ($run.specialTerm -ne 'Hover') { throw "$Mode`: the recognised term is '$($run.specialTerm)', expected Hover" }
        if ($run.specialAcquisition -ne 'recognition') {
            throw "$Mode`: the word came by $($run.specialAcquisition), not recognition"
        }
        if ($run.specialSource -ne 'XDict.exe') { throw "$Mode`: the word came from $($run.specialSource)" }
        if ($run.specialReadMs -gt $MaxOcrReadMs) { throw "$Mode`: the read took $($run.specialReadMs) ms, over $MaxOcrReadMs" }
        if ($run.specialPanelMs -lt 0 -or $run.specialPanelMs -gt $MaxPanelMs) {
            throw "$Mode`: the panel took $($run.specialPanelMs) ms, over $MaxPanelMs"
        }
        if ($run.specialAck -ne 'Shown') { throw "$Mode`: the entry was not acknowledged: $($run.specialAck)" }
        if (-not $run.specialRequest) { throw "$Mode`: the panel carries no acknowledgement request" }
    }

    # The pointer must be where the pass put it: another input source (a person on the console, a remote mouse)
    # moves it, the reader sees movement between the two taps, and the pass would report a gesture fault that is not
    # the product's. Measured 2026-11-07: the cursor sat at (1915,1038) while the point was (325,383).
    function Assert-PointerHeld($run, [string]$Mode) {
        if ($null -eq $run.hoverCursor -or $null -eq $run.hoverPoint) { return }
        $dx = [Math]::Abs([int]$run.hoverCursor[0] - [int]$run.hoverPoint[0])
        $dy = [Math]::Abs([int]$run.hoverCursor[1] - [int]$run.hoverPoint[1])
        if ($dx -gt 2 -or $dy -gt 2) {
            throw ("$Mode`: the pointer was moved out from under the pass (wanted ($($run.hoverPoint[0])," +
                "$($run.hoverPoint[1])), found ($($run.hoverCursor[0]),$($run.hoverCursor[1]))); " +
                'the host was in use — rerun when it is idle')
        }
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
    Assert-PointerHeld $hold 'hover'
    Assert-HoverCommon $hold 'hover'
    if ($hold.hoverModifierDowns -lt 1) { throw 'hover: the key press reached no hook' }

    $double = Invoke-HoverPass 'hover-double'
    Assert-PointerHeld $double 'hover-double'
    Assert-HoverCommon $double 'hover-double'
    if ($double.hoverGesture -ne 'DoubleTap') { throw 'hover-double: the gesture was not the double tap' }

    $own = Invoke-HoverPass 'hover-own'
    if ($own.PSObject.Properties['error']) { throw "the own-window pass failed: $($own.error)" }
    if (-not $own.ownPanel) { throw 'hover-own: the selection did not present a panel' }
    # The hover case only runs once the planned word and the panel's term have been placed; without either the pass
    # proved nothing, so each is a named failure rather than a missing property.
    if ($null -eq $own.ownPlannedRect) {
        throw "hover-own: the planned word '$($own.ownPlannedWord)' had no rectangle in the document"
    }
    if (-not $own.ownTermRectFound) {
        throw "hover-own: the panel's term rectangle was not found (planned word '$($own.ownPlannedWord)')"
    }
    if ($own.ownHoverTerm -ne 'run') {
        throw "hover-own: the panel's own word was '$($own.ownHoverTerm)', expected run"
    }
    if ($own.ownBehindWord -ne 'gamma' -or $own.ownHoverTerm -eq $own.ownBehindWord) {
        throw "hover-own: the word behind ($($own.ownBehindWord)) was not distinct from the panel's ($($own.ownHoverTerm))"
    }
    if ($own.ownLastSource -ne 'XDict.exe') { throw "hover-own: the word came from $($own.ownLastSource), not XDict" }
    if ($own.ownReadMs -gt $MaxReadMs) { throw "hover-own: the read took $($own.ownReadMs) ms, over $MaxReadMs" }
    if (-not $own.ownHoverRequest -or $own.ownHoverAck -ne 'Shown') {
        throw "hover-own: the hover produced no fresh acknowledged request (request $($own.ownHoverRequest), ack $($own.ownHoverAck))"
    }

    $skip = Invoke-HoverPass 'hover-own-skip'
    if ($null -eq $skip.ownPlannedRect) {
        throw "hover-own-skip: the planned word '$($skip.ownPlannedWord)' had no rectangle in the document"
    }
    if (-not $skip.ownTermRectFound) {
        throw "hover-own-skip: the panel's term rectangle was not found (planned word '$($skip.ownPlannedWord)')"
    }
    if ($skip.ownHoverTerm -ne 'gamma') {
        throw "hover-own-skip: the fault did not show the behind word (got '$($skip.ownHoverTerm)')"
    }
    if ($skip.ownLastSource -eq 'XDict.exe') { throw 'hover-own-skip: the fault still read XDict’s own window' }

    # The OCR fallback, on a window that exposes nothing to Accessibility (a plain Win32 surface drawing one word).
    $ocr = Invoke-HoverPass 'hover-ocr' $pixelsText
    Assert-SpecialCommon $ocr 'hover-ocr'
    Assert-PixelsSurface $ocr 'hover-ocr'
    Assert-OcrWord $ocr 'hover-ocr'

    # The same window from a dpi-unaware thread: the system scales its surface, so its pixels are not screen pixels.
    # This is the mixed-DPI hazard a second monitor with another scale would also produce; the E2E host has one
    # scaled display, so a dpi-unaware window is the case it can make. The monitor must actually be scaled, or the
    # pass would prove nothing.
    $dpi = Invoke-HoverPass 'hover-unaware' $pixelsText
    Assert-SpecialCommon $dpi 'hover-unaware'
    Assert-PixelsSurface $dpi 'hover-unaware'
    Assert-OcrWord $dpi 'hover-unaware'
    if ($dpi.pixelsMonitorDpi -lt 120) {
        throw "hover-unaware: the monitor runs at $($dpi.pixelsMonitorDpi) dpi; a dpi-unaware window is not scaled there"
    }

    # No recogniser language: the read says so, with its notice, and shows no panel.
    $noOcr = Invoke-HoverPass 'hover-noocr' $pixelsText
    Assert-SpecialCommon $noOcr 'hover-noocr'
    Assert-PixelsSurface $noOcr 'hover-noocr'
    Assert-NothingBehind $noOcr 'hover-noocr'
    if ($noOcr.specialShown) { throw 'hover-noocr: a panel was drawn without a recogniser' }
    if ($noOcr.specialOutcome -ne 'miss:ocrUnavailable') {
        throw "hover-noocr: the outcome is '$($noOcr.specialOutcome)', expected miss:ocrUnavailable"
    }
    if ($noOcr.specialNotice -ne 'ocrUnavailable') { throw "hover-noocr: the notice is '$($noOcr.specialNotice)'" }

    # A UIA provider that never answers: the read is abandoned at its deadline and the pixels answer. Recovery is read
    # from a UIA-only window (a blank surface whose word is its title): OCR cannot produce it, so the word proves the
    # worker answered again, and StuckReads proves the lane's own state, not only a panel that appeared.
    $stallUia = Invoke-HoverPass 'hover-stall-uia' $pixelsText
    Assert-SpecialCommon $stallUia 'hover-stall-uia'
    Assert-PixelsSurface $stallUia 'hover-stall-uia'
    if (-not $stallUia.specialShown) { throw 'hover-stall-uia: the pixels did not answer after the abandonment' }
    if ($stallUia.specialAcquisition -ne 'recognition') {
        throw "hover-stall-uia: the word came by $($stallUia.specialAcquisition)"
    }
    if ($stallUia.specialReadMs -lt $UiaDeadlineMs -or $stallUia.specialReadMs -gt $StallCeilingMs) {
        throw "hover-stall-uia: the read took $($stallUia.specialReadMs) ms, expected $UiaDeadlineMs-$StallCeilingMs"
    }
    if (-not $stallUia.specialDismissed) { throw 'hover-stall-uia: the first panel was still up before recovery' }
    if (-not $stallUia.recoveryShown -or $stallUia.recoveryTerm -ne 'resume') {
        throw "hover-stall-uia: the UIA-only recovery read did not answer (shown=$($stallUia.recoveryShown), term=$($stallUia.recoveryTerm))"
    }
    # A text-pattern word from the UIA-only edit: the pixels of that surface are white on white.
    if ($stallUia.recoveryAcquisition -ne 'textRange') {
        throw "hover-stall-uia: the recovery word came by '$($stallUia.recoveryAcquisition)', not the UIA lane"
    }
    if ([int]$stallUia.recoveryStuckReads -ne 0) {
        throw "hover-stall-uia: the worker still counts $($stallUia.recoveryStuckReads) abandoned reads after it answered"
    }
    if ([int]$stallUia.recoveryRequest -le [int]$stallUia.specialRequest) {
        throw "hover-stall-uia: recovery was not a new request ($($stallUia.recoveryRequest))"
    }
    if ($stallUia.recoveryReadMs -gt $MaxOcrReadMs) {
        throw "hover-stall-uia: the recovery read took $($stallUia.recoveryReadMs) ms"
    }

    # A capture that holds its lane past the deadline: no panel, the honest refusal, and the lane answers again after.
    $stallOcr = Invoke-HoverPass 'hover-stall-ocr' $pixelsText
    Assert-SpecialCommon $stallOcr 'hover-stall-ocr'
    Assert-PixelsSurface $stallOcr 'hover-stall-ocr'
    Assert-NothingBehind $stallOcr 'hover-stall-ocr'
    if ($stallOcr.specialShown) { throw 'hover-stall-ocr: a panel was drawn while the capture was stuck' }
    if ($stallOcr.specialOutcome -ne 'miss:captureStuck') {
        throw "hover-stall-ocr: the outcome is '$($stallOcr.specialOutcome)', expected miss:captureStuck"
    }
    if ($stallOcr.specialReadMs -lt $OcrDeadlineMs -or $stallOcr.specialReadMs -gt $StallCeilingMs) {
        throw "hover-stall-ocr: the read took $($stallOcr.specialReadMs) ms, expected $OcrDeadlineMs-$StallCeilingMs"
    }
    if (-not $stallOcr.specialDismissed) { throw 'hover-stall-ocr: a panel was still up before recovery' }
    if (-not $stallOcr.recoveryShown -or $stallOcr.recoveryTerm -ne 'Hover') {
        throw "hover-stall-ocr: the lane did not answer again (shown=$($stallOcr.recoveryShown), term=$($stallOcr.recoveryTerm))"
    }
    if ([int]$stallOcr.recoveryRequest -le [int]$stallOcr.specialRequest) {
        throw "hover-stall-ocr: recovery was not a new request ($($stallOcr.recoveryRequest))"
    }
    if ($stallOcr.recoveryReadMs -gt $MaxOcrReadMs) {
        throw "hover-stall-ocr: the recovery read took $($stallOcr.recoveryReadMs) ms"
    }

    # An elevated window under the pointer: the reader names the refusal, shows its notice, and draws no panel. The
    # key comes from the elevated launcher, because UIPI withholds a synthetic key from a hook while an elevated
    # window holds the foreground — the launcher hands the foreground back to this process first.
    if ($SkipElevated) {
        Write-Host 'ELEVATED NOT MEASURED: -SkipElevated was given; the elevated refusal was not exercised'
    }
    if (-not $SkipElevated) {
    $press = Join-Path $folder 'elevated.press'
    $stop = Join-Path $folder 'elevated.stop'
    $ready = Join-Path $folder 'elevated.json'
    $launcher = Join-Path $folder 'elevated-target.ps1'
    $launcherConfig = Join-Path $folder 'elevated-target.config.json'
    Remove-Item $press, $stop, $ready, $launcherConfig -Force -ErrorAction SilentlyContinue
    # Paths travel as data. The launcher runs elevated, so no path is ever spliced into its source: an apostrophe in
    # a profile path would otherwise end a PowerShell string and inject commands into an elevated process.
    @{ text = $text; press = $press; stop = $stop; ready = $ready } | ConvertTo-Json |
        Set-Content -LiteralPath $launcherConfig -Encoding UTF8
    @'
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HoverElevated {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static IntPtr FindNotepad() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            var name = new StringBuilder(128);
            GetClassName(h, name, 128);
            if (name.ToString() == "Notepad") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@
$notepad = Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $config.text + '"') -PassThru
$handle = [IntPtr]::Zero
for ($i = 0; $i -lt 80 -and $handle -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 250
    $handle = [HoverElevated]::FindNotepad()
}
$placed = $false
[uint32]$owner = 0
if ($handle -ne [IntPtr]::Zero) {
    # Topmost: nothing the medium-integrity lab raises may cover the point under test.
    $placed = [HoverElevated]::SetWindowPos($handle, [IntPtr](-1), 100, 100, 900, 600, 0x0040 -bor 0x0010)
    [HoverElevated]::GetWindowThreadProcessId($handle, [ref]$owner) | Out-Null
}
@{ pid = $notepad.Id; owner = $owner; handle = $handle.ToInt64(); placed = $placed } | ConvertTo-Json |
    Set-Content -LiteralPath $config.ready -Encoding UTF8
try {
    for ($i = 0; $i -lt 180 -and -not (Test-Path -LiteralPath $config.stop); $i++) {
        if (Test-Path -LiteralPath $config.press) {
            $value = Get-Content -LiteralPath $config.press -Raw
            Remove-Item -LiteralPath $config.press -Force
            [long]$handleValue = 0
            if ([long]::TryParse($value.Trim(), [ref]$handleValue) -and $handleValue -ne 0) {
                [HoverElevated]::SetForegroundWindow([IntPtr]$handleValue) | Out-Null
                Start-Sleep -Milliseconds 600
            }
            [HoverElevated]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Seconds 4
            [HoverElevated]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    # Only the processes this launcher started: the window's owner and the process it launched. A Notepad that was
    # already open is never touched (the stage refuses to start when one is).
    foreach ($target in @([int]$owner, $notepad.Id)) {
        if ($target -gt 0) { Stop-Process -Id $target -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $config.stop -Force -ErrorAction SilentlyContinue
}
'@ | Set-Content -LiteralPath $launcher -Encoding Ascii
    $task = 'xdict-hover-elevated-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" "' + $launcherConfig + '"')
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Highest
    try {
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $task
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $ready)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'the elevated target did not report itself' }
            Start-Sleep -Milliseconds 250
        }
        $elevated = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
        if (-not $elevated.placed) { throw 'the elevated target could not be placed topmost' }
        $refused = Invoke-HoverPass 'hover-elevated' $text $press -KeepNotepad
        Assert-SpecialCommon $refused 'hover-elevated'
        if ($refused.specialShown) { throw 'hover-elevated: an elevated window was read and a panel drawn' }
        if ($refused.specialOutcome -ne 'miss:elevated') {
            throw "hover-elevated: the outcome is '$($refused.specialOutcome)', expected miss:elevated"
        }
        if ($refused.specialNotice -ne 'elevated') { throw "hover-elevated: the notice is '$($refused.specialNotice)'" }
        if ($refused.specialReadMs -gt $MaxReadMs) {
            throw "hover-elevated: the refusal took $($refused.specialReadMs) ms"
        }
        if ($refused.pointWindow -notmatch '^Notepad\.exe/Notepad/') {
            throw "hover-elevated: the window under the point was '$($refused.pointWindow)', not the elevated Notepad"
        }
    }
    finally {
        New-Item -ItemType File -Path $stop -Force -ErrorAction SilentlyContinue | Out-Null
        # The launcher removes the stop file after its own cleanup; wait for that before unregistering.
        for ($i = 0; $i -lt 120 -and (Test-Path -LiteralPath $stop); $i++) { Start-Sleep -Milliseconds 250 }
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 40 -and $elevated.owner -gt 0 -and
        (Get-Process -Id $elevated.owner -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
    if ($elevated.owner -gt 0 -and (Get-Process -Id $elevated.owner -ErrorAction SilentlyContinue)) {
        throw 'the elevated target did not exit'
    }
    }

    Stop-XDictLabProcesses -Name @('XDict', 'notepad') -Marker $folder
    Write-Host ("hover thresholds: read <= {0} ms, panel <= {1} ms, hook <= {2} us, idle CPU <= {3} %, ocr read <= {4} ms" -f `
        $MaxReadMs, $MaxPanelMs, $MaxHookMicroseconds, $MaxIdleCpuPercent, $MaxOcrReadMs)
}
