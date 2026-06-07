<#
.SYNOPSIS
  Deterministic, DryRun-safe state engine for team-vacation-watch.

.DESCRIPTION
  This script owns EVERY destructive file operation for the skill so the LLM
  agent never hand-writes persona files. The agent's only job is the work that
  genuinely needs it: the WorkIQ calendar read (MCP) and the Outlook welcome-back
  post (COM). Everything that touches disk -- persona managed-block upserts, the
  returnee computation, the welcomed.json ledger, and the snapshot -- happens here,
  surgically and idempotently.

  CRITICAL invariants enforced in code (not just prose):
    * Persona edits ONLY ever replace the <!-- nirvana:vacation-status --> region,
      or insert that block. The rest of the file is preserved byte-for-byte.
    * -DryRun computes + reports but writes NOTHING (no persona, no ledger, no snapshot).
    * Validate the WorkIQ JSON before any mutation; a bad read touches nothing.
    * Snapshot is written LAST.

  MODES
    (default / -Mode scan)  Read WorkIQ JSON + prior snapshot, upsert all personas,
                            compute returnees, append 'pending' ledger claims, write
                            snapshot. Emits a single result line to stdout:
                              VACWATCH_RESULT: { ...json... }
                            The agent reads `returnees` from it, sends one Teams post
                            per returnee, then calls -Mode commit for each.

    -Mode commit            Flip one ledger entry (alias,return_date) to status=sent.

.NOTES
  Windows PowerShell 5.1. ASCII only. Pure helpers are unit-tested in
  tests/team-vacation-watch.tests.ps1.
#>
[CmdletBinding()]
param(
    [ValidateSet('scan', 'commit')]
    [string] $Mode = 'scan',

    # scan inputs
    [string] $WorkIqJsonPath,
    [string] $AsOfDate,
    [int]    $MaxLateWelcomeDays = 2,
    [int]    $MinWorkingDaysForWelcome = 2,
    [switch] $DryRun,
    [switch] $Force,

    # commit inputs
    [string] $CommitAlias,
    [string] $CommitReturnDate,

    # path overrides (default: resolve relative to this script)
    [string] $PeopleDir,
    [string] $StateDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --------------------------------------------------------------------------
# Pure helpers (unit-tested in tests/team-vacation-watch.tests.ps1)
# --------------------------------------------------------------------------
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'vacation-helpers.ps1')
# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------

# Resolve default paths relative to this script.
$skillDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $PeopleDir) { $PeopleDir = Join-Path (Split-Path -Parent $skillDir) 'team-personas\people' }
if (-not $StateDir)  { $StateDir  = Join-Path $skillDir 'state' }
$welcomedPath = Join-Path $StateDir 'welcomed.json'
$snapshotPath = Join-Path $StateDir 'vacation-status.json'

function Read-Ledger {
    if (-not (Test-Path $welcomedPath)) { return @() }
    try {
        $raw = Get-Content $welcomedPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } catch { return @() }
}

function Write-Ledger {
    param([object[]] $Ledger)
    $json = (@($Ledger) | ConvertTo-Json -Depth 6)
    if ($null -eq $json) { $json = '[]' }
    # ConvertTo-Json emits a bare object (not array) for a single element; normalize.
    if ($Ledger.Count -le 1 -and -not $json.TrimStart().StartsWith('[')) { $json = "[$json]" }
    Set-Content -Path $welcomedPath -Value $json -Encoding UTF8
}

if ($Mode -eq 'commit') {
    if (-not $CommitAlias -or -not $CommitReturnDate) {
        Write-Error 'commit mode requires -CommitAlias and -CommitReturnDate.'
        exit 2
    }
    $ledger = @(Read-Ledger)
    $found = $false
    foreach ($e in $ledger) {
        if ($null -eq $e) { continue }
        if (("$($e.alias)") -eq $CommitAlias -and ("$($e.return_date)") -eq $CommitReturnDate) {
            $e | Add-Member -NotePropertyName status -NotePropertyValue 'sent' -Force
            $e | Add-Member -NotePropertyName welcomed_at -NotePropertyValue (Get-Date -Format o) -Force
            $found = $true
        }
    }
    if (-not $found) {
        $ledger += [pscustomobject]@{ alias = $CommitAlias; return_date = $CommitReturnDate; status = 'sent'; welcomed_at = (Get-Date -Format o) }
    }
    if (-not $DryRun) { Write-Ledger -Ledger $ledger }
    Write-Output ("VACWATCH_RESULT: " + (@{ mode = 'commit'; alias = $CommitAlias; return_date = $CommitReturnDate; committed = (-not $DryRun) } | ConvertTo-Json -Compress))
    exit 0
}

