# The main window's search path, driven in the interactive session: the library lab first registers the generated
# tiny fixture in a library file, then the search lab opens that library through the window's own session, searches
# "cafe", and reports the first headword (café, reached by removing the mark).
[CmdletBinding()]
param([switch]$Full)

. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
& (Join-Path $PSScriptRoot 'build.ps1') -Full:$Full

function Invoke-XDictWindowLab {
    param([string]$Config, [string]$Output, [string]$Name)
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    return Invoke-XDictTask -Executable $exe -Arguments ('--' + $Name + '-lab "' + $Config + '"') -Output $Output `
        -Seconds 180 -Prefix 'xdict-lab'
}

Invoke-XDictGate -Name 'search-lab' -Inputs (Get-XDictLabInputs -Layout $layout) -Full:$Full -Action {
    $folder = Join-Path $env:LOCALAPPDATA ('XDict\search-lab\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $tiny = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures\tiny\tiny.mdx'
    if (-not (Test-Path -LiteralPath $tiny)) { throw "the tiny fixture is missing: $tiny" }
    $libraryConfig = Join-Path $folder 'library-config.json'
    @{ output = (Join-Path $folder 'library-result.json'); library = (Join-Path $folder 'library.json'); paths = @($tiny) } |
        ConvertTo-Json | Set-Content -LiteralPath $libraryConfig -Encoding Ascii
    $added = Invoke-XDictWindowLab -Config $libraryConfig -Output (Join-Path $folder 'library-result.json') -Name 'library'
    if ($added.count -lt 1) { throw 'the library lab added no dictionary' }
    $searchConfig = Join-Path $folder 'search-config.json'
    @{ output = (Join-Path $folder 'search-result.json'); library = (Join-Path $folder 'library.json'); query = 'cafe' } |
        ConvertTo-Json | Set-Content -LiteralPath $searchConfig -Encoding Ascii
    $found = Invoke-XDictWindowLab -Config $searchConfig -Output (Join-Path $folder 'search-result.json') -Name 'search'
    Write-Host ($found | ConvertTo-Json -Depth 5)
    if ($found.hits -lt 1) { throw 'the search window found nothing for cafe' }
    $cafe = 'caf' + [char]0x00E9
    if ($found.first -ne $cafe) { throw "the first headword is not $cafe" }
}
