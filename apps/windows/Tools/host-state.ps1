# What is running, which lab tasks are left, and the SSH server's own limits.
Get-Process -Name XDict, XDictService, notepad, msedge, chrome, WINWORD, powershell -ErrorAction SilentlyContinue |
    Select-Object Name, Id, StartTime, Responding | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
Get-ScheduledTask | Where-Object { $_.TaskName -like '*xdict*' } |
    Select-Object TaskName, State | Format-Table -AutoSize | Out-String | Write-Host
Get-Content 'C:\ProgramData\ssh\sshd_config' -ErrorAction SilentlyContinue |
    Select-String -Pattern 'MaxStartups', 'MaxSessions', 'LoginGraceTime', 'LogLevel' |
    ForEach-Object { Write-Host $_.Line }
