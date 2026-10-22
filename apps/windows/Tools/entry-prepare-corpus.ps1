. (Join-Path $PSScriptRoot 'gates.ps1')
$ErrorActionPreference = 'Stop'
$drive = Get-PSDrive C
Write-Host ('Free bytes: ' + $drive.Free)
if ($drive.Free -lt 65000000000) { throw 'less than 65 GB free for the reader corpus' }
New-Item -ItemType Directory -Force -Path (Get-XDictCorpus) | Out-Null
