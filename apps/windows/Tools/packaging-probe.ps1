# What can build an installer on this host: Inno Setup, NSIS, WiX, and the .NET WiX tool.
foreach ($name in 'iscc', 'makensis', 'wix', 'candle', 'light') {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { Write-Host ($name + ' -> ' + $command.Source) } else { Write-Host ($name + ' -> absent') }
}
foreach ($path in @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        'C:\Program Files (x86)\NSIS\makensis.exe',
        'C:\Program Files\NSIS\makensis.exe')) {
    if (Test-Path -LiteralPath $path) { Write-Host ('found ' + $path) }
}
