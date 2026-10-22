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
                $skip = $false
                foreach ($pattern in $Exclude) {
                    if ($path -match $pattern) { $skip = $true; break }
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
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Full,
        [switch]$NeverCache
    )
    $key = Get-XDictTreeHash -Roots $Inputs -Extra $Extra
    $file = Join-Path (Get-XDictCacheDirectory) ($Name + '.key')
    if (-not $Full -and -not $NeverCache -and (Test-Path -LiteralPath $file)) {
        $passed = (Get-Content -LiteralPath $file -Raw).Trim()
        if ($passed -eq $key) {
            Write-Host ("{0}: cached pass ({1})" -f $Name, $key.Substring(0, 12))
            return
        }
    }
    $global:LASTEXITCODE = 0
    & $Action
    if ($LASTEXITCODE -ne 0) { throw ("{0} failed: exit {1}" -f $Name, $LASTEXITCODE) }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    Set-Content -LiteralPath $file -Value $key -Encoding Ascii
    Write-Host ("{0}: pass ({1})" -f $Name, $key.Substring(0, 12))
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
        while (-not (Test-Path -LiteralPath $Output)) {
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

# Ends the windows a lab opened, never the reader's own: only processes started after the run began are killed. A
# cleanup by process name alone closed whatever Word, Edge or Notepad the host's owner had open.
function Stop-XDictLabProcesses {
    param([string[]]$Name = @('XDict', 'XDictService', 'notepad', 'msedge', 'chrome'), [datetime]$Since = [datetime]::MinValue)
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
        'sound', 'sound-links', 'selection', 'setup', 'setup-225')
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
