. (Join-Path $PSScriptRoot 'gates.ps1')
$folder = Join-Path $env:TEMP ('xdict-byte-control-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $folder | Out-Null
    $canary = 'xdict-private-sent-byte-control'
    @{ pass = $true; canary = $canary } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'result.json') -Encoding Ascii
    $bytes = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('POST / HTTP/1.1' + $canary))
    @{ constants = @{ logEventTypes = @{ SOCKET_BYTES_SENT = 1 } }; events = @(@{type = 1;phase = 0;source = @{id = 1};params = @{bytes = $bytes}}) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'netlog.json') -Encoding Ascii
    $detected = $false
    try { & (Join-Path $PSScriptRoot 'entry-netlog.ps1') -Folder $folder }
    catch { if ($_.Exception.Message -match 'Private dictionary marker reached sent bytes') { $detected = $true } else { throw } }
    if (-not $detected) { throw 'the byte observer accepted a private marker in sent network bytes' }
    Write-Host 'NetLog sent-byte control: pass (private marker rejected)'
}
finally { Remove-Item -LiteralPath $folder -Recurse -Force }