# ---- scan mode ----
if (-not $AsOfDate) { $AsOfDate = (Get-Date).ToString('yyyy-MM-dd') }
$today = [datetime]::ParseExact($AsOfDate, 'yyyy-MM-dd', $null)

# 1) Validate WorkIQ JSON BEFORE any mutation.
if (-not $WorkIqJsonPath -or -not (Test-Path $WorkIqJsonPath)) {
    Write-Error "WorkIQ JSON not found at '$WorkIqJsonPath'. Touching nothing."
    exit 2
}
try {
    $wq = Get-Content $WorkIqJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Error "WorkIQ JSON is not parseable. Touching nothing. $($_.Exception.Message)"
    exit 2
}
if ($null -eq $wq -or -not ($wq.PSObject.Properties.Name -contains 'people') -or $null -eq $wq.people) {
    Write-Error "WorkIQ JSON missing 'people'. Touching nothing."
    exit 2
}

# 2) Roster from disk.
$personaFiles = Get-ChildItem -Path $PeopleDir -Filter '*.md' | Where-Object { $_.BaseName -ne 'nirvana' }
$displayToAlias = @{}
$aliasToFile = @{}
foreach ($f in $personaFiles) {
    $alias = $f.BaseName
    $aliasToFile[$alias] = $f.FullName
    $head = Get-Content $f.FullName -TotalCount 1 -Encoding UTF8
    $h1 = [regex]::Match("$head", '^#\s+(.+?)\s*\((.+?)\)\s*$')
    if ($h1.Success) {
        $displayToAlias[$h1.Groups[1].Value.Trim().ToLowerInvariant()] = $alias
    }
    # Always allow alias-as-name fallback too.
    $displayToAlias[$alias.Replace('-', ' ')] = $alias
}

# 3) Current status per alias (default: not on vacation, low confidence).
$current = @{}
foreach ($alias in $aliasToFile.Keys) {
    $current[$alias] = [pscustomobject]@{ on_vacation = $false; start = $null; end = $null; returned_today = $false; confidence = 'low' }
}
$unmatched = @()
foreach ($p in @($wq.people)) {
    $name = "$($p.name)"
    $alias = Resolve-AliasFromName -Name $name -DisplayToAlias $displayToAlias
    if (-not $alias) { $unmatched += $name; continue }
    $onVac = $false; try { $onVac = [bool]$p.on_vacation } catch { $onVac = $false }
    $rt = $false; try { $rt = [bool]$p.returned_today } catch { $rt = $false }
    $conf = 'low'; try { if ($p.confidence) { $conf = "$($p.confidence)" } } catch {}
    $current[$alias] = [pscustomobject]@{
        on_vacation = $onVac
        start = $(if ($p.start) { "$($p.start)" } else { $null })
        end   = $(if ($p.end) { "$($p.end)" } else { $null })
        returned_today = $rt
        confidence = $conf
    }
}

# 4) Prior snapshot.
$priorPeople = $null
$isFirstRun = $true
if (Test-Path $snapshotPath) {
    try {
        $snap = Get-Content $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($snap -and $snap.as_of) { $isFirstRun = $false; $priorPeople = $snap.people }
    } catch { $isFirstRun = $true }
}

