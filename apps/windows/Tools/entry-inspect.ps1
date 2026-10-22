. (Join-Path $PSScriptRoot 'gates.ps1')
# Read-only inventory of owned evidence and corpus paths. Never enumerates credentials or environment files.
$roots = @((Get-XDictCorpus), (Join-Path $env:USERPROFILE 'xdict-spike\corpus'),(Join-Path $env:LOCALAPPDATA 'XDict\entry-evidence'))
foreach ($root in $roots) {
    Write-Host $root
    if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Directory | Select-Object -ExpandProperty FullName }
}
