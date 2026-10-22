# Build the Rust service and the .NET solution, and copy the service beside the app. -Release is the bootstrap
# release build; bundle.ps1 publishes and stages it. The app's build fails when the service is missing.
[CmdletBinding()]
param([switch]$Full, [switch]$Release)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$configuration = if ($Release) { 'Release' } else { 'Debug' }

Invoke-XDictGate -Name ('build-' + $configuration.ToLower()) -Full:$Full -Action {
    if ($Release) {
        cargo build --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml') --release
    }
    else {
        cargo build --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml')
    }
    if ($LASTEXITCODE -ne 0) { throw 'the service did not build' }
    dotnet build (Join-Path $layout.AppRoot 'XDict.slnx') -c $configuration -warnaserror
    if ($LASTEXITCODE -ne 0) { throw 'the solution did not build' }
} -Inputs (Get-XDictBuildInputs -Layout $layout) `
  -Extra @($configuration, (& rustc --version), (& dotnet --version))

$output = Get-XDictAppOutput -Configuration $configuration
Write-Host ("app: {0}" -f (Join-Path $output 'XDict.exe'))
Write-Host ("service: {0}" -f (Join-Path $output 'XDictService.exe'))
