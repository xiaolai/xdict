# The IPC conformance gate: the real service, started by the production client over the production pipe, answers the
# handshake and the typed refusals, then conformance/'s tiny and matrix suites through the dictionary operations. The
# runner refuses to run without --generated and --expected, and prints each suite's case count and the steps no
# operation reaches.
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'ipc-conformance' -Full:$Full -Action {
    # The fixtures are descriptions; the core's own writer makes the files, deterministically.
    $generated = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
    cargo run --quiet --manifest-path (Join-Path $layout.RepoRoot 'core\Cargo.toml') `
        -p xdict-conformance --bin conformance-fixtures -- $generated
    if ($LASTEXITCODE -ne 0) { throw 'the conformance fixtures did not write' }
    $runner = Get-XDictConformanceExe -Layout $layout
    & $runner --service $layout.Service --generated $generated --expected (Join-Path $layout.RepoRoot 'conformance\fixtures')
    if ($LASTEXITCODE -ne 0) { throw 'IPC conformance failed' }
} -Inputs @($layout.AppRoot, (Join-Path $layout.RepoRoot 'core'), (Join-Path $layout.RepoRoot 'conformance')) `
  -Extra @((& dotnet --version), (& rustc --version))
