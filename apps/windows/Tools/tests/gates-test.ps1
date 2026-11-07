# The gate runner's own test. A gate whose inputs change while it runs is not recorded: the key it would write names
# a tree that never passed, and the next run would skip it. The control, a gate whose inputs stay still, is recorded.
# The release's committed-tree check refuses a changed tree and a folder no commit names; a committed tree passes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'gates.ps1')

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('xdict-gates-test-' + [Guid]::NewGuid().ToString('N'))
$saved = $env:LOCALAPPDATA
$failures = New-Object System.Collections.Generic.List[string]
try {
    $env:LOCALAPPDATA = Join-Path $scratch 'cache'
    $inputs = Join-Path $scratch 'inputs'
    New-Item -ItemType Directory -Force -Path $inputs | Out-Null
    $source = Join-Path $inputs 'source.txt'
    Set-Content -LiteralPath $source -Value 'before'
    $cache = Get-XDictCacheDirectory

    $said = Invoke-XDictGate -Name 'edited' -Inputs @($inputs) -Action { Set-Content -LiteralPath $source -Value 'during' } 6>&1 |
        Out-String
    if (Test-Path -LiteralPath (Join-Path $cache 'edited.key')) {
        $failures.Add('a gate whose inputs changed during its run was recorded')
    }
    if ($said -notmatch 'edited: passed; NOT cached: the inputs changed during the run') {
        $failures.Add('the edited gate did not say why it was not cached: ' + $said.Trim())
    }

    Invoke-XDictGate -Name 'still' -Inputs @($inputs) -Action { } 6>&1 | Out-Null
    $key = Join-Path $cache 'still.key'
    if (-not (Test-Path -LiteralPath $key)) { $failures.Add('the control, a gate whose inputs stayed still, was not recorded') }
    elseif ((Get-Content -LiteralPath $key -Raw).Trim() -ne (Get-XDictTreeHash -Roots @($inputs))) {
        $failures.Add('the control recorded a key that is not its tree''s')
    }

    $repo = Join-Path $scratch 'repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'shipped.txt') -Value 'committed'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $repo init -q 2>$null
        & git -C $repo add shipped.txt 2>$null
        & git -C $repo -c user.name=gates-test -c user.email=gates-test@invalid commit -q -m committed 2>$null
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw 'the scratch repository could not be committed' }
    $refusal = { param($Root) try { Assert-XDictCommittedTree -Root $Root; '' } catch { $_.Exception.Message } }
    $said = & $refusal $repo
    if ($said) { $failures.Add('a committed tree was refused: ' + $said) }
    Set-Content -LiteralPath (Join-Path $repo 'shipped.txt') -Value 'edited'
    $said = & $refusal $repo
    if ($said -notmatch 'uncommitted change') { $failures.Add('a tree with an edited file was not refused: ' + $said) }
    & git -C $repo checkout -q -- shipped.txt
    Set-Content -LiteralPath (Join-Path $repo 'stray.txt') -Value 'untracked'
    $said = & $refusal $repo
    if ($said -notmatch 'uncommitted change') { $failures.Add('a tree with an untracked file was not refused: ' + $said) }
    $loose = Join-Path $scratch 'loose'
    New-Item -ItemType Directory -Force -Path $loose | Out-Null
    $said = & $refusal $loose
    if ($said -notmatch 'not a git checkout') { $failures.Add('a folder no commit names was not refused: ' + $said) }
}
finally {
    $env:LOCALAPPDATA = $saved
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($failure in $failures) { Write-Host ('FAIL: ' + $failure) }
if ($failures.Count -gt 0) { exit 1 }
Write-Host 'gates-test: pass'