# 4b) Low-confidence carry-forward.
# Free/busy resolution is intermittently flaky (a member can fail to resolve on one tick and
# come back 'low'/false). Such a read must NOT erase a known vacation: if this read is
# low-confidence AND not-on-vacation, but the prior snapshot had the person on vacation,
# preserve the prior on_vacation/start/end. This keeps the persona block from flapping AND
# preserves the on_vacation state that a later genuine return needs to detect the transition
# (otherwise a single flake between "on vacation" and "actually returned" silently swallows
# the welcome-back). Marked confidence='carried' so it never itself triggers a returnee.
if ($null -ne $priorPeople) {
    foreach ($alias in @($current.Keys)) {
        $cur = $current[$alias]
        $isLow = ('low' -eq ("$($cur.confidence)").ToLowerInvariant())
        if ($isLow -and -not $cur.on_vacation -and ($priorPeople.PSObject.Properties.Name -contains $alias)) {
            $pr = $priorPeople.$alias
            $priorOnVac = $false; try { $priorOnVac = [bool]$pr.on_vacation } catch { $priorOnVac = $false }
            if ($priorOnVac) {
                $current[$alias] = [pscustomobject]@{
                    on_vacation    = $true
                    start          = $(if ($pr.start) { "$($pr.start)" } else { $null })
                    end            = $(if ($pr.end) { "$($pr.end)" } else { $null })
                    returned_today = $false
                    confidence     = 'carried'
                }
            }
        }
    }
}

# 4c) Working-day welcome hold.
# A weekend return is a one-shot transition, so do not let the snapshot flip to
# not-on-vacation until the next Israel working day can surface the welcome.
if ($null -ne $priorPeople) {
    foreach ($alias in @($current.Keys)) {
        $cur = $current[$alias]
        $okConf = @('high', 'medium') -contains ("$($cur.confidence)").ToLowerInvariant()
        if (-not $okConf -or [bool]$cur.on_vacation) { continue }
        if (-not ($priorPeople.PSObject.Properties.Name -contains $alias)) { continue }
        $pr = $priorPeople.$alias
        $priorOnVac = $false; try { $priorOnVac = [bool]$pr.on_vacation } catch { $priorOnVac = $false }
        if (-not $priorOnVac) { continue }

        $returnDate = $today
        $priorEnd = $null; try { $priorEnd = [string]$pr.end } catch { $priorEnd = $null }
        if (-not [string]::IsNullOrWhiteSpace($priorEnd)) {
            $parsedEnd = [datetime]::MinValue
            if ([datetime]::TryParse($priorEnd, [ref]$parsedEnd)) { $returnDate = $parsedEnd.AddDays(1) }
        }
        $due = Get-WelcomeDueDecision -Today $today -ReturnDate $returnDate -MaxLate $MaxLateWelcomeDays
        if ($due.Decision -eq 'hold') {
            $current[$alias] = [pscustomobject]@{
                on_vacation    = $true
                start          = $(if ($pr.start) { "$($pr.start)" } else { $null })
                end            = $(if ($pr.end) { "$($pr.end)" } else { $null })
                returned_today = $false
                confidence     = 'carried'
            }
        }
    }
}
# 5) Persona upserts (surgical) + 6) returnee computation.
$ledger = @(Read-Ledger)
$onVacationAliases = @()
$returnees = @()
$personaUpdated = 0

