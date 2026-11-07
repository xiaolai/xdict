# The gate cache and the gate runner. A gate's key is a SHA-256 of the contents it reads, never a timestamp; a gate
# whose key matches the one it last passed with is skipped unless -Full. The macOS tree's rule (AGENTS.md: only what
# changed, never again what passed) applies here in PowerShell.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-XDictCacheDirectory {
    Join-Path $env:LOCALAPPDATA 'XDict\gates'
}

function Get-XDictTreeHash {
    param(
        [string[]]$Roots,
        [string[]]$Extra = @(),
        [string[]]$Exclude = @('\\bin\\', '\\obj\\', '\\target\\', '\\out\\', '\\.git\\')
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $item = Get-Item -LiteralPath $root
        if ($item.PSIsContainer) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
                $path = $file.FullName
                # The exclusions name folders inside the tree, never a folder the checkout happens to live under:
                # a workspace beneath `C:\out\` must not exclude every source file from the key.
                $relative = '\' + $path.Substring($root.Length).TrimStart('\', '/').Replace('/', '\')
                $skip = $false
                foreach ($pattern in $Exclude) {
                    if ($relative -match $pattern) { $skip = $true; break }
                }
                if ($skip) { continue }
                $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                $lines.Add($path.Replace('\', '/') + ' ' + $hash)
            }
        }
        else {
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            $lines.Add($item.FullName.Replace('\', '/') + ' ' + $hash)
        }
    }
    foreach ($line in $Extra) { $lines.Add('extra ' + $line) }
    $text = ''
    if ($lines.Count -gt 0) { $text = [string]::Join("`n", ($lines | Sort-Object)) }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
    }
    finally {
        $sha.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Invoke-XDictGate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Inputs = @(),
        [string[]]$Extra = @(),
        # The files a pass leaves behind. A cached pass is accepted only while every one of them is still there with
        # the hash it had when the gate passed: a deleted bin or target folder otherwise kept reporting "cached pass".
        [string[]]$Outputs = @(),
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Full,
        [switch]$NeverCache
    )
    $key = Get-XDictTreeHash -Roots $Inputs -Extra $Extra
    $file = Join-Path (Get-XDictCacheDirectory) ($Name + '.key')
    $evidence = Join-Path (Get-XDictCacheDirectory) ($Name + '.outputs')
    if (-not $Full -and -not $NeverCache -and (Test-Path -LiteralPath $file)) {
        $passed = (Get-Content -LiteralPath $file -Raw).Trim()
        if ($passed -eq $key -and (Test-XDictOutputs -Evidence $evidence -Paths $Outputs)) {
            Write-Host ("{0}: cached pass ({1})" -f $Name, $key.Substring(0, 12))
            return
        }
    }
    $global:LASTEXITCODE = 0
    & $Action
    if ($LASTEXITCODE -ne 0) { throw ("{0} failed: exit {1}" -f $Name, $LASTEXITCODE) }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    Set-Content -LiteralPath $file -Value $key -Encoding Ascii
    Save-XDictOutputs -Evidence $evidence -Paths $Outputs
    Write-Host ("{0}: pass ({1})" -f $Name, $key.Substring(0, 12))
}

# The recorded hashes a cached pass must still find. No evidence file and no declared outputs agree; a gate that
# declares outputs and writes none is refused by Save-XDictOutputs, never cached.
function Test-XDictOutputs {
    param([string]$Evidence, [string[]]$Paths = @())
    if (-not $Paths -or $Paths.Count -eq 0) { return $true }
    if (-not (Test-Path -LiteralPath $Evidence)) { return $false }
    foreach ($line in Get-Content -LiteralPath $Evidence -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { return $false }
        if (-not (Test-Path -LiteralPath $parts[0])) { return $false }
        if ((Get-FileHash -LiteralPath $parts[0] -Algorithm SHA256).Hash -ne $parts[1]) { return $false }
    }
    return $true
}

function Save-XDictOutputs {
    param([string]$Evidence, [string[]]$Paths = @())
    if (-not $Paths -or $Paths.Count -eq 0) {
        Remove-Item -LiteralPath $Evidence -Force -ErrorAction SilentlyContinue
        return
    }
    $lines = foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { throw "the gate passed but produced no $path" }
        $path + "`t" + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    Set-Content -LiteralPath $Evidence -Encoding UTF8 -Value $lines
}

# Running a command in the interactive desktop session through a one-shot scheduled task: an SSH session cannot open
# a UIA tree or hold a foreground window, and a task in the interactive session can. Every lab starts one; this used
# to be copied into each harness, so a fix had to be made in a dozen places.
function Invoke-XDictTask {
    param(
        [string]$Script = '',
        [string]$Executable = '',
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$Output,
        [int]$Seconds = 180,
        [string]$RunLevel = 'Limited',
        [string]$Prefix = 'xdict-task',
        [switch]$TolerateTimeout
    )
    if ([string]::IsNullOrWhiteSpace($Executable)) {
        $Executable = 'powershell.exe'
        $Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
    }
    $id = $Prefix + '-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute $Executable -Argument $Arguments
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel $RunLevel
    $started = Get-Date
    try {
        Register-ScheduledTask -TaskName $id -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $id
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
        # Wait for the task to end, not for its result file to appear: a driver writes its result and then cleans
        # up, so a file that exists may still be half-written and its cleanup may still be running. The run is over
        # once its LastRunTime is this run's and its state is no longer Running (a task that finished instantly never
        # shows Running at all).
        while ($true) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $id -ErrorAction SilentlyContinue
            $ran = $null -ne $taskInfo -and $taskInfo.LastRunTime -ge $started.AddSeconds(-2)
            $state = (Get-ScheduledTask -TaskName $id -ErrorAction SilentlyContinue).State
            if ($ran -and $state -ne 'Running') { break }
            if ([DateTime]::UtcNow -gt $deadline) {
                # Unregistering alone leaves the wrapper and its app alive; the next stage's window search takes
                # the stale window. Stop the task and everything the run started.
                Stop-ScheduledTask -TaskName $id -ErrorAction SilentlyContinue
                Stop-XDictLabProcesses -Since $started
                # The measurement tolerates one sample's timeout and records it; every other caller fails loud.
                if ($TolerateTimeout) { return $null }
                throw "the task produced no result: $Output"
            }
            Start-Sleep -Milliseconds 250
        }
        $info = Get-ScheduledTaskInfo -TaskName $id -ErrorAction SilentlyContinue
        $code = if ($null -ne $info) { [int64]$info.LastTaskResult } else { 0 }
        if ($code -ne 0) {
            # The task ended with a failure the result file cannot be trusted to describe; the stage is red.
            throw ("the task failed: exit {0}; result {1}" -f $code, $Output)
        }
        if (-not (Test-Path -LiteralPath $Output)) { throw "the task ended without a result: $Output" }
        return (Get-Content -LiteralPath $Output -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    finally {
        Unregister-ScheduledTask -TaskName $id -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Get-XDictLayout {
    $appRoot = Split-Path $PSScriptRoot -Parent
    $repoRoot = Split-Path (Split-Path $appRoot -Parent) -Parent
    [pscustomobject]@{
        AppRoot  = $appRoot
        RepoRoot = $repoRoot
        Service  = Join-Path $appRoot 'service\target\debug\xdict-service.exe'
    }
}

function Get-XDictAppOutput {
    param([string]$Configuration = 'Debug')
    $layout = Get-XDictLayout
    $project = Join-Path $layout.AppRoot 'XDict.App\XDict.App.csproj'
    $value = & dotnet msbuild $project -getProperty:OutDir -p:Configuration=$Configuration -nologo
    if ($LASTEXITCODE -ne 0) { throw 'dotnet msbuild could not report the app output folder' }
    # msbuild reports OutDir relative to the project; the gates need one absolute path.
    $relative = ($value | Select-Object -Last 1).Trim()
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path $project -Parent) $relative))
}

# A private library for one UIA stage: the library window lab imports the named MDX files, sidecars included, so the
# stage never touches the reader's own library. Returns the library path the app reads through XDICT_LIBRARY.
function New-XDictUiaLibrary {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string[]]$Mdx)
    foreach ($path in $Mdx) {
        if (-not (Test-Path -LiteralPath $path)) { throw "the fixture is missing: $path" }
    }
    New-Item -ItemType Directory -Force -Path $Folder | Out-Null
    $library = Join-Path $Folder 'library.json'
    $config = Join-Path $Folder 'library-config.json'
    @{ output = (Join-Path $Folder 'library-result.json'); library = $library; paths = $Mdx } |
        ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8
    $exe = Join-Path (Get-XDictAppOutput) 'XDict.exe'
    $null = Invoke-XDictTask -Executable $exe -Arguments ('--library-lab "' + $config + '"') `
        -Output (Join-Path $Folder 'library-result.json') -Seconds 180 -Prefix 'xdict-library'
    if (-not (Test-Path -LiteralPath $library)) { throw 'the private library was not written' }
    return $library
}

# Ends the windows a lab opened, never the reader's own: only processes started after the run began are killed. A
# cleanup by process name alone closed whatever Word, Edge or Notepad the host's owner had open.
function Stop-XDictLabProcesses {
    param([string[]]$Name = @('XDict', 'XDictService', 'notepad', 'msedge', 'chrome'), [datetime]$Since = [datetime]::MinValue,
        [string]$Marker = '')
    if ($Marker) {
        # A marker names this run's own artefacts (its unique lab folder) in the command line. That is an identity,
        # unlike a process name and start time, which can match a process the person opened during the run.
        # Windows 11's packaged Notepad carries the document path base64-encoded in /SESSION:, so it is decoded first.
        $wanted = @($Name | ForEach-Object { $_ -replace '\.exe$', '' })
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $wanted -contains ($_.Name -replace '\.exe$', '') })) {
            $line = $process.CommandLine
            if ($line -and $line -match '/SESSION:([A-Za-z0-9+/=]+)') {
                try { $line = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) }
                catch { }
            }
            if ($line -and $line.IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        return
    }
    foreach ($process in @(Get-Process -Name $Name -ErrorAction SilentlyContinue)) {
        try {
            if ($null -ne $process.StartTime -and $process.StartTime -lt $Since) { continue }
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
        catch { }
    }
}

# The measurement corpus: an explicit XDICT_CORPUS wins, otherwise the host's per-user copy. Never a hard-coded
# account path: the host, the E2E user and the developer do not share one.
function Get-XDictCorpus {
    param([string]$Name = 'the24')
    if (-not [string]::IsNullOrWhiteSpace($env:XDICT_CORPUS)) { return $env:XDICT_CORPUS }
    return Join-Path $env:USERPROFILE ('xdict-corpus\' + $Name)
}

# The conformance runner the service fixtures and the IPC gate start: one path, not four copies of it.
function Get-XDictConformanceExe {
    param($Layout = (Get-XDictLayout))
    return Join-Path $Layout.AppRoot 'XDict.Conformance\bin\Debug\net10.0\XDict.Conformance.exe'
}

# The Windows E2E stages whose passing evidence a release requires; e2e.ps1 and release.ps1 read this one list.
function Get-XDictE2EStageNames {
    return @('build', 'unit', 'contract', 'ipc', 'capture', 'library', 'launch', 'lookup', 'scope', 'trail',
        'find', 'tabs', 'all', 'explore', 'hover', 'sound', 'sound-links', 'review', 'selection', 'setup', 'setup-225')
}

function Get-XDictBuildInputs {
    param($Layout)
    $inputs = @($Layout.AppRoot, (Join-Path $Layout.RepoRoot 'core'))
    $project = Join-Path $Layout.AppRoot 'XDict.App\XDict.App.csproj'
    [xml]$manifest = Get-Content -LiteralPath $project -Raw
    foreach ($resource in $manifest.SelectNodes('//EmbeddedResource')) {
        $include = $resource.GetAttribute('Include')
        if ($include.StartsWith('../../apple/')) {
            $inputs += [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $project) $include))
        }
    }
    $inputs
}

# What a lab or UIA gate's binary and fixtures are built from: the app, the core, the embedded apple resources and
# the conformance suites the harnesses read. A lab keyed on AppRoot alone reported "cached pass" after a core change
# rebuilt the binary underneath it.
function Get-XDictLabInputs {
    param($Layout)
    $inputs = @(Get-XDictBuildInputs -Layout $Layout)
    $inputs += Join-Path $Layout.RepoRoot 'conformance'
    $inputs
}
