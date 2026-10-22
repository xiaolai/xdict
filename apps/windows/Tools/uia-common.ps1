# The window search every UIA wrapper shares. WinUI's provider can stop answering FindAll once a WebView2 entry
# exists (a documented limit); the trail harness learned to retry and the other harnesses took the timeout raw.
function Find-XDictWindow {
    param($Root, [int]$Seconds = 60)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $windows = $Root.FindAll([System.Windows.Automation.TreeScope]::Children,
                [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($candidate in $windows) {
                if ($candidate.Current.Name -eq 'XDict') { return $candidate }
            }
        }
        catch { }
        Start-Sleep -Milliseconds 500
    }
    return $null
}
