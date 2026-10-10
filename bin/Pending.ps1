# List dispatched jobs whose outbox has no READY.json yet, with the command to re-arm the watcher.
# Run once after the Claude session restarts. 会话重启后跑一次，重挂守候。
# Claude Code force-stops background commands around 30 minutes (measured 2026-10-02),
# so every re-armed watch is 29 minutes and exits 2 while the executor can keep running.
$root = Split-Path -Parent $PSScriptRoot
$found = 0
Get-ChildItem (Join-Path $root 'jobs/*/job.json') -ErrorAction SilentlyContinue | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    if (Test-Path -LiteralPath (Join-Path $j.outbox 'READY.json')) { return }
    # Lead closed it by hand (smoke test, stopped, reassigned). File sits next to job.json.
    if (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'CLOSED.txt')) { return }
    $found++
    $alive = $j.host_pid -and [bool](Get-Process -Id $j.host_pid -ErrorAction SilentlyContinue)
    "PENDING $($j.job_id) | $($j.executor) | $($j.task) | pid=$($j.host_pid) alive=$alive | outbox=$($j.outbox)"
    $watch = "pwsh -NoProfile -File `"$PSScriptRoot/Wait-Delivery.ps1`" -JobDir `"$($j.outbox)`""
    if ($j.host_pid) { $watch += " -ProcessId $($j.host_pid)" }
    $watch += " -TimeoutMinutes 29 -IntervalSeconds 20"
    "  WATCH: $watch"
}
if ($found -eq 0) { 'NO PENDING JOBS' }
