# The capture-suite integrity gate: every value vector decodes and carries the contract's fields, and the suite's
# count never shrinks. The production constructor's run is WI-9's; this gate proves the suite that runner will read.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$capture = Join-Path $layout.RepoRoot 'conformance\capture'

Invoke-XDictGate -Name 'capture' -Full:$Full -Action {
    $vectors = Join-Path $capture 'vectors.jsonl'
    $lines = @(Get-Content -LiteralPath $vectors | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -lt 58) { throw "the suite has $($lines.Count) vectors; the contract's revision has at least 58" }
    $seen = @{}
    foreach ($line in $lines) {
        $vector = $line | ConvertFrom-Json
        foreach ($field in 'format', 'contract', 'id', 'op', 'input', 'expect') {
            # StrictMode throws on a missing property before the intended sentence could run.
            if (-not $vector.PSObject.Properties[$field]) { throw "a vector has no $field" }
        }
        if ($vector.format -ne 1) { throw "$($vector.id): format $($vector.format), expected 1" }
        if ($vector.contract -ne 1) { throw "$($vector.id): contract $($vector.contract), expected 1" }
        if ($seen.ContainsKey($vector.id)) { throw "the id $($vector.id) appears twice" }
        $seen[$vector.id] = $true
        if ($null -eq $vector.expect.status) { throw "$($vector.id): expect has no status" }
        if ($vector.expect.status -eq 'valid' -and $null -eq $vector.expect.value) {
            throw "$($vector.id): a valid expectation has no value"
        }
    }
    Write-Host ("capture suite: {0} vectors, {1} ids" -f $lines.Count, $seen.Count)
} -Inputs @($capture, $PSCommandPath)
