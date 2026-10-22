# The capture contract's runner (CONTRACT.md §8): the value fixtures through the production constructor, the four
# lifecycle rules, and the privacy canary — the executed case ids, the count and the suite revision.
[CmdletBinding()]
param([switch]$Full)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$vectors = Join-Path $layout.RepoRoot 'conformance\capture\vectors.jsonl'
if (-not (Test-Path -LiteralPath $vectors)) { throw "the capture vectors are missing: $vectors" }
$ids = @(Get-Content -LiteralPath $vectors | Where-Object { $_.Trim() } | ForEach-Object {
    ($_ | ConvertFrom-Json).id })
$revision = (Get-FileHash -LiteralPath $vectors -Algorithm SHA256).Hash.ToLowerInvariant()

Invoke-XDictGate -Name 'capture-conformance' -Inputs @($vectors, (Join-Path $layout.AppRoot 'XDict.Models\Capture.cs'),
    (Join-Path $layout.AppRoot 'XDict.Models\CaptureLifecycle.cs'), (Join-Path $layout.AppRoot 'XDict.Tests'),
    $PSCommandPath, (Join-Path $PSScriptRoot 'gates.ps1')) -Full:$Full -Action {
    Push-Location $layout.AppRoot
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $trx = Join-Path $env:TEMP ('xdict-capture-' + [Guid]::NewGuid().ToString('N') + '.trx')
    try {
        $output = (& dotnet test 'XDict.Tests\XDict.Tests.csproj' --filter 'FullyQualifiedName~Capture' `
            --logger ('trx;LogFileName=' + $trx) 2>&1 | Out-String)
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        Pop-Location
    }
    Write-Host $output
    if ($exit -ne 0) { throw 'the capture suite is red' }
    if ($ids.Count -ne 58) { throw "the value suite holds $($ids.Count) cases, expected 58" }
    # The four rules and the canary are named checks, not an aggregate exit: a deleted test still left the suite green.
    $required = @('NumbersExistBeforeTheReadAndClaimingIsASecondAct', 'EveryRequestEndsExactlyOnce',
        'AStaleAnswerChangesNothing', 'AnInFlightReadIsCancelledByTheShortcutAndByEscape',
        'TheSentenceNeverLeavesTheSession')
    if (-not (Test-Path -LiteralPath $trx)) { throw 'the capture run left no trx report' }
    [xml]$results = [System.IO.File]::ReadAllText($trx, [System.Text.Encoding]::UTF8)
    $passed = @($results.TestRun.Results.UnitTestResult | Where-Object { $_.outcome -eq 'Passed' } |
        ForEach-Object { [string]$_.testName })
    $missing = @($required | Where-Object { $name = $_; -not ($passed | Where-Object { $_ -like ('*' + $name) }) })
    Remove-Item -LiteralPath $trx -Force -ErrorAction SilentlyContinue
    if ($missing.Count -gt 0) { throw ('the capture run did not execute: ' + ($missing -join ', ')) }
    Write-Host ''
    Write-Host ("capture-contract 1 | production constructor XDict.Models.CaptureValue | suite revision {0}" -f $revision)
    Write-Host ("value cases ({0}): {1}" -f $ids.Count, ($ids -join ', '))
    Write-Host 'lifecycle: NumbersExistBeforeTheReadAndClaimingIsASecondAct, EveryRequestEndsExactlyOnce, AStaleAnswerChangesNothing, AnInFlightReadIsCancelledByTheShortcutAndByEscape'
    Write-Host 'privacy canary: TheSentenceNeverLeavesTheSession'
    $folder = Join-Path $env:LOCALAPPDATA 'XDict\capture'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    @{ date = (Get-Date -Format o); contract = 1; cases = $ids; revision = $revision
       lifecycle = @('NumbersExistBeforeTheReadAndClaimingIsASecondAct', 'EveryRequestEndsExactlyOnce',
           'AStaleAnswerChangesNothing', 'AnInFlightReadIsCancelledByTheShortcutAndByEscape')
       canary = 'TheSentenceNeverLeavesTheSession' } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $folder 'report.json') -Encoding UTF8
}
