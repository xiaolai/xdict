# Native WinUI acceptance belongs in the interactive session, never the SSH desktop.
[CmdletBinding()]
param([string]$Mode = 'smoke')
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$id = 'entry-' + [Guid]::NewGuid().ToString('N')
$folder = Join-Path $env:LOCALAPPDATA ('XDict\entry-evidence\' + $id)
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$output = Join-Path $folder 'result.json'
$config = Join-Path $folder 'config.json'
@{ output = $output; mode = $Mode; corpus = (Get-XDictCorpus); fixtures = (Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'); cases = (Join-Path $layout.RepoRoot 'conformance\fixtures\hostile\cases.json') } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding Ascii
$exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
$action = New-ScheduledTaskAction -Execute $exe -Argument ('--entry-lab "' + $config + '"')
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
try {
    Register-ScheduledTask -TaskName $id -Action $action -Principal $principal | Out-Null
    Start-ScheduledTask -TaskName $id
    $seconds = 90
    if ($Mode.StartsWith('rtc')) { $seconds = 30 }
    if ($Mode.StartsWith('hostile') -or $Mode.StartsWith('corpus')) { $seconds = 1800 }
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    $nextProgress = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $output)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'the native entry harness produced no result' }
        if ([DateTime]::UtcNow -gt $nextProgress) {
            $progress = Join-Path $folder 'progress.json'
            if (Test-Path -LiteralPath $progress) { Write-Host (Get-Content -LiteralPath $progress -Raw) }
            $nextProgress = [DateTime]::UtcNow.AddSeconds(20)
        }
        Start-Sleep -Milliseconds 250
    }
    $text = Get-Content -LiteralPath $output -Raw -Encoding UTF8
    $result = $text | ConvertFrom-Json
    if ($result.pass) {
        $summary = [ordered]@{ pass = $result.pass }
        foreach ($property in 'runtime','dictionaries','refusals','crash','layer','escaped','left','loaded','preferences','font','bridge','word','large','rtc') {
            if ($result.PSObject.Properties[$property]) { $summary[$property] = $result.$property }
        }
        if ($result.PSObject.Properties['cases']) { $summary['cases'] = @($result.cases).Count }
        Write-Host ($summary | ConvertTo-Json -Depth 10)
    }
    else { Write-Host $text }
    Write-Host ('evidence: ' + $output)
    # `exit` here would end the calling script too, skipping every later mode; throw so the caller fails on its own.
    if (-not $result.pass) { throw 'the entry probe reported failure' }
    if ($result.PSObject.Properties['netlog']) { & (Join-Path $PSScriptRoot 'entry-netlog.ps1') -Folder $folder }
}
finally {
    # A timed-out owned probe must not leave its GUI process behind or lock the next build.
    if (-not (Test-Path -LiteralPath $output)) {
        Stop-ScheduledTask -TaskName $id -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $id -Confirm:$false -ErrorAction SilentlyContinue
}
