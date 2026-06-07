# Runs the personal-todos-import skill non-interactively.
# Called by the "DM-PersonalTodosImport" Windows Scheduled Task every 5 minutes, 24/7.
#
# Pure pipeline (no copilot CLI invocation): walks the Outlook task folder
# "Tasks > 🔎 Nirvana TODO", pipes each task through
# .copilot/skills/personal-todos/add-item.py, marks the Outlook task complete
# with [PT-NNN] prefixed in the subject.
#
# Failure-mode philosophy: never throw. Every error path logs and continues
# so a single bad task can't poison the rest of the queue.

param(
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

# --- Single-instance lock ---
$lockPath = Join-Path $LogDir 'personal-todos-import.lock'
$lockDir  = Split-Path $lockPath -Parent
New-Item -ItemType Directory -Force -Path $lockDir | Out-Null

if (Test-Path $lockPath) {
    $lockAge = (Get-Date) - (Get-Item $lockPath).LastWriteTime
    if ($lockAge.TotalMinutes -lt 30) { exit 0 }
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

# Defer log-file creation until we have actual work to do (or are in DryRun).
$logFile = $null
function Get-LogFile {
    if (-not $script:logFile) {
        $script:logFile = Join-Path $LogDir ("personal-todos-import-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")
    }
    return $script:logFile
}
function Write-Log([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format o), $msg
    Add-Content -Path (Get-LogFile) -Value $line -Encoding UTF8
}

try {
    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    if (-not (Ensure-OutlookRunning -LogFile (Join-Path $LogDir 'ensure-outlook.log'))) {
        exit 0
    }

    $ol = New-Object -ComObject Outlook.Application
    $ns = $ol.GetNamespace('MAPI')
    $tasksRoot = $ns.DefaultStore.GetRootFolder().Folders.Item('Tasks')

    $importList = $null
    foreach ($f in $tasksRoot.Folders) {
        if ($f.Name -match 'Nirvana\s*TODO') { $importList = $f; break }
    }
    if (-not $importList) {
        # Folder missing - exit silently (no log file created).
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasksRoot) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns)        | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)        | Out-Null
        exit 0
    }

    # Cheap pre-check: anything ready to process?
    $settleSec = 60
    $now = Get-Date
    $hasWork = $false
    foreach ($t in $importList.Items) {
        if ($t.Complete) { continue }
        if (($now - $t.CreationTime).TotalSeconds -lt $settleSec) { continue }
        $hasWork = $true; break
    }
    if (-not $hasWork -and -not $DryRun) {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($importList) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasksRoot)  | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns)         | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)         | Out-Null
        exit 0
    }

    Write-Log ("Polling folder '{0}' (items={1}, DryRun={2})" -f $importList.Name, $importList.Items.Count, $DryRun)

    $todosFile = Join-Path $AgentRoot 'reports\personal-todos\todos.md'
    $addItem   = Join-Path $AgentRoot '.copilot\skills\personal-todos\add-item.py'

    $processed = 0
    $skipped = 0
    $failed = 0

    # Snapshot Items into an array first - we mutate Complete/Subject inside the loop,
    # and Outlook can re-order live collections under us mid-enumeration.
    $items = @()
    foreach ($t in $importList.Items) { $items += ,$t }

    foreach ($t in $items) {
        if ($t.Complete) { continue }
        $ageSec = ($now - $t.CreationTime).TotalSeconds
        if ($ageSec -lt $settleSec) {
            Write-Log ("  [skip] '{0}' - settling ({1}s < {2}s)" -f $t.Subject, [int]$ageSec, $settleSec)
            $skipped++
            continue
        }
        $title = ($t.Subject -as [string])
        if ($null -eq $title) { $title = '' }
        $title = $title.Trim()
        if (-not $title) {
            Write-Log "  [warn] task has empty subject; leaving untouched"
            $skipped++
            continue
        }
        $body = ($t.Body -as [string])
        if ($null -eq $body) { $body = '' }
        $body = $body.Trim()
        $notesArg = if ($body) { $body } else { '-' }

        if ($DryRun) {
            Write-Log ("  [dry-run] would add: title='{0}' notes='{1}'" -f $title, $notesArg)
            $processed++
            continue
        }

        $pyArgs = @(
            $addItem,
            '--todos-file', $todosFile,
            '--title', $title,
            '--notes', $notesArg
        )
        $stdout = & python @pyArgs 2>&1
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            Write-Log ("  [fail] add-item.py exit={0} for '{1}' - output: {2}" -f $exit, $title, ($stdout -join ' | '))
            $failed++
            continue
        }
        $first = ($stdout | Select-Object -First 1) -as [string]
        $ptId = $null
        if ($first -match '^(PT-\d{3})\b') { $ptId = $Matches[1] }
        if (-not $ptId) {
            Write-Log ("  [fail] could not parse PT-NNN from add-item.py output: '{0}'" -f $first)
            $failed++
            continue
        }
        try {
            $t.Subject = "[$ptId] $title"
            $t.Complete = $true
            $t.Save()
            Write-Log ("  [ok] imported '{0}' as {1}" -f $title, $ptId)
            $processed++
        } catch {
            Write-Log ("  [fail] '{0}' added to todos.md but Outlook update failed: {1}" -f $ptId, $_)
            $failed++
        }
    }

    Write-Log ("Done. processed={0} skipped={1} failed={2}" -f $processed, $skipped, $failed)

    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($importList) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tasksRoot)  | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns)         | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)         | Out-Null
}
catch {
    if ($logFile) { Write-Log ("[unhandled] {0}" -f $_) }
    exit 0
}
finally {
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
