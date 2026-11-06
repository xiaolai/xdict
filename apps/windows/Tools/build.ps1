# Build the Rust service and the .NET solution, and copy the service beside the app. -Release is the bootstrap
# release build; bundle.ps1 publishes and stages it. The app's build fails when the service is missing.
[CmdletBinding()]
param([switch]$Full, [switch]$Release)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$configuration = if ($Release) { 'Release' } else { 'Debug' }

Invoke-XDictGate -Name ('build-' + $configuration.ToLower()) -Full:$Full -Action {
    # The service ships as one exe with no installer of its own: a dynamic CRT makes it import VCRUNTIME140.dll,
    # which a clean Windows 11 has no Visual C++ redistributable for. A fresh VM refused it at load with
    # 0xC0000135 before main (2026-11-06); static linking is what makes the bundle self-contained.
    $previousFlags = $env:RUSTFLAGS
    $serviceFlags = '-C target-feature=+crt-static'
    $env:RUSTFLAGS = if ([string]::IsNullOrWhiteSpace($previousFlags)) { $serviceFlags }
        else { $previousFlags + ' ' + $serviceFlags }
    try {
        if ($Release) {
            cargo build --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml') --release
        }
        else {
            cargo build --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml')
        }
        if ($LASTEXITCODE -ne 0) { throw 'the service did not build' }
    }
    finally { $env:RUSTFLAGS = $previousFlags }
    dotnet build (Join-Path $layout.AppRoot 'XDict.slnx') -c $configuration -warnaserror
    if ($LASTEXITCODE -ne 0) { throw 'the solution did not build' }
} -Inputs (Get-XDictBuildInputs -Layout $layout) `
  -Extra @($configuration, (& rustc --version), (& dotnet --version))

$output = Get-XDictAppOutput -Configuration $configuration
Write-Host ("app: {0}" -f (Join-Path $output 'XDict.exe'))
Write-Host ("service: {0}" -f (Join-Path $output 'XDictService.exe'))
