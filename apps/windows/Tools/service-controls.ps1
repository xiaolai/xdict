# Positive controls for WI-4. Mutations stay in this host's source copy, restore exact bytes, and touch restored
# sources to invalidate timestamp-based build caches. Never use this on a shared build tree while another run owns it.
[CmdletBinding()]
param([ValidateSet('generation','deadline','reopen','sandbox','bulk','credits','identity','idle','paths')][string]$Control)
. (Join-Path $PSScriptRoot 'gates.ps1')
$layout = Get-XDictLayout
$env:XDICT_SERVICE = $layout.Service
$env:XDICT_FIXTURES = Join-Path $env:LOCALAPPDATA 'XDict\conformance-fixtures'
$env:XDICT_PROBE_SERVICE = Join-Path $layout.AppRoot 'service\target\acceptance\XDictProbeService.exe'
$project = Join-Path $layout.AppRoot 'XDict.Tests\XDict.Tests.csproj'
$manifest = Join-Path $layout.AppRoot 'service\Cargo.toml'
$rust = $false
$server = $false
switch ($Control) {
    'generation' {
        $relative = 'XDict.Client\ServiceClient.cs'
        $old = 'generation?.Token ?? default'
        $new = 'CancellationToken.None'
        $filter = 'FullyQualifiedName~ASupersededLateReply|FullyQualifiedName~AQueuedSuperseded'
    }
    'deadline' {
        $relative = 'XDict.Client\ServiceClient.cs'
        $old = 'timeout.CancelAfter(deadline)'
        $new = 'timeout.CancelAfter(Timeout.InfiniteTimeSpan)'
        $filter = 'FullyQualifiedName~AStallExpires'
    }
    'reopen' {
        $relative = 'XDict.Client\ServiceClient.cs'
        $old = 'if (package.Connection != current)'
        $new = 'if (package.Connection != current && operation.Length == 0)'
        $filter = 'FullyQualifiedName~KillMidLookupReopens'
    }
    'sandbox' {
        $relative = 'XDict.Client\Native.cs'
        $old = 'if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x00020009), container.Capabilities,'
        $new = 'if (arguments == "disable-security" && !UpdateProcThreadAttribute(list, 0, new IntPtr(0x00020009), container.Capabilities,'
        $filter = 'FullyQualifiedName~SandboxTests'
    }
    'bulk' {
        $rust = $true
        $relative = 'service\src\runtime.rs'
        $old = 'if let Some((bytes, _)) = payload {'
        $new = 'drop(out); std::thread::yield_now(); let mut out = self.out.lock().unwrap_or_else(|p| p.into_inner()); if let Some((bytes, _)) = payload {'
        $filter = 'bulk_announcements_and_payloads_cannot_be_interleaved'
    }
    'credits' {
        $rust = $true
        $relative = 'service\src\runtime.rs'
        $old = 'Mutex::new([2, 8, 1])'
        $new = 'Mutex::new([3, 8, 1])'
        $filter = 'credits_are_service_wide'
    }
    'idle' {
        $rust = $true
        $relative = 'service\src\runtime.rs'
        $old = 'state.active == 0 && '
        $new = ''
        $filter = 'idle_exit_and_request_admission'
    }
    'identity' {
        $rust = $true
        $relative = 'service\src\handles.rs'
        $old = 'if Some(at_path) != at_open'
        $new = 'if Some(at_path) == at_open'
        $filter = 'path_observation_is_used'
    }
    'paths' {
        $server = $true
        $relative = 'service\src\ops.rs'
        $old = 'let source = sources.remove(&file.file)'
        $new = 'if sources.is_empty() { return Ok(Location::Path { path: file.file.clone() }); } let source = sources.remove(&file.file)'
        $filter = 'FullyQualifiedName~APathInsteadOfAHandle'
    }
}
$file = Join-Path $layout.AppRoot $relative
$original = [System.IO.File]::ReadAllBytes($file)
$encoding = New-Object System.Text.UTF8Encoding($false)
$text = $encoding.GetString($original)
if (-not $text.Contains($old)) { throw "control anchor is missing: $Control" }
$mutated = $text.Replace($old, $new)
try {
    [System.IO.File]::WriteAllText($file, $mutated, $encoding)
    if ($server) {
        cargo build --manifest-path $manifest
        if ($LASTEXITCODE -ne 0) { throw 'the path-admission control did not build' }
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($rust) { $output = (& cargo test --manifest-path $manifest $filter 2>&1 | Out-String) }
        else { $output = (& dotnet test $project -c Debug --filter $filter 2>&1 | Out-String) }
        $result = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    Write-Host $output
    # A mutation that does not compile also exits non-zero: that RED would prove nothing about the check.
    if ($output -match 'error\[E|error: could not compile|error CS') {
        throw "the $Control control did not compile; its red proves nothing"
    }
    if ($result -eq 0) { throw "the $Control control did not turn its check red" }
    Write-Host "CONTROL $Control : RED (exit $result)"
}
finally {
    [System.IO.File]::WriteAllBytes($file, $original)
    (Get-Item -LiteralPath $file).LastWriteTimeUtc = [DateTime]::UtcNow
    if ($rust -or $server) { cargo build --manifest-path $manifest }
    else { dotnet build $project -c Debug -warnaserror }
    if ($LASTEXITCODE -ne 0) { throw "the $Control restore did not build" }
}
