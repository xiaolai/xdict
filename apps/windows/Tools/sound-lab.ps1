# The system voice and playback on the host: voices enumerated, plain and IPA renders measured, a real WAV played to
# the end, and a Chinese render. Run in the interactive session (speech needs it), never on the Air.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$started = Get-Date
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'sound-lab' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\sound-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $config = Join-Path $folder 'config.json'
    $result = Join-Path $folder 'result.json'
    @{ output = $result } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $sound = Invoke-XDictTask -Executable $exe -Arguments ('--sound-lab "' + $config + '"') -Output $result `
        -Seconds 120 -Prefix 'xdict-sound'
    Write-Host ($sound | ConvertTo-Json -Depth 5)
    if ($null -eq $sound.english) { throw 'no English voice was found' }
    if ($sound.plain -lt 1) { throw 'the plain render produced no bytes' }
    if ($sound.ipa -lt 1) { throw 'the IPA render produced no bytes' }
    if ($sound.chinese -lt 1) { throw 'the Chinese render produced no bytes' }
    if ($sound.played -ne $true) { throw 'the WAV did not play to its end' }
    Stop-XDictLabProcesses -Name @('XDict') -Since $started
}