foreach ($alias in ($aliasToFile.Keys | Sort-Object)) {
    $cur = $current[$alias]
    if ($cur.on_vacation) { $onVacationAliases += $alias }

    # Persona managed-block upsert (deterministic, EOL-preserving).
    $statusLine = Get-VacationStatusLine -OnVacation:([bool]$cur.on_vacation) -Start $cur.start -End $cur.end -AsOf $AsOfDate
    $file = $aliasToFile[$alias]
    $content = Get-Content $file -Raw -Encoding UTF8
    $newContent = Set-VacationBlockContent -Content $content -StatusLine $statusLine
    if ($newContent -ne $content) {
        $personaUpdated++
        if (-not $DryRun) {
            # Preserve original byte EOL by writing without added trailing newline.
            [System.IO.File]::WriteAllText($file, $newContent, (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    # Returnee decision.
    $prior = $null
    if ($null -ne $priorPeople -and ($priorPeople.PSObject.Properties.Name -contains $alias)) {
        $prior = $priorPeople.$alias
    }
    $decision = Get-ReturneeDecision -IsFirstRun:$isFirstRun -CurOnVacation:([bool]$cur.on_vacation) `
        -CurConfidence $cur.confidence -ReturnedToday:([bool]$cur.returned_today) -Prior $prior -Today $today
    if (-not $decision.IsReturnee) { continue }

    $rd = $decision.ReturnDate
    if ([string]::IsNullOrWhiteSpace($rd)) { continue }

    $rdDate = [datetime]::ParseExact($rd, 'yyyy-MM-dd', $null)
    $due = Get-WelcomeDueDecision -Today $today -ReturnDate $rdDate -MaxLate $MaxLateWelcomeDays
    if ($due.Decision -ne 'due') { continue }

    # Idempotency.
    if (-not $Force -and (Test-AlreadyWelcomed -Ledger $ledger -Alias $alias -ReturnDate $rd)) { continue }

    # Recent in-flight pending claim (<30 min) -> skip to avoid racing a slow Power Automate pickup.
    $recentPending = $false
    foreach ($e in $ledger) {
        if ($null -eq $e) { continue }
        if (("$($e.alias)") -eq $alias -and ("$($e.return_date)") -eq $rd -and ("$($e.status)") -eq 'pending') {
            $claimedAt = [datetime]::MinValue
            if ([datetime]::TryParse("$($e.claimed_at)", [ref]$claimedAt)) {
                if (((Get-Date) - $claimedAt).TotalMinutes -lt 30) { $recentPending = $true }
            }
        }
    }
    if ($recentPending -and -not $Force) { continue }

    $vacStart = $null
    $vacEnd = $null
    $vacDays = $null
    $vacWorkDays = $null
    if ($null -ne $prior) {
        try { if ($prior.start) { $vacStart = "$($prior.start)" } } catch {}
        try { if ($prior.end) { $vacEnd = "$($prior.end)" } } catch {}
        if (-not [string]::IsNullOrWhiteSpace($vacStart) -and -not [string]::IsNullOrWhiteSpace($vacEnd)) {
            $startDate = [datetime]::MinValue
            $endDate = [datetime]::MinValue
            if ([datetime]::TryParse($vacStart, [ref]$startDate) -and [datetime]::TryParse($vacEnd, [ref]$endDate)) {
                $vacDays = [int]($endDate.Date - $startDate.Date).Days + 1
                $vacWorkDays = Get-WorkingDayCount -Start $startDate -End $endDate
            }
        }
    }

    # Minimum-working-days gate (Nir's rule): only welcome someone back if the vacation
    # cost at least $MinWorkingDaysForWelcome Israel working days (Sun-Thu). This silently
    # drops weekend-only absences (Fri/Sat -> 0 working days) and one-working-day absences
    # flanked by the weekend (e.g. Thu+Fri+Sat -> 1 working day). When the span is unknown
    # (no prior start/end, e.g. a first-run explicit return) we cannot measure it, so we do
    # NOT suppress -- never swallow a genuine return just because its length is unknown.
    if ($null -ne $vacWorkDays -and $vacWorkDays -lt $MinWorkingDaysForWelcome) {
        continue
    }

    $first = (Get-Culture).TextInfo.ToTitleCase($alias.Split('-')[0])
    $returnees += [pscustomobject]@{
        alias = $alias
        first_name = $first
        return_date = $rd
        reason = $decision.Reason
        vac_start = $vacStart
        vac_end = $vacEnd
        vac_days = $vacDays
        vac_work_days = $vacWorkDays
    }

    # Append a 'pending' claim (unless DryRun).
    $ledger += [pscustomobject]@{ alias = $alias; return_date = $rd; status = 'pending'; claimed_at = (Get-Date -Format o) }
}

if (-not $DryRun) { Write-Ledger -Ledger $ledger }

# 7) Snapshot LAST.
$snapPeople = @{}
foreach ($alias in $current.Keys) {
    $c = $current[$alias]
    $snapPeople[$alias] = [ordered]@{ on_vacation = [bool]$c.on_vacation; start = $c.start; end = $c.end; confidence = "$($c.confidence)" }
}
$snapshot = [ordered]@{ as_of = $AsOfDate; people = $snapPeople }
if (-not $DryRun) {
    Set-Content -Path $snapshotPath -Value ($snapshot | ConvertTo-Json -Depth 6) -Encoding UTF8
}

# 8) Emit machine-readable result for the agent.
$result = [ordered]@{
    mode = 'scan'
    as_of = $AsOfDate
    dry_run = [bool]$DryRun
    first_run = [bool]$isFirstRun
    on_vacation = @($onVacationAliases | Sort-Object)
    returnees = @($returnees)
    persona_updated = $personaUpdated
    unmatched_workiq_names = @($unmatched)
}
Write-Output ("VACWATCH_RESULT: " + ($result | ConvertTo-Json -Depth 6 -Compress))
exit 0
