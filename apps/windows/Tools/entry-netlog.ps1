# Chromium's own network log belongs to this fresh pane's browser environment. No browser restrictions are set.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Folder)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = Get-Content -LiteralPath (Join-Path $Folder 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$path = Join-Path $Folder 'netlog.json'
$deadline = [DateTime]::UtcNow.AddSeconds(15)
$log = $null
while ($null -eq $log) {
    try { $log = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { if ([DateTime]::UtcNow -gt $deadline) { throw "No completed browser NetLog: $path" }; Start-Sleep -Milliseconds 200 }
}
$types = @{}
foreach ($property in $log.constants.logEventTypes.PSObject.Properties) { $types[[string]$property.Value] = $property.Name }
$dns = New-Object System.Collections.Generic.List[object]
$control = ''
if ($result.PSObject.Properties['dnsControl']) { $control = [string]$result.dnsControl }
$byteControl = ''
if ($result.PSObject.Properties['byteControl']) { $byteControl = [string]$result.byteControl }
$byteControlSeen = $false
$canary = ''
if ($result.PSObject.Properties['canary']) { $canary = [string]$result.canary }
$observedControl = $false
$sentEvents = 0
$sentBytes = 0L
$tails = @{}
foreach ($event in $log.events) {
    $name = $types[[string]$event.type]
    if ($name -match 'BYTES_SENT' -and $event.PSObject.Properties['params'] -and $event.params.PSObject.Properties['bytes']) {
        $decoded = [Convert]::FromBase64String([string]$event.params.bytes)
        $sentEvents++
        $sentBytes += $decoded.Length
        if ($canary -or $byteControl) {
            $stream = ([string]$event.source.id) + ':' + $name
            $prefix = ''
            if ($tails.ContainsKey($stream)) { $prefix = $tails[$stream] }
            $text = $prefix + [System.Text.Encoding]::UTF8.GetString($decoded)
            if ($byteControl -and $text.Contains($byteControl)) { $byteControlSeen = $true }
            if ($canary -and $text.Contains($canary)) { throw 'Private dictionary marker reached sent bytes' }
            $keep = [Math]::Min([Math]::Max($canary.Length, $byteControl.Length) - 1, $text.Length)
            $tails[$stream] = $text.Substring($text.Length - $keep)
        }
    }
    if ($name -notmatch 'HOST_RESOLVER|DNS_') { continue }
    $parameters = ''
    if ($event.PSObject.Properties['params']) { $parameters = $event.params | ConvertTo-Json -Compress -Depth 30 }
    if ($control -and $parameters.Contains($control)) { $observedControl = $true }
    if ($canary -and $parameters.Contains($canary)) { throw 'Private dictionary marker reached a DNS operation' }
    $dns.Add(@{ event = $name; phase = $event.phase; source = $event.source; parameters = $parameters })
}
if ($byteControl -and -not $byteControlSeen) { throw 'The browser sent-byte positive control was not observed' }
if ($control -and -not $observedControl) { throw 'The browser DNS positive control was not observed' }
@{ byteControlSeen = $byteControlSeen; sentByteEvents = $sentEvents; sentBytes = $sentBytes; observer = 'per-environment Chromium NetLog'; control = $control; observedControl = $observedControl; dns = @($dns.ToArray()) } | ConvertTo-Json -Depth 35 | Set-Content -LiteralPath (Join-Path $Folder 'dns.json') -Encoding UTF8
Write-Host ('DNS attribution: events=' + $dns.Count + '; positive control=' + $observedControl + '; evidence=' + (Join-Path $Folder 'dns.json'))

Write-Host ('Sent-byte attribution: events=' + $sentEvents + '; bytes=' + $sentBytes)
