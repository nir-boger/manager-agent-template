# Runs the inbox-watch skill non-interactively.
# Called by the "DM-InboxWatch" Windows Scheduled Task every 5 minutes,
# every day, all hours.
#
# Pattern mirrors run-agent-todos.ps1:
#   - PID-aware single-instance lock (avoid overlap if a run takes >5 min)
#   - Outlook process check (skill aborts cleanly if Outlook isn't running)
#   - Cheap pre-check: any unread Inbox items in last 24h that mention the
#     agent's trigger words and are unprocessed? If none -> exit 0 fast.
#   - Otherwise: invoke `copilot -p` with the SKILL.md as the prompt.

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

# Config-driven values
$idemTag        =  Get-AgentField -Path 'agent.idempotency_tag'     -Default 'NirvanaProcessed' -Config $AgentConfig
$subjectPrefix  =  Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'        -Config $AgentConfig
$triggerAliases =  Get-AgentField -Path 'agent.trigger_aliases'     -Default @('nirvana','@nirvana') -Config $AgentConfig
$connectRoot    = (Get-AgentField -Path 'paths.connect_buddy_root'  -Default '%USERPROFILE%/.copilot/connect-buddy' -Config $AgentConfig)
$connectRootAbs = Resolve-AgentPath $connectRoot -Config $AgentConfig

# Build the cheap pre-check trigger regex from the trigger aliases.
$_bareWords = @()
$_atWords   = @()
foreach ($a in $triggerAliases) {
    if ($a -match '^@(.+)$') { $_atWords   += [regex]::Escape($matches[1]) }
    else                     { $_bareWords += [regex]::Escape($a) }
}
if (-not $_bareWords) { $_bareWords = @([regex]::Escape((Get-AgentField -Path 'agent.name' -Default 'Nirvana' -Config $AgentConfig))) }
if (-not $_atWords)   { $_atWords   = $_bareWords }
$bareGroup = '(?:' + ($_bareWords -join '|') + ')'
$atGroup   = '(?:' + ($_atWords   -join '|') + ')'
$triggerRegex = "(\b$bareGroup\b|@$atGroup)"
# Subject-prefix exclusion (don't loop on our own mail)
$subjectPrefixRegex = [regex]::Escape($subjectPrefix)

# --- PID-aware single-instance lock ---
$lockPath = Join-Path $LogDir 'inbox-watch.lock'
if (Test-Path $lockPath) {
    $lockContent = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
    $lockPidMatch = [regex]::Match($lockContent, '^(\d+)\s')
    $lockAge = (Get-Date) - (Get-Item $lockPath).LastWriteTime

    $alive = $false
    if ($lockPidMatch.Success) {
        $lockPid = [int]$lockPidMatch.Groups[1].Value
        if (Get-Process -Id $lockPid -ErrorAction SilentlyContinue) { $alive = $true }
    }

    if ($alive -and $lockAge.TotalMinutes -lt 30) {
        # Previous run still in progress.
        exit 0
    }
    # Stale lock (process gone or >30 min) - break it.
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {
    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    if (-not (Ensure-OutlookRunning -LogFile (Join-Path $LogDir 'ensure-outlook.log'))) { exit 0 }

    # --- Cheap pre-check: anything to do? ---
    # Run twice with a 15-sec gap to catch tight-race cases (mail that arrived a
    # second before the tick fired - Outlook's COM Items collection may not have
    # surfaced the new item to a freshly-instantiated client yet). On the second
    # pass, Outlook has had time to process the new mail.
    function Test-InboxHasWork {
        $hasWork = $false
        $ol = $null; $ns = $null; $inbox = $null
        try {
            $ol = New-Object -ComObject Outlook.Application
            $ns = $ol.GetNamespace('MAPI')
            $inbox = $ns.GetDefaultFolder(6)   # olFolderInbox
            $cutoff = (Get-Date).AddHours(-24)

            # Sort newest first so we exit fast on a busy inbox.
            $items = $inbox.Items
            $items.Sort('[ReceivedTime]', $true) | Out-Null

            $count = 0
            foreach ($m in $items) {
                $count++
                if ($count -gt 200) { break }   # cap the pre-scan
                try {
                    if ($m.Class -ne 43) { continue }            # 43 = olMail
                    if (-not $m.UnRead)  { continue }
                    if ($m.ReceivedTime -lt $cutoff) { break }   # sorted desc -> done
                    if ($m.MessageClass -notlike 'IPM.Note*') { continue }

                    # Already processed? (defense in depth)
                    $up = $m.UserProperties.Find($idemTag)
                    if ($up) { continue }

                    $subj = ($m.Subject + '')
                    $body = ($m.Body + '')
                    if ($subj -match $subjectPrefixRegex) { continue }    # don't loop on our own mail

                    # Quick text trigger (cheap; full check happens in the skill)
                    if (($subj + "`n" + $body) -imatch $triggerRegex) {
                        $hasWork = $true
                        break
                    }
                }
                catch { continue }
            }
        }
        finally {
            if ($inbox) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($inbox) }
            if ($ns)    { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns) }
            if ($ol)    { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol) }
        }
        return $hasWork
    }

    $hasWork = Test-InboxHasWork
    if (-not $hasWork) {
        Start-Sleep -Seconds 15
        $hasWork = Test-InboxHasWork
    }

    if (-not $hasWork) { exit 0 }

    # --- Invoke the agent ---
    $logFile = Join-Path $LogDir ("inbox-watch-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

    $skillName = (Get-AgentField -Path 'agent.name' -Default 'Nirvana' -Config $AgentConfig)
    $prompt = "Read the skill definition at $AgentRoot\.copilot\skills\inbox-watch\SKILL.md and execute it exactly as described. Do not ask me any questions - proceed autonomously. Honor every guardrail in the SKILL.md (direct-reports-only, explicit $skillName addressing in the live preamble, no externals, no DLs, conversation throttle, sendability filter). When done, print a one-line summary per item processed."

    Invoke-CopilotAgent -Prompt $prompt -LogFile $logFile -AddDir $connectRootAbs | Out-Null
}
finally {
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
