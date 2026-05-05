# Runs the agent-todos skill non-interactively.
# Called by the "DM-NirvanaAgentTodos" Windows Scheduled Task every 5 minutes
# during work hours (Sun-Thu 08:00-19:00 IST).
#
# Guards:
#   - Outlook must be running (skill aborts cleanly otherwise).
#   - Single-instance lock to avoid overlapping runs (if a run takes > 5 min).

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

# --- Single-instance lock ---
$lockPath = Join-Path $LogDir 'agent-todos.lock'
$lockDir  = Split-Path $lockPath -Parent
New-Item -ItemType Directory -Force -Path $lockDir | Out-Null

if (Test-Path $lockPath) {
    $lockAge = (Get-Date) - (Get-Item $lockPath).LastWriteTime
    if ($lockAge.TotalMinutes -lt 30) {
        # Previous run still in progress (or hung within reason). Skip this tick.
        exit 0
    }
    # Stale lock (>30 min) — break it.
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {
    # --- Cheap pre-check: are there any open tasks? ---
    # Skip the heavyweight copilot invocation when the list is empty.
    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    if (-not (Ensure-OutlookRunning -LogFile (Join-Path $LogDir 'ensure-outlook.log'))) { exit 0 }

    $ol = New-Object -ComObject Outlook.Application
    $ns = $ol.GetNamespace('MAPI')
    $tasksRoot = $ns.DefaultStore.GetRootFolder().Folders.Item('Tasks')
    $agentList = $tasksRoot.Folders | Where-Object { $_.Name -match 'Nirvana\s*Agent' } | Select-Object -First 1
    if (-not $agentList) { exit 0 }

    # Settle window: 60s grace right after CREATION (Nir might still be typing).
    # Do NOT key off LastModificationTime — Exchange ActiveSync (phone / To Do app)
    # bumps that every few minutes, which used to starve tasks created on mobile.
    $settleSec = 60
    $now = Get-Date
    $hasWork = $false
    foreach ($t in $agentList.Items) {
        if ($t.Complete) { continue }
        $ageSinceCreate = $now - $t.CreationTime
        if ($ageSinceCreate.TotalSeconds -lt $settleSec) { continue }
        $hasWork = $true
        break
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($agentList) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasksRoot) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns)        | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)        | Out-Null

    if (-not $hasWork) { exit 0 }

    # --- Invoke the agent ---
    $logFile = Join-Path $LogDir ("agent-todos-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

    $prompt = "Read the skill definition at $AgentRoot\.copilot\skills\agent-todos\SKILL.md and execute it exactly as described. Do not ask me any questions - proceed autonomously. Honor the 60-second settle period (skip tasks modified within the last 60s). When done, print a one-line summary per task processed."

    & copilot -p $prompt --allow-all-tools --allow-all-paths --no-ask-user --model claude-sonnet-4.5 *>&1 | Tee-Object -FilePath $logFile
}
finally {
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

