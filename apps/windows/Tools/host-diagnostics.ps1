# Why an SSH session died mid-run: boot time, sleep and wake events, the disk, and the SSH server's own log.
[CmdletBinding()]
param([int]$Hours = 6)
$since = (Get-Date).AddHours(-$Hours)
Write-Host ('now: ' + (Get-Date -Format o))
Write-Host ('boot: ' + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime)
Get-PSDrive C | Format-Table Name, @{n = 'UsedGB'; e = { [math]::Round($_.Used / 1GB, 1) } },
    @{n = 'FreeGB'; e = { [math]::Round($_.Free / 1GB, 1) } } -AutoSize | Out-String | Write-Host
Get-Service sshd | Format-Table Name, Status, StartType -AutoSize | Out-String | Write-Host
Write-Host '--- power events (42 sleep, 107 resume, 1 wake) ---'
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 42, 107, 1; StartTime = $since } -ErrorAction SilentlyContinue |
    Select-Object -First 20 TimeCreated, Id, ProviderName, @{n = 'Message'; e = { $_.Message.Substring(0, [Math]::Min(160, $_.Message.Length)) } } |
    Format-Table -AutoSize | Out-String -Width 220 | Write-Host
Write-Host '--- OpenSSH operational ---'
Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, @{n = 'Message'; e = { $_.Message.Substring(0, [Math]::Min(160, $_.Message.Length)) } } |
    Format-Table -AutoSize | Out-String -Width 220 | Write-Host
