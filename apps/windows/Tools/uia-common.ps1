# The window search every UIA wrapper shares. WinUI's provider can stop answering FindAll once a WebView2 entry
# exists (a documented limit); the trail harness learned to retry and the other harnesses took the timeout raw.
# A caller that launched the app passes its process id; a name-only match could take another XDict window.
function Find-XDictWindow {
    # $ProcessId is the instance the caller launched: another XDict window on the same desktop is a different
    # process, and a stage that drives the wrong one proves nothing about this build.
    param($Root, [int]$Seconds = 60, [int]$ProcessId = 0)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $windows = $Root.FindAll([System.Windows.Automation.TreeScope]::Children,
                [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($candidate in $windows) {
                if ($candidate.Current.Name -eq 'XDict' -and
                    ($ProcessId -eq 0 -or $candidate.Current.ProcessId -eq $ProcessId)) { return $candidate }
            }
        }
        catch { }
        Start-Sleep -Milliseconds 500
    }
    return $null
}
