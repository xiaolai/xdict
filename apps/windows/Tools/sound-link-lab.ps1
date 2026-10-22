# The entry's sound links through the core: link resolves them, resource fetches the bytes, SoundSupport classifies
# the three outcomes (playable, Speex, missing). No audio is played: the fixture's recordings are not real audio.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'sound-link-lab' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    Get-Process -Name XDict -ErrorAction SilentlyContinue | Stop-Process -Force
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\sound-link\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $config = Join-Path $folder 'config.json'
    $result = Join-Path $folder 'result.json'
    @{ output = $result; fixtures = (Join-Path $env:LOCALAPPDATA 'XDict\library-fixtures') } |
        ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $id = 'xdict-sound-link-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $exe -Argument ('--sound-link-lab "' + $config + '"')
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $id -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $id
        $deadline = [DateTime]::UtcNow.AddSeconds(180)
        while (-not (Test-Path -LiteralPath $result)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'the sound link lab produced no result' }
            Start-Sleep -Milliseconds 250
        }
        $lab = Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ($lab | ConvertTo-Json -Depth 6)
        foreach ($link in $lab.links) { if ($link.type -ne 'sound') { throw "$($link.url) is $($link.type), not sound" } }
        $kinds = @{}
        foreach ($resource in $lab.resources) { $kinds[$resource.path] = $resource.kind }
        if ($kinds['here.mp3'] -ne 'Playable') { throw 'here.mp3 is not Playable' }
        if ($kinds['present.spx'] -ne 'Unsupported') { throw 'present.spx is not Unsupported' }
        if ($kinds['gone.mp3'] -ne 'Missing') { throw 'gone.mp3 is not Missing' }
    }
    finally {
        Unregister-ScheduledTask -TaskName $id -Confirm:$false -ErrorAction SilentlyContinue
        Get-Process -Name XDict -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}
