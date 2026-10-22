# Validate the MSI without installing it: read its File table and extract it administratively to a temporary target.
# A real clean install/uninstall belongs on a fresh Windows 11 VM, not on the owner's machine.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Msi)
if (-not (Test-Path -LiteralPath $Msi)) { throw "no MSI: $Msi" }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Msi, 0))
$view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @('SELECT FileName FROM File'))
$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
$files = New-Object System.Collections.Generic.List[string]
while ($true) {
    $row = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($null -eq $row) { break }
    $name = $row.GetType().InvokeMember('StringData', 'GetProperty', $null, $row, @(1))
    # The File table's FileName may carry the short name before a vertical bar: SHORT~1.EXE|XDict.exe.
    $files.Add(($name -split '\|')[-1])
}
foreach ($required in 'XDict.exe', 'XDictService.exe', 'Provenance.txt') {
    if (-not ($files | Where-Object { $_ -ieq $required })) { throw "the MSI has no $required (names: $($files -join ', '))" }
}
$target = Join-Path $env:TEMP ('xdict-msi-' + [Guid]::NewGuid().ToString('N'))
try {
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/a', ('"' + $Msi + '"'), '/qn', ('TARGETDIR="' + $target + '"')) -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "the administrative extraction failed: $($process.ExitCode)" }
    $extracted = @(Get-ChildItem -LiteralPath $target -Recurse -File | Select-Object -ExpandProperty Name)
    foreach ($required in 'XDict.exe', 'XDictService.exe') {
        if (-not ($extracted | Where-Object { $_ -ieq $required })) { throw "the extraction has no $required" }
    }
    Write-Host ("MSI verified: {0} files in the table; {1} extracted to {2}" -f $files.Count, $extracted.Count, $target)
}
finally {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
}
