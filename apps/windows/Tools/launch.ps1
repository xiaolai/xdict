# The launch stage: start the built app in the E2E host's interactive session, read what it got from the service,
# and quit it on request. The SSH session has no desktop, so the app is started through a scheduled task in the
# logged-on session; the app writes %LOCALAPPDATA%\XDict\launch\<id>.json itself. Evidence, not a cached gate.
[CmdletBinding()]
param(
    [string]$LaunchId = '',
    [string]$ExpectedHost = $env:XDICT_LAUNCH_HOST,
    [string]$App = '',
    [int]$TimeoutSeconds = 60
)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ([string]::IsNullOrWhiteSpace($ExpectedHost)) {
    # The host's name is machine configuration, never committed: the workspace's local.mk or the environment
    # supplies it. Without it this stage cannot tell the E2E host from any other machine.
    throw 'pass -ExpectedHost or set XDICT_LAUNCH_HOST (local.mk sets it on the E2E host)'
}
if ([string]::IsNullOrWhiteSpace($LaunchId)) { $LaunchId = [guid]::NewGuid().ToString('N') }

# Smart App Control gate: with it on, every locally built binary is refused at load (0x800711C7). Say so and stop;
# never read that as the product's failure.
$policy = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
    -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
if ($null -ne $policy -and $policy.VerifiedAndReputablePolicyState -eq 1) {
    Write-Error ('Smart App Control is on (VerifiedAndReputablePolicyState=1): this host refuses locally built ' +
        'binaries at load (0x800711C7), so a launch proves nothing. Turn it off or use another host.') -ErrorAction Continue
    exit 2
}

# The launch stage runs only on the E2E host: another machine's session proves another machine.
if ($env:COMPUTERNAME -ne $ExpectedHost) {
    Write-Error ("this launch stage runs only on $ExpectedHost (E2E_HOST_WINDOWS); this is $($env:COMPUTERNAME)") `
        -ErrorAction Continue
    exit 3
}

if ([string]::IsNullOrWhiteSpace($App)) {
    $App = Join-Path (Get-XDictAppOutput -Configuration Debug) 'XDict.exe'
}
if (-not (Test-Path -LiteralPath $App)) { throw "the app is not built: $App (run Tools\build.ps1)" }

$launchDirectory = Join-Path $env:LOCALAPPDATA 'XDict\launch'
New-Item -ItemType Directory -Force -Path $launchDirectory | Out-Null
$recordPath = Join-Path $launchDirectory ($LaunchId + '.json')
$quitPath = Join-Path $launchDirectory ($LaunchId + '.quit')
Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $quitPath -Force -ErrorAction SilentlyContinue

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskName = 'XDict-Launch-' + $LaunchId
$action = New-ScheduledTaskAction -Execute $App -Argument ('--launch-id ' + $LaunchId)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
Write-Host ("launch {0}: {1} as {2}" -f $LaunchId, $App, $user)
try {
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $recordPath)) {
        if ((Get-Date) -ge $deadline) {
            $info = Get-ScheduledTaskInfo -TaskName $taskName
            throw ("the app wrote no launch record within {0} s; the task's last result was 0x{1:X8}" -f
                $TimeoutSeconds, $info.LastTaskResult)
        }
        Start-Sleep -Milliseconds 250
    }

    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $errorProperty = $record.PSObject.Properties['error']
    if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
        throw ("the app could not reach the service: {0}" -f $errorProperty.Value)
    }
    $versionsProperty = $record.PSObject.Properties['versions']
    if ($null -eq $versionsProperty -or $null -eq $versionsProperty.Value) {
        throw 'the launch record carries no versions'
    }
    $versions = $versionsProperty.Value
    $servicePidProperty = $record.PSObject.Properties['servicePid']
    if ($null -ne $servicePidProperty -and $null -ne $servicePidProperty.Value) {
        Write-Host ("app process {0}, service process {1}" -f $record.pid, $servicePidProperty.Value)
    }
    Write-Host ("versions: core {0}, protocol {1}, index format {2}, normalization {3}" -f
        $versions.core, $versions.protocol, $versions.indexFormat, $versions.normalization)
    if ($versions.protocol -ne 1) { throw ("the service answered protocol {0}, expected 1" -f $versions.protocol) }
    if ([string]::IsNullOrWhiteSpace($versions.core)) { throw 'the service answered no core version' }

    Set-Content -LiteralPath $quitPath -Value '' -Encoding Ascii
    $deadline = (Get-Date).AddSeconds(10)
    while ($null -ne (Get-Process -Id $record.pid -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -ge $deadline) {
            Stop-Process -Id $record.pid -Force
            throw 'the app did not quit when asked, and was killed'
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host 'launch: pass (the app quit on request)'
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}
