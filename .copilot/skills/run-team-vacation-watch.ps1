# Runs the team-vacation-watch skill non-interactively (FULLY DETERMINISTIC - no copilot agent).
# Called by the "DM-TeamVacationWatch" Windows Scheduled Task (daily 08:00 IST,
# repeating every 10 min for 12h so a closed laptop doesn't miss a day).
#
# Flow (no LLM in the loop):
#   1. Ensure Outlook is running (required - the calendar read is Outlook COM free/busy).
#   2. read-freebusy.ps1  -> per-roster free/busy -> WorkIQ-shaped people[] JSON.
#   3. apply-vacation-state.ps1 -Mode scan -> surgical persona blocks + snapshot + returnees.
#   4. For each returnee: send a templated welcome-back via the post-to-teams trigger email,
#      then apply-vacation-state.ps1 -Mode commit to mark it sent.
#
# WHY NO WorkIQ / agent: WorkIQ only returns event metadata for timed meetings - it cannot
# read free/busy or all-day OOO banners, so it structurally misses vacations (verified
# 2026-06-04). Outlook COM Recipient.FreeBusy is authoritative. With the read deterministic,
# no LLM is needed, which also removes the catastrophic-rewrite risk entirely.
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-team-vacation-watch.ps1
# Flags:
#   -DryRun              compute + log, write nothing, send nothing
#   -Force               bypass the per-(alias,return_date) welcome idempotency gate
#   -AsOfDate YYYY-MM-DD override "today" for testing

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Force,
    [string] $AsOfDate
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$skillDir = Join-Path $AgentRoot '.copilot\skills\team-vacation-watch'
. (Join-Path $skillDir 'welcome-message.ps1')
$skillMd  = Join-Path $skillDir 'SKILL.md'
$stateDir = Join-Path $skillDir 'state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$logFile = Join-Path $LogDir ("team-vacation-watch-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- PID-aware single-instance lock ---------------------------------------
$lockPath = Join-Path $LogDir 'team-vacation-watch.lock'
if (Test-Path $lockPath) {
    $lockContent  = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
    $lockPidMatch = [regex]::Match($lockContent, '^(\d+)\s')
    $lockAge      = (Get-Date) - (Get-Item $lockPath).LastWriteTime

    $alive = $false
    if ($lockPidMatch.Success) {
        $lockPid = [int]$lockPidMatch.Groups[1].Value
        if (Get-Process -Id $lockPid -ErrorAction SilentlyContinue) { $alive = $true }
    }
    if ($alive -and $lockAge.TotalMinutes -lt 30) { exit 0 }   # previous run still going
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue # stale -> break it
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {
    # Outlook is REQUIRED: the calendar read is Outlook COM free/busy, and the
    # welcome-back post also goes via Outlook. If it won't start, bail for this tick.
    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    $outlookUp = Ensure-OutlookRunning -LogFile (Join-Path $LogDir 'ensure-outlook.log')
    if (-not $outlookUp) {
        Write-Log "WARN: Outlook not running and could not be started; skipping this tick (free/busy read needs Outlook)."
        exit 0
    }

    $asOf       = if ($AsOfDate) { $AsOfDate } else { (Get-Date).ToString('yyyy-MM-dd') }
    $readPs1    = Join-Path $skillDir 'read-freebusy.ps1'
    $applyPs1   = Join-Path $skillDir 'apply-vacation-state.ps1'
    $reportFile = Join-Path $AgentRoot ("reports\team-vacation-watch\" + $asOf + ".md")
    $teamsTrigger = 'someone@example.com'

    Write-Log "team-vacation-watch start. asOf=$asOf dryRun=$DryRun force=$Force"

    # --- 1) Deterministic free/busy read -> WorkIQ-shaped JSON ---------------
    $fbJson = Join-Path $env:TEMP ("vacwatch-fb-" + (Get-Date -Format 'yyyyMMddHHmmss') + ".json")
    & powershell -NoProfile -ExecutionPolicy Bypass -File $readPs1 -AsOfDate $asOf -OutJsonPath $fbJson | Out-Null
    if (-not (Test-Path $fbJson)) {
        Write-Log "ERROR: free/busy read produced no JSON. Aborting (nothing mutated)."
        exit 1
    }

    # --- 2) Deterministic scan: personas + snapshot + returnees -------------
    $scanArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$applyPs1,'-Mode','scan',
                  '-WorkIqJsonPath',$fbJson,'-AsOfDate',$asOf)
    if ($DryRun) { $scanArgs += '-DryRun' }
    if ($Force)  { $scanArgs += '-Force' }
    $scanOut = & powershell @scanArgs 2>&1 | Out-String
    Add-Content -Path $logFile -Value $scanOut -Encoding UTF8
    Remove-Item $fbJson -Force -ErrorAction SilentlyContinue

    $resLine = ($scanOut -split "`r?`n" | Where-Object { $_ -like 'VACWATCH_RESULT: *' } | Select-Object -Last 1)
    if (-not $resLine) {
        Write-Log "ERROR: scan did not emit VACWATCH_RESULT (bad read or helper error). Nothing was mutated."
        exit 1
    }
    $result = ($resLine -replace '^VACWATCH_RESULT:\s*', '') | ConvertFrom-Json

    $onVac     = @($result.on_vacation)
    $returnees = @($result.returnees)
    Write-Log ("scan ok: onvac=[{0}] returnees=[{1}] persona_updated={2} first_run={3} dry_run={4}" -f `
        ($onVac -join ','), (($returnees | ForEach-Object { $_.alias }) -join ','), $result.persona_updated, $result.first_run, $result.dry_run)

    # --- 3) Welcome-back posts (skipped entirely on DryRun) -----------------
    $peopleDir = Join-Path $AgentRoot '.copilot\skills\team-personas\people'
    $teamMembers = @(Get-TeamDisplayNames -PeopleDir $peopleDir)
    $posted = @()
    if (-not $DryRun) {
        foreach ($ret in $returnees) {
            $first = "$($ret.first_name)"
            if (-not $first) { $first = (Get-Culture).TextInfo.ToTitleCase(("$($ret.alias)").Split('-')[0]) }
            $subject = "NirvanaTeams Welcome back $first"
            $highlights = Get-AbsenceHighlights -FirstName $first -VacStart "$($ret.vac_start)" -ReturnDate "$($ret.return_date)" -TeamMembers $teamMembers
            $html = Build-WelcomeBackMessage -FirstName $first -VacStart "$($ret.vac_start)" -VacEnd "$($ret.vac_end)" -VacDays $ret.vac_days -WorkDays $ret.vac_work_days -Highlights $highlights -ReturnDate "$($ret.return_date)"
            try {
                $ol   = New-Object -ComObject Outlook.Application
                $mail = $ol.CreateItem(0)   # olMailItem
                $mail.To       = $teamsTrigger
                $mail.Subject  = $subject
                $mail.HTMLBody = $html
                $mail.Send()
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null

                # Commit the ledger entry pending -> sent ONLY after a successful send.
                & powershell -NoProfile -ExecutionPolicy Bypass -File $applyPs1 -Mode commit `
                    -CommitAlias "$($ret.alias)" -CommitReturnDate "$($ret.return_date)" | Out-Null
                $posted += $ret.alias
                Write-Log "posted welcome-back + committed: $($ret.alias) return=$($ret.return_date) subject=`"$subject`""

                # Mirror the post-to-teams log convention.
                $teamsLog = Join-Path $AgentRoot ("reports\teams\" + (Get-Date -Format 'yyyy-MM-dd') + ".md")
                New-Item -ItemType Directory -Force -Path (Split-Path $teamsLog) | Out-Null
                Add-Content -Path $teamsLog -Value ("- {0} subject=`"{1}`" status=queued (team-vacation-watch)" -f (Get-Date -Format 'HH:mm'), $subject) -Encoding UTF8
            } catch {
                Write-Log "WARN: welcome-back post FAILED for $($ret.alias) (left pending for retry): $($_.Exception.Message)"
            }
        }
    } else {
        Write-Log "DryRun: skipping $($returnees.Count) welcome-back post(s)."
    }

    # --- 4) Daily summary line ----------------------------------------------
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path (Split-Path $reportFile) | Out-Null
        $summary = "- {0} scan: onvac=[{1}] returned=[{2}] posted=[{3}] persona_updated={4}" -f `
            (Get-Date -Format 'HH:mm'), ($onVac -join ','), (($returnees | ForEach-Object { $_.alias }) -join ','), ($posted -join ','), $result.persona_updated
        Add-Content -Path $reportFile -Value $summary -Encoding UTF8
    }

    Write-Log ("team-vacation-watch done. onvac={0} returnees={1} posted={2} persona_updated={3}{4}" -f `
        $onVac.Count, $returnees.Count, $posted.Count, $result.persona_updated, $(if ($DryRun) { ' (DRYRUN: no writes/posts)' } else { '' }))
}
finally {
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

