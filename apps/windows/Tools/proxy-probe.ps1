# WI-5 falsification probe: observe the proxy endpoint in addition to the target TCP and UDP canaries.
[CmdletBinding()]
param([ValidateSet('control','production','production-empty','production-preconnect')][string]$Mode = 'production')
. (Join-Path $PSScriptRoot 'gates.ps1')
$project = Join-Path $PSScriptRoot 'ProxyProbe\ProxyProbe.csproj'
dotnet build $project -c Release -warnaserror
if ($LASTEXITCODE -ne 0) { throw 'the proxy-observer probe did not build' }
$exe = Join-Path $PSScriptRoot 'ProxyProbe\bin\Release\net10.0-windows10.0.26100.0\ProxyProbe.exe'
$id = 'wi5-proxy-' + [Guid]::NewGuid().ToString('N')
$folder = Join-Path $env:LOCALAPPDATA ('XDict\security-probes\' + $id)
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$result = Join-Path $folder ('wv2-' + $Mode + '.json')
$taskName = 'XDict-' + $id
$action = New-ScheduledTaskAction -Execute $exe -Argument ($Mode + ' "' + $folder + '"')
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while (-not (Test-Path -LiteralPath $result)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'no proxy probe result from the interactive session' }
        Start-Sleep -Milliseconds 250
    }
    $text = Get-Content -LiteralPath $result -Raw -Encoding UTF8
    Write-Host $text
    Write-Host ('evidence: ' + $result)
    $record = $text | ConvertFrom-Json
    if ($record.PSObject.Properties.Name -contains 'error') { throw 'the interactive proxy probe failed' }
    if ($Mode.StartsWith('production') -and ($record.canaryHttp -ne 0 -or $record.canaryUdp -ne 0 -or $record.proxyConnections -ne 0)) {
        Write-Host 'WI-5 BLOCKER: the proposed production confinement permits a network connection'
        exit 1
    }
}
finally { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
