# Sign and verify binaries with the owner's certificate: the only signing step either the bundle or the MSI runs.
[CmdletBinding()]
param([Parameter(Mandatory)][string[]]$Path, [Parameter(Mandatory)][string]$CertificateThumbprint)
$signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
if ($null -eq $signTool) { throw 'signtool.exe is not on PATH; install the Windows SDK on the signing machine' }
& $signTool.Source sign /sha1 $CertificateThumbprint /fd SHA256 /td SHA256 /tr 'http://timestamp.digicert.com' @Path
if ($LASTEXITCODE -ne 0) { throw 'signing failed' }
& $signTool.Source verify /pa @Path
if ($LASTEXITCODE -ne 0) { throw 'the signed files do not verify' }
Write-Host ('signed and verified: ' + ($Path -join ', '))
