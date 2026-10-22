# WI-5 acceptance, one GUI stage at a time. A failed stage never stamps or caches a pass.
[CmdletBinding()]
param([string[]]$Modes = @('fault-scheme','fault-filter','fault-navigation','fault-csp','fault-crash','control-filter-off','control-filter-on','control-csp-off','control-csp-on','control-navigation-off','control-navigation-on','frame-write','frame-relaunch','bridge','word','frame-large','display','corpus','hostile'), [switch]$Full)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$webview = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application'
if (-not (Test-Path -LiteralPath $webview)) { $webview = Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView\Application' }
$runtime = @(Get-ChildItem -LiteralPath $webview -Directory | Where-Object { $_.Name -match '^\d+\.' } | Select-Object -ExpandProperty Name) -join ','
if (-not $runtime) { throw 'cannot key acceptance to the installed WebView2 runtime' }
$inputs = @(Get-XDictBuildInputs -Layout $layout) + @((Join-Path $layout.RepoRoot 'conformance'),$PSCommandPath,(Join-Path $PSScriptRoot 'entry-native.ps1'),(Join-Path $PSScriptRoot 'entry-netlog.ps1'))
$evidence = Join-Path $env:LOCALAPPDATA 'XDict\entry-evidence'
foreach ($mode in $Modes) {
    Write-Host ('WI-5 stage: ' + $mode)
    Invoke-XDictGate -Name ('entry-' + $mode) -Inputs $inputs -Extra @($runtime) -Full:$Full -Action {
        & (Join-Path $PSScriptRoot 'entry-native.ps1') -Mode $mode
        if ($LASTEXITCODE -ne 0) { throw ('WI-5 stage failed: ' + $mode) }
    }
}
Write-Host ('WI-5 stages passed; evidence under ' + $evidence)
