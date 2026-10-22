# Every Windows stage on one tree, in order, with a report: launch, service, contract, capture, library, lookup,
# sound, selection/panel/tray, setup in both text scales and the unit gates. Started detached so an SSH drop cannot
# end the run; the caller polls the report.
[CmdletBinding()]
param([switch]$Full, [string]$Only = '', [switch]$SkipElevated, [switch]$Detached, [string]$Report = '')
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$runStarted = Get-Date

$stages = @(
    @{ Name = 'build'; Script = 'build.ps1'; Args = @() },
    @{ Name = 'unit'; Script = 'test.ps1'; Args = @() },
    @{ Name = 'contract'; Script = 'contract.ps1'; Args = @() },
    @{ Name = 'ipc'; Script = 'conformance.ps1'; Args = @() },
    @{ Name = 'capture'; Script = 'capture-conformance.ps1'; Args = @() },
    @{ Name = 'library'; Script = 'library-corpus.ps1'; Args = @(); Full = $false },
    @{ Name = 'launch'; Script = 'launch.ps1'; Args = @(if ($env:XDICT_LAUNCH_HOST) { '-ExpectedHost', $env:XDICT_LAUNCH_HOST }); Full = $false },
    @{ Name = 'lookup'; Script = 'search-uia.ps1'; Args = @() },
    @{ Name = 'scope'; Script = 'search-scope-uia.ps1'; Args = @() },
    @{ Name = 'trail'; Script = 'trail-lab.ps1'; Args = @() },
    @{ Name = 'sound'; Script = 'sound-lab.ps1'; Args = @() },
    @{ Name = 'sound-links'; Script = 'sound-link-lab.ps1'; Args = @() },
    @{ Name = 'selection'; Script = 'capture-lab.ps1'; Args = @(if ($SkipElevated) { '-SkipElevated' }) },
    @{ Name = 'setup'; Script = 'settings-uia.ps1'; Args = @() },
    @{ Name = 'setup-225'; Script = 'settings-uia.ps1'; Args = @('-Scale', '225') }
)

# The release gate reads Get-XDictE2EStageNames; a table that drifts from it would demand evidence no run produces.
$declared = Get-XDictE2EStageNames
if (($stages.Name -join ',') -ne ($declared -join ',')) {
    throw 'the E2E stage table and Get-XDictE2EStageNames disagree'
}
if ($Only) {
    # A comma-separated list: the UIA stages run over SSH, the rest can run detached (each context has its own limits).
    $names = @($Only -split ',' | ForEach-Object { $_.Trim() })
    $stages = @($stages | Where-Object { $names -contains $_.Name })
}
if ($stages.Count -eq 0) { throw "no stage named $Only" }

if ($Detached) {
    if ([string]::IsNullOrWhiteSpace($Report)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $Report = Join-Path $env:LOCALAPPDATA ('XDict\e2e\' + $stamp + '\report.json')
    }
    # The marker tells a poll from a fresh request: a report without one is an old run, and a marker without a
    # report is a run still going. Without this, re-running with an old -Report silently replayed it.
    $marker = $Report + '.run'
    $polling = Test-Path -LiteralPath $marker
    if (Test-Path -LiteralPath $Report) {
        if (-not $polling) { throw "a report already exists at $Report; pass a new -Report for a fresh run" }
        $existing = Get-Content -LiteralPath $Report -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($stage in $existing.stages) {
            Write-Host ("{0,-12} {1,7:N1}s  {2}" -f $stage.name, ($stage.seconds), $(if ($stage.pass) { 'pass' } else { 'FAIL' }))
        }
        Write-Host ("E2E: {0} of {1} stages passed; report {2}" -f $existing.passed, $existing.total, $Report)
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        if ($existing.failed -gt 0) { throw ("$($existing.failed) E2E stage(s) failed") }
        return
    }
    $task = $null
    if (-not $polling) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Report) | Out-Null
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
            '-Report', ('"' + $Report + '"'))
        if ($Full) { $arguments += '-Full' }
        # The task command line is raw text: a value with a space must be quoted, as the inline branch does.
        if ($Only) { $arguments += @('-Only', ('"' + $Only + '"')) }
        if ($SkipElevated) { $arguments += '-SkipElevated' }
        $task = 'xdict-e2e-' + [Guid]::NewGuid().ToString('N')
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($arguments -join ' ')
        $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
        Set-Content -LiteralPath $marker -Value $task -Encoding Ascii
    }
    try {
        if ($task) { Start-ScheduledTask -TaskName $task }
        Write-Host ("started: {0}" -f $Report)
        $deadline = [DateTime]::UtcNow.AddMinutes(90)
        while (-not (Test-Path -LiteralPath $Report)) {
            if ([DateTime]::UtcNow -gt $deadline) {
                Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
                throw 'the E2E run produced no report'
            }
            Start-Sleep -Seconds 10
        }
        # The report is written once, at the end; a partial file is never trusted.
        $result = Get-Content -LiteralPath $Report -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($stage in $result.stages) {
            Write-Host ("{0,-12} {1,7:N1}s  {2}" -f $stage.name, ($stage.seconds), $(if ($stage.pass) { 'pass' } else { 'FAIL' }))
        }
        Write-Host ("E2E: {0} of {1} stages passed; report {2}" -f $result.passed, $result.total, $Report)
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        if ($result.failed -gt 0) { throw ("$($result.failed) E2E stage(s) failed") }
    }
    finally { if ($task) { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue } }
    return
}

