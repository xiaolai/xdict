# Test-only artifacts. No probes are compiled into the service copied beside XDict.exe.
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$env:XDICT_OUTSIDE_CLIENT = Get-XDictConformanceExe -Layout $layout
$env:XDICT_FIXTURES = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
cargo run --quiet --manifest-path (Join-Path $layout.RepoRoot 'core\Cargo.toml') -p xdict-conformance --bin conformance-fixtures -- $env:XDICT_FIXTURES
if ($LASTEXITCODE -ne 0) { throw 'the generated service fixtures failed' }
$env:XDICT_LIBRARY_FIXTURES = Join-Path $env:LOCALAPPDATA 'XDict\library-fixtures'
cargo run --quiet --manifest-path (Join-Path $layout.RepoRoot 'core\Cargo.toml') -p xdict-conformance --bin library-fixture -- $env:XDICT_LIBRARY_FIXTURES
if ($LASTEXITCODE -ne 0) { throw 'the generated library fixtures failed' }
$target = Join-Path $layout.AppRoot 'service\target\probes'
$acceptance = Join-Path $layout.AppRoot 'service\target\acceptance'
New-Item -ItemType Directory -Force -Path $acceptance | Out-Null
cargo build --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml') --features acceptance-contract2 --target-dir $target
if ($LASTEXITCODE -ne 0) { throw 'the foreign contract artifact did not build' }
$env:XDICT_FOREIGN_SERVICE = Join-Path $acceptance 'XDictForeignService.exe'
Copy-Item -LiteralPath (Join-Path $target 'debug\xdict-service.exe') -Destination $env:XDICT_FOREIGN_SERVICE -Force
cargo build --manifest-path (Join-Path $layout.AppRoot 'service\Cargo.toml') --features acceptance-probes --target-dir $target
if ($LASTEXITCODE -ne 0) { throw 'the sandbox probe artifact did not build' }
$env:XDICT_PROBE_SERVICE = Join-Path $acceptance 'XDictProbeService.exe'
Copy-Item -LiteralPath (Join-Path $target 'debug\xdict-service.exe') -Destination $env:XDICT_PROBE_SERVICE -Force
