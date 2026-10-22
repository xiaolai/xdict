# The unit gate: XDict.Tests through the real service, including the string catalogue, the launch probe and the
# app-output boundary (no core binary beside the app).
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

Invoke-XDictGate -Name 'test' -Full:$Full -Action {
    cargo fmt --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml') --check
    if ($LASTEXITCODE -ne 0) { throw 'the service formatting failed' }
    cargo test --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml')
    if ($LASTEXITCODE -ne 0) { throw 'the service unit tests failed' }
    cargo clippy --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml') --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw 'the service clippy gate failed' }
    . (Join-Path $PSScriptRoot 'service-fixtures.ps1')
    $env:XDICT_SERVICE = $layout.Service
    $env:XDICT_APP_OUTPUT = Get-XDictAppOutput -Configuration Debug
    $env:XDICT_CAPTURE = Join-Path $layout.RepoRoot 'conformance\capture'
    dotnet test (Join-Path $layout.AppRoot 'XDict.Tests\XDict.Tests.csproj') -c Debug --no-build `
        --filter 'FullyQualifiedName!~LibraryCorpusTests&FullyQualifiedName!~SearchCorpusTests'
    if ($LASTEXITCODE -ne 0) { throw 'the unit tests failed' }
} -Inputs @($layout.AppRoot, (Join-Path $layout.RepoRoot 'core'), (Join-Path $layout.RepoRoot 'conformance')) `
  -Extra @((& dotnet --version))