# Inline execution (the SSH context the lab stages were built for): keep the machine awake for the run.
Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);' -Name Power -Namespace XDictLab
$stayAwake = [System.Convert]::ToUInt32('80000003', 16)
$notNeeded = [System.Convert]::ToUInt32('80000000', 16)
$null = [XDictLab.Power]::SetThreadExecutionState($stayAwake)
try {
if ([string]::IsNullOrWhiteSpace($Report)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Report = Join-Path $env:LOCALAPPDATA ('XDict\e2e\' + $stamp + '\report.json')
}
$reportDirectory = Split-Path -Parent $Report
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
$tree = Get-XDictTreeHash -Roots @($layout.AppRoot, (Join-Path $layout.RepoRoot 'core'), (Join-Path $layout.RepoRoot 'conformance')) -Exclude @('\\bin\\', '\\obj\\', '\\target\\', '\\out\\')
$records = New-Object System.Collections.Generic.List[object]
$failed = 0
foreach ($stage in $stages) {
    $log = Join-Path $reportDirectory ($stage.name + '.log')
    $started = Get-Date
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot $stage.Script)) + $stage.Args
    $acceptsFull = -not ($stage.ContainsKey('Full')) -or [bool]$stage.Full
    if ($Full -and $acceptsFull) { $arguments += '-Full' }
    # A child process per stage: a stage that exits, crashes or hangs is bounded and its output kept.
    $code = 1
    try {
        # No output redirection and no shared MSBuild server: a redirected pipe plus node reuse deadlocked a build
        # against the next stage's dotnet test (2026-10-22). The stage's console is the run's console.
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = 'powershell.exe'
        $info.Arguments = ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $info.UseShellExecute = $false
        $info.EnvironmentVariables['MSBUILDDISABLENODEREUSE'] = '1'
        $info.EnvironmentVariables['DOTNET_CLI_USE_MSBUILD_SERVER'] = '0'
        $process = [System.Diagnostics.Process]::Start($info)
        if (-not $process.WaitForExit(30 * 60 * 1000)) {
            try { $process.Kill() } catch { }
            $code = -1
        }
        else {
            $code = $process.ExitCode
        }
        Set-Content -LiteralPath ($log + '.out') -Encoding UTF8 -Value ("stage {0}: {1} in {2:N1}s; console output stays on the run console (never redirected: a pipe plus MSBuild node reuse deadlocked the next stage)" -f $stage.name, $(if ($code -eq 0) { 'pass' } else { "exit $code" }), ((Get-Date) - $started).TotalSeconds)
    }
    catch {
        $code = 1
        Set-Content -LiteralPath ($log + '.err') -Value $_.Exception.Message -Encoding UTF8
        # The report's log path must exist even when the stage could not start.
        Set-Content -LiteralPath ($log + '.out') -Encoding UTF8 -Value ("stage {0}: could not run ({1}); see the .err file" -f $stage.name, $_.Exception.Message)
    }
    $seconds = ((Get-Date) - $started).TotalSeconds
    $pass = $code -eq 0
    if (-not $pass) { $failed++ }
    $records.Add([ordered]@{ name = $stage.Name; seconds = [math]::Round($seconds, 1); pass = $pass; exit = $code; log = ($log + '.out') })
    Write-Host ("{0,-12} {1,7:N1}s  {2}" -f $stage.Name, $seconds, $(if ($pass) { 'pass' } else { "FAIL ($code)" }))
}
$os = Get-CimInstance Win32_OperatingSystem
$summary = [ordered]@{
    date = (Get-Date -Format o)
    host = $env:COMPUTERNAME
    os = ($os.Caption + ' ' + $os.Version + ' build ' + $os.BuildNumber)
    tree = $tree
    stages = $records
    total = $records.Count
    passed = $records.Count - $failed
    failed = $failed
}
Write-Host ("E2E report path: " + $Report)
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Report -Encoding UTF8
Write-Host ("E2E report written: " + (Test-Path -LiteralPath $Report))
Stop-XDictLabProcesses -Name @('XDict', 'XDictService', 'notepad', 'msedge', 'chrome', 'WINWORD') -Since $runStarted
if ($failed -gt 0) { exit 1 }
}
finally { $null = [XDictLab.Power]::SetThreadExecutionState($notNeeded) }
