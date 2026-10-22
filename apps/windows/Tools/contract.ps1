# The contract-fixture gate: both sides decode, validate and re-encode every fixture (contract 1).
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout

Invoke-XDictGate -Name 'contract' -Full:$Full -Action {
    cargo test --manifest-path (Join-Path $layout.AppRoot 'contract\tests\rust\Cargo.toml')
    if ($LASTEXITCODE -ne 0) { throw 'the Rust fixture test failed' }
    dotnet test (Join-Path $layout.AppRoot 'contract\tests\cs\ContractTests.csproj') -c Debug
    if ($LASTEXITCODE -ne 0) { throw 'the C# fixture test failed' }
} -Inputs @((Join-Path $layout.AppRoot 'contract'), (Join-Path $layout.AppRoot 'XDict.Contract'), $PSCommandPath) `
  -Extra @((& dotnet --version), (& rustc --version))
