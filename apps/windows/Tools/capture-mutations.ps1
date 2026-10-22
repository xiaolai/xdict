# Each capture lifecycle rule is shown failing once against a mutation of that rule (lifecycle.md, "What each shell
# owes"): the source is mutated on the host, the rule's named test must go red for its own assertion, and the source is
# restored in a finally. A mutation the test survives is the failure this script reports.
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$model = Join-Path $layout.AppRoot 'XDict.Models\CaptureLifecycle.cs'
# 5.1's Get-Content/Set-Content misread a BOM-less UTF-8 file as ANSI and write a BOM back: the "restore" would
# corrupt the source it mutates. Read and write it byte-faithfully, and keep the round trip identical.
$utf8 = [System.Text.UTF8Encoding]::new($false)
$original = [System.IO.File]::ReadAllText($model, $utf8)
function Write-Model([string]$Text) { [System.IO.File]::WriteAllText($model, $Text, $utf8) }
$cases = @(
    @{ Rule = 1; Test = 'NumbersExistBeforeTheReadAndClaimingIsASecondAct'
       What = 'the numbering never advances'
       Old = 'issued += 1;'; New = 'issued += 0;' }
    @{ Rule = 2; Test = 'EveryRequestEndsExactlyOnce'
       What = 'an ended request can be ended again'
       Old = 'private bool IsEnded(int number) => ended.ContainsKey(number) || (number <= forgottenThrough && !open.ContainsKey(number));'
       New = 'private bool IsEnded(int number) => number <= forgottenThrough && !open.ContainsKey(number);' }
    @{ Rule = 3; Test = 'AStaleAnswerChangesNothing'
       What = 'an acknowledgement ignores its generation'
       Old = 'open.GetValueOrDefault(request.Number, -1) != generation'; New = 'open.GetValueOrDefault(request.Number, -1) == -1' }
    @{ Rule = 4; Test = 'AnInFlightReadIsCancelledByTheShortcutAndByEscape'
       What = 'a cancel ends nothing'
       Old = 'endedNow = End(request.Number, open.GetValueOrDefault(request.Number), CaptureOutcome.Cancelled);'
       New = 'endedNow = null;' }
)
$evidence = New-Object System.Collections.Generic.List[object]
$failures = 0
try {
    foreach ($case in $cases) {
        if (-not $original.Contains($case.Old)) { throw "mutation $($case.Rule): the source no longer holds: $($case.Old)" }
        Write-Model ($original.Replace($case.Old, $case.New))
        Push-Location $layout.AppRoot
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = (& dotnet test 'XDict.Tests\XDict.Tests.csproj' --filter ('FullyQualifiedName~' + $case.Test) 2>&1 | Out-String)
            $exit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
            Pop-Location
        }
        $red = $exit -ne 0 -and $output -match '\[FAIL\]' -and $output -match [regex]::Escape($case.Test) -and
            $output -notmatch 'error CS'
        $why = ''
        $match = [regex]::Match($output, '(?:错误消息|Error Message):\s*\r?\n\s*(.+)')
        if ($match.Success) { $why = $match.Groups[1].Value.Trim() }
        elseif ($output -match 'error CS') { $why = 'the mutation did not compile' }
        else { $why = 'the test passed' }
        $evidence.Add([ordered]@{ rule = $case.Rule; test = $case.Test; mutation = $case.What; red = $red; observed = $why })
        if (-not $red) { $failures++ }
        Write-Host ("rule {0}: {1,-55} {2}  {3}" -f $case.Rule, $case.What, $(if ($red) { 'RED' } else { 'SURVIVED' }), $why)
        Write-Model $original
    }
}
finally {
    Write-Model $original
    if ([System.IO.File]::ReadAllText($model, $utf8) -ne $original) {
        throw 'the capture model did not restore byte-faithfully'
    }
}
$folder = Join-Path $env:LOCALAPPDATA 'XDict\capture-mutations'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$report = Join-Path $folder 'mutations.json'
@{ date = (Get-Date -Format o); cases = $evidence } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "evidence: $report"
if ($failures -gt 0) { throw "$failures mutation(s) were not caught by their rule's test" }
