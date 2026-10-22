# The WI-11 protocol: a typed lookup's submit to the first paint, measured inside the production app (200 warm, 20
# cold), and the app's and service's working set with the library open. The UIA provider wedges under a long query
# loop (0x80131505), so the measurement runs in the app: the query goes into the production search box, the same
# SearchAsync runs, and the time is taken from the submit through the results being applied and the dispatcher's next
# turn — the first paint opportunity. OS input injection and UIA are outside the measurement; the record says so.
[CmdletBinding()]
param([int]$Warm = 200, [int]$Cold = 20, [string]$Corpus = '', [string]$Out = '', [string]$Library = '', [switch]$SkipImport)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ([string]::IsNullOrWhiteSpace($Corpus)) { $Corpus = Join-Path $env:USERPROFILE 'xdict-corpus\the24' }
if (-not (Test-Path -LiteralPath $Corpus)) { throw "the corpus is missing: $Corpus" }
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path $env:LOCALAPPDATA ('XDict\measure\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '\measure.json')
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
& (Join-Path $PSScriptRoot 'build.ps1')
if ($LASTEXITCODE -ne 0) { throw 'the build failed' }
$exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
$folder = Split-Path -Parent $Out
$library = if ([string]::IsNullOrWhiteSpace($Library)) { Join-Path $folder 'library.json' } else { $Library }
$queries = @('run', 'hold', 'cafe', 'take off', 'abb', 'window', 'reader', 'sentence', 'dictionary', 'oald')

function Invoke-Lab {
    param([string]$Arguments, [string]$Output, [int]$Seconds = 900)
    $id = 'xdict-measure-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $exe -Argument $Arguments
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $id -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $id
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
        while (-not (Test-Path -LiteralPath $Output)) {
            if ([DateTime]::UtcNow -gt $deadline) { return $null }
            Start-Sleep -Seconds 1
        }
        return (Get-Content -LiteralPath $Output -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    finally { Unregister-ScheduledTask -TaskName $id -Confirm:$false -ErrorAction SilentlyContinue }
}

function Invoke-MeasureApp {
    param([string]$Mode, [int]$Count, [string]$Output)
    $config = Join-Path $folder ('measure-' + $Mode + '-' + [Guid]::NewGuid().ToString('N') + '.json')
    @{ output = $Output; library = $library; mode = $Mode; count = $Count; queries = $queries } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $config -Encoding Ascii
    return Invoke-Lab -Arguments ('--measure-lab "' + $config + '" --client-deadline 180') -Output $Output
}

if (-not $SkipImport) {
    $paths = @(Get-ChildItem -LiteralPath $Corpus -Filter *.mdx -File -Recurse | Select-Object -ExpandProperty FullName)
    if ($paths.Count -eq 0) { throw "no .mdx files in $Corpus" }
    $imported = 0
    foreach ($path in $paths) {
        $oneConfig = Join-Path $folder ('library-config-' + $imported + '.json')
        $oneResult = Join-Path $folder ('library-result-' + $imported + '.json')
        @{ output = $oneResult; library = $library; paths = @($path) } |
            ConvertTo-Json | Set-Content -LiteralPath $oneConfig -Encoding Ascii
        $one = Invoke-Lab -Arguments ('--library-lab "' + $oneConfig + '" --client-deadline 300') -Output $oneResult -Seconds 600
        if ($null -eq $one) { Write-Host ("import timed out: " + (Split-Path -Leaf $path)) }
        elseif ($one.status -and $one.status -ne '') { Write-Host ("import " + (Split-Path -Leaf $path) + ": " + $one.status) }
        if (Test-Path -LiteralPath $library) { $imported = @((Get-Content -LiteralPath $library -Raw | ConvertFrom-Json)).Count }
    }
    Write-Host ("dictionaries in the measurement library: " + $imported)
    Get-Process -Name XDict, XDictService -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}
if (-not (Test-Path -LiteralPath $library)) { throw "the library to measure is missing: $library" }

$warmOutput = Join-Path $folder 'warm.json'
$warmRun = Invoke-MeasureApp -Mode 'warm' -Count $Warm -Output $warmOutput
if ($null -eq $warmRun) { throw 'the warm measurement produced no result' }
$coldSamples = New-Object System.Collections.Generic.List[object]
$coldOpens = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt $Cold; $i++) {
    Get-Process -Name XDict, XDictService -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    $coldOutput = Join-Path $folder ('cold-' + $i + '.json')
    $coldRun = Invoke-MeasureApp -Mode 'cold' -Count 1 -Output $coldOutput
    if ($null -eq $coldRun) { Write-Host ("cold sample $i produced no result"); continue }
    if ($coldRun.samples.Count -gt 0) { $coldSamples.Add($coldRun.samples[0]) }
    $coldOpens.Add([double]$coldRun.openMs)
}
if ($coldSamples.Count -lt $Cold) {
    throw "the cold measurement produced $($coldSamples.Count) of $Cold samples; p50/p95 over fewer would be a lie"
}
$memoryOutput = Join-Path $folder 'memory.json'
Get-Process -Name XDict, XDictService -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
$memory = Invoke-MeasureApp -Mode 'memory' -Count 0 -Output $memoryOutput
Get-Process -Name XDict, XDictService -ErrorAction SilentlyContinue | Stop-Process -Force

function Percentile($values, [double]$p) {
    $sorted = @($values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    $index = [Math]::Min($sorted.Count - 1, [Math]::Ceiling($p * $sorted.Count) - 1)
    return $sorted[$index]
}
$warmMs = @($warmRun.samples | ForEach-Object { [double]$_.ms })
$coldMs = @($coldSamples | ForEach-Object { [double]$_.ms })
$report = [ordered]@{
    date = (Get-Date -Format o)
    host = $env:COMPUTERNAME
    protocol = 'in-app: query submit -> results applied -> dispatcher next turn; UIA and input injection excluded'
    corpus = $Corpus
    dictionaries = $warmRun.dictionaries
    warm = @{ samples = $warmMs.Count; p50 = [math]::Round((Percentile $warmMs 0.5), 1); p95 = [math]::Round((Percentile $warmMs 0.95), 1); openMs = $warmRun.openMs }
    cold = @{ samples = $coldMs.Count; p50 = [math]::Round((Percentile $coldMs 0.5), 1); p95 = [math]::Round((Percentile $coldMs 0.95), 1); openP50 = [math]::Round((Percentile $coldOpens 0.5), 1); openP95 = [math]::Round((Percentile $coldOpens 0.95), 1) }
    memory = if ($null -ne $memory) { $memory } else { @{} }
    raw = @{ warm = $warmRun.samples; cold = $coldSamples }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Out -Encoding UTF8
Write-Host ("warm p50 {0} ms, p95 {1} ms ({2} samples, {3} dictionaries)" -f $report.warm.p50, $report.warm.p95, $report.warm.samples, $report.dictionaries)
Write-Host ("cold p50 {0} ms, p95 {1} ms ({2} samples); open p50 {3} ms p95 {4} ms" -f $report.cold.p50, $report.cold.p95, $report.cold.samples, $report.cold.openP50, $report.cold.openP95)
Write-Host ("memory: " + ($report.memory | ConvertTo-Json -Compress))
Write-Host ("measure: {0}" -f $Out)
