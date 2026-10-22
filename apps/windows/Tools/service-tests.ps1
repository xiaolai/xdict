# Narrow WI-4 iteration: no GUI and no builds on the editing machine.
[CmdletBinding()]
param([string]$Filter = 'FullyQualifiedName~ServiceLifecycleTests|FullyQualifiedName~SandboxTests|FullyQualifiedName~ContractMismatchTests|FullyQualifiedName~OutsideClientTests', [switch]$BuildService, [switch]$Probes, [switch]$FormatOnly)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ($FormatOnly) {
    cargo fmt --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml')
    exit $LASTEXITCODE
}
$env:XDICT_SERVICE = $layout.Service
$env:XDICT_OUTSIDE_CLIENT = Get-XDictConformanceExe -Layout $layout
dotnet build (Join-Path $layout.AppRoot 'XDict.Conformance\XDict.Conformance.csproj') -c Debug -warnaserror
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$env:XDICT_FIXTURES = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
if ($Probes) {
    . (Join-Path $PSScriptRoot 'service-fixtures.ps1')
}
$env:XDICT_PROBE_SERVICE = Join-Path $layout.AppRoot 'service\target\acceptance\XDictProbeService.exe'
$env:XDICT_FOREIGN_SERVICE = Join-Path $layout.AppRoot 'service\target\acceptance\XDictForeignService.exe'
if ($BuildService) {
    cargo fmt --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    cargo test --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    cargo build --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
dotnet test (Join-Path $layout.AppRoot 'XDict.Tests\XDict.Tests.csproj') -c Debug --filter $Filter
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
