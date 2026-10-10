# Dispatch one task card to an external agent CLI, detached; print the watch command.
# 派一个任务卡给外部 agent CLI（后台隐藏进程），输出守候命令。
#
#   pwsh -File Dispatch.ps1 -Executor codex -Workspace <dir> -Outbox <dir> -PromptFile <card.md> -Task "name"
#
# Executors are defined in executors.json (copy executors.example.json). No model/account is hard-coded here.
param(
    [Parameter(Mandatory = $true)][string]$Executor,
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$Outbox,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$Task,
    [string]$Project = '',
    [string]$JobId = '',
    [int]$TimeoutMinutes = 90,
    [string]$Config = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
# UTF-8 both ways; otherwise non-ASCII task names and paths get mangled on Windows (e.g. GBK code page).
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
# Write-Error is terminating when ErrorAction is Stop, which would skip `exit 2`.
function Fail([string]$msg) { Write-Error $msg -ErrorAction Continue; exit 2 }
$root = Split-Path -Parent $PSScriptRoot
if (-not $Config) { $Config = Join-Path $root 'executors.json' }
if (-not (Test-Path -LiteralPath $Config)) { Fail "Config not found: $Config (copy executors.example.json to executors.json)" }
$cfg = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json -AsHashtable
if (-not $cfg.executors.ContainsKey($Executor)) { Fail "Unknown executor '$Executor'. Known: $($cfg.executors.Keys -join ', ')" }
$e = $cfg.executors[$Executor]

foreach ($p in $Workspace, $PromptFile) { if (-not (Test-Path -LiteralPath $p)) { Fail "Not found: $p" } }
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { Fail "Workspace must be an existing directory: $Workspace" }
$PromptFile = (Resolve-Path -LiteralPath $PromptFile).Path
if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Fail "PromptFile must be an existing file: $PromptFile" }

# -DryRun must not create the outbox. Resolve an existing path; otherwise keep the absolute form.
if (Test-Path -LiteralPath $Outbox) {
    $Outbox = (Resolve-Path -LiteralPath $Outbox).Path
} else {
    $Outbox = [IO.Path]::GetFullPath($Outbox)
}
if (-not $JobId) { $JobId = [guid]::NewGuid().ToString('D') }
$jobDir = Join-Path $root "jobs/$JobId"

$cmd = Get-Command $e.command -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cmd) { Fail "Command not found on PATH: $($e.command)" }

function Expand-Token([string]$s, $map) {
    # Longer keys first so "{card}" does not eat the prefix of "{carddir}".
    foreach ($k in @($map.Keys | Sort-Object { -$_.Length })) {
        $s = $s.Replace([string]$k, [string]$map[$k])
    }
    return $s
}
function New-LaunchSpec([string]$outboxPath, [string]$jobPath) {
    $tokens = @{
        '{workspace}' = $Workspace
        '{outbox}'    = $outboxPath
        '{card}'      = $PromptFile
        '{carddir}'   = (Split-Path -Parent $PromptFile)
        '{jobdir}'    = $jobPath
    }
    $pointerTemplate = if ($cfg.pointer) { $cfg.pointer } else { 'Read the task card file "{card}" (UTF-8) in full and follow it exactly. Do nothing outside the card.' }
    $tokens['{pointer}'] = Expand-Token $pointerTemplate $tokens
    [ordered]@{
        command    = $cmd.Source
        args       = @($e.args | ForEach-Object { Expand-Token $_ $tokens })
        cwd        = if ($e.cwd) { Expand-Token $e.cwd $tokens } else { $Workspace }
        stdin_card = [bool]$e.stdin_card
        card       = $PromptFile
        env        = if ($e.env) { $e.env } else { @{} }
    }
}

if ($DryRun) {
    "DRYRUN JobId=$JobId executor=$Executor"
    (New-LaunchSpec $Outbox $jobDir) | ConvertTo-Json -Depth 5
    exit 0
}

if (Test-Path -LiteralPath (Join-Path $Outbox 'READY.json')) {
    Fail "Outbox already contains READY.json; choose a new delivery directory: $Outbox"
}
if (Test-Path -LiteralPath $jobDir) { Fail "Job exists: $jobDir" }
New-Item -ItemType Directory -Force -Path $Outbox | Out-Null
$Outbox = (Resolve-Path -LiteralPath $Outbox).Path
$spec = New-LaunchSpec $Outbox $jobDir

New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
Copy-Item -LiteralPath $PromptFile (Join-Path $jobDir 'TASK_CARD.md')
$spec | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $jobDir 'spec.json') -Encoding utf8

$runner = Join-Path $PSScriptRoot 'Run-Agent.ps1'
# ArgumentList on ProcessStartInfo passes each argument separately, so a path with spaces
# is not split and does not depend on quotes embedded in the string.
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
if ($IsWindows) { $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden }
foreach ($arg in @('-NoProfile', '-File', $runner, '-JobDir', $jobDir)) {
    [void]$startInfo.ArgumentList.Add($arg)
}
$proc = [Diagnostics.Process]::Start($startInfo)
if ($null -eq $proc) { Fail 'Failed to start agent runner.' }

[ordered]@{
    job_id = $JobId; project = $Project; task = $Task; executor = $Executor
    workspace = $Workspace; outbox = $Outbox; host_pid = $proc.Id
    timeout_minutes = $TimeoutMinutes; dispatched_at = (Get-Date -Format o)
} | ConvertTo-Json | Set-Content (Join-Path $jobDir 'job.json') -Encoding utf8

# Claude Code force-stops background commands around 30 minutes (measured 2026-10-02).
# Exit 2 while this pid is still alive means: arm another round. Do not kill the executor.
$watchMinutes = [Math]::Min(29, $TimeoutMinutes + 10)
"DISPATCHED JobId=$JobId executor=$Executor pid=$($proc.Id)"
"WATCH: pwsh -NoProfile -File `"$PSScriptRoot/Wait-Delivery.ps1`" -JobDir `"$Outbox`" -ProcessId $($proc.Id) -TimeoutMinutes $watchMinutes -IntervalSeconds 20"
