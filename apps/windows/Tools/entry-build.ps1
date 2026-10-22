# Narrow Windows-only WI-5 build; production service inputs did not change.
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
dotnet build (Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj') -c Debug -warnaserror
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
