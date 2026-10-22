# The system voice and playback on the host: voices enumerated, plain and IPA renders measured, a real WAV played to
# the end, and a Chinese render. Run in the interactive session (speech needs it), never on the Air.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'sound-lab' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    Get-Process -Name XDict -ErrorAction SilentlyContinue | Stop-Process -Force
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\sound-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $config = Join-Path $folder 'config.json'
    $result = Join-Path $folder 'result.json'
    @{ output = $result } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $id = 'xdict-sound-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('--sound-lab "' + $config + '"')
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $id -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $id
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while (-not (Test-Path -LiteralPath $result)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'the sound lab produced no result' }
            Start-Sleep -Milliseconds 250
        }
        $sound = Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ($sound | ConvertTo-Json -Depth 5)
        if ($null -eq $sound.english) { throw 'no English voice was found' }
        if ($sound.plain -lt 1) { throw 'the plain render produced no bytes' }
        if ($sound.ipa -lt 1) { throw 'the IPA render produced no bytes' }
        if ($sound.chinese -lt 1) { throw 'the Chinese render produced no bytes' }
        if ($sound.played -ne $true) { throw 'the WAV did not play to its end' }
    }
    finally {
        Unregister-ScheduledTask -TaskName $id -Confirm:$false -ErrorAction SilentlyContinue
        Get-Process -Name XDict -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}
