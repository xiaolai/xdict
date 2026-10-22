# The 24 corpus editions, against index_bench's own registry: the library's imports must equal the benchmarked
# edition for every folder. A measurement gate, never cached: it reads the corpus itself.
[CmdletBinding()]
param([string]$Corpus = $env:XDICT_CORPUS)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
if ([string]::IsNullOrWhiteSpace($Corpus)) { $Corpus = Get-XDictCorpus }
if (-not (Test-Path -LiteralPath $Corpus)) { throw "the corpus is not at $Corpus" }
& (Join-Path $PSScriptRoot 'build.ps1')

Invoke-XDictGate -Name 'library-corpus' -NeverCache -Action {
    $scratch = Join-Path $env:LOCALAPPDATA 'XDict\library-corpus'
    cargo run --quiet --release --manifest-path (Join-Path $layout.RepoRoot 'core\Cargo.toml') `
        -p xdict-core --example index_bench -- import-all $scratch $Corpus
    if ($LASTEXITCODE -ne 0) { throw 'index_bench import-all failed' }
    $registry = Get-Content -LiteralPath (Join-Path $scratch "data\registry.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $root = [System.IO.Path]::GetFullPath($Corpus).TrimEnd('\')
    $expected = @{}
    foreach ($property in $registry.locations.PSObject.Properties) {
        $location = [string]$property.Value.location
        if (-not $location.StartsWith('path:')) { continue }
        $path = [System.IO.Path]::GetFullPath($location.Substring(5))
        $folder = Split-Path -Path $path -Parent
        if (-not $folder.StartsWith($root + '\')) { continue }
        $name = Split-Path -Path $folder -Leaf
        $expected[$name] = [string]$property.Value.edition
    }
    if ($expected.Count -lt 1) { throw 'index_bench registered no path edition' }
    $editions = Join-Path $scratch 'editions.json'
    $expected | ConvertTo-Json | Set-Content -LiteralPath $editions -Encoding UTF8
    $env:XDICT_CORPUS = $Corpus
    $env:XDICT_EDITIONS = $editions
    $env:XDICT_SERVICE = $layout.Service
    dotnet test (Join-Path $layout.AppRoot 'XDict.Tests\XDict.Tests.csproj') -c Debug --no-build `
        --filter 'FullyQualifiedName~LibraryCorpusTests|FullyQualifiedName~SearchCorpusTests'
    if ($LASTEXITCODE -ne 0) { throw 'the corpus editions differ from index_bench' }
}
