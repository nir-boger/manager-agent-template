# Runs the daily-capture skill non-interactively (replaces Cowork's OneDrive feed).
#
# Two phases, each driven by a copilot subprocess (the only path to the WorkIQ
# MCP read tool):
#   A. Daily activity summary  -> DailySummary_<date>.md  (local handoff: reports\daily-capture\published\daily-summary)
#   B. Per-direct-report 24h capture -> 14 .md files       (local handoff: reports\daily-capture\published\personas\<date>)
#
# The subprocess only RETRIEVES + DRAFTS into a staging folder under the agent
# root. This runner owns preflight, per-phase/per-person STATE, output VALIDATION,
# atomic PUBLISH to the local handoff folder, and the single signed summary email.
# Subprocesses never send mail.
#
# Both importers (run-personas-import.ps1 / run-daily-summary-import.ps1) run on
# this same machine and poll the handoff folder every 10 min, so the producer
# publishes to a local reports folder -- no OneDrive round-trip (Cowork's old
# OneDrive delivery channel is retired).
#
# Idempotency keys on reports/daily-capture/state/<date>.json (NOT on output-file
# existence -- the importer deletes the summary after ingest).
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .copilot/skills/run-daily-capture.ps1
# Flags: -Force (ignore state), -OnlyA, -OnlyB, -DryRun (compose only; no spawn/publish/email).
#
# Scheduled by: DM-DailyCapture (daily 18:00 IST, execution_time_limit PT45M).

[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $OnlyA,
    [switch] $OnlyB,
    [switch] $DryRun,
    # Suppress the per-run summary email (used by multi-day backfill, which sends
    # one consolidated email afterward).
    [switch] $NoEmail,
    # Backfill a specific past day (yyyy-MM-dd). When set, the capture window is
    # that calendar day 00:00:00 -> 23:59:59 local instead of now-minus-24h.
    [string] $Date
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')
. (Join-Path $PSScriptRoot '_runner-email.ps1')

# --- Paths + run context -----------------------------------------------------
$now          = Get-Date
if ($Date) {
    try {
        $target = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "Invalid -Date '$Date'. Expected yyyy-MM-dd."
    }
    if ($target.Date -gt $now.Date) { throw "Refusing to backfill a future date: $Date." }
    $dateStr      = $target.ToString('yyyy-MM-dd')
    $windowStart  = $target.Date.ToString('o')                                  # 00:00:00 local
    $windowEnd    = $target.Date.AddDays(1).AddSeconds(-1).ToString('o')        # 23:59:59 local
    $isBackfill   = $true
} else {
    $dateStr      = $now.ToString('yyyy-MM-dd')
    $windowStart  = $now.AddHours(-24).ToString('o')
    $windowEnd    = $now.ToString('o')
    $isBackfill   = $false
}

$skillDir     = Join-Path $AgentRoot '.copilot\skills\daily-capture'
$promptAPath  = Join-Path $skillDir 'prompt-daily-summary.md'
$promptBPath  = Join-Path $skillDir 'prompt-personas-capture.md'

$captureRoot  = Join-Path $AgentRoot 'reports\daily-capture'
$stateDir     = Join-Path $captureRoot 'state'
$stateFile    = Join-Path $stateDir ("$dateStr.json")
$stagingDir   = Join-Path $captureRoot ("staging\$dateStr")
$stagingSummary   = Join-Path $stagingDir ("DailySummary_$dateStr.md")
$stagingPersonas  = Join-Path $stagingDir 'personas'

# Local handoff folders (both importers run on this same machine, so the producer
# publishes to a local reports folder -- no OneDrive round-trip).
$handoffSummaryDir  = Resolve-AgentPath (Get-AgentField -Path 'paths.daily_capture_summary' -Default 'reports/daily-capture/published/daily-summary' -Config $AgentConfig) -Config $AgentConfig
$handoffPersonasRoot = Resolve-AgentPath (Get-AgentField -Path 'paths.daily_capture_personas' -Default 'reports/daily-capture/published/personas' -Config $AgentConfig) -Config $AgentConfig
$handoffPersonasDir = Join-Path $handoffPersonasRoot $dateStr
$publishedSummary   = Join-Path $handoffSummaryDir ("DailySummary_$dateStr.md")

New-Item -ItemType Directory -Force -Path $stateDir, $stagingDir, $stagingPersonas | Out-Null

$logFile = Join-Path $LogDir ("daily-capture-" + $now.ToString('yyyy-MM-dd_HHmm') + ".log")
function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Canonical filename list for the 14 direct reports (must match prompt-personas-capture.md).
$personaFiles = @(
    'Teammate9.md','Teammate10.md','Teammate14.md','Teammate2.md',
    'Teammate1.md','Teammate13.md','Teammate12.md','Teammate8.md',
    'Teammate4.md','Teammate7.md','Teammate5.md','Teammate3.md',
    'Teammate6.md','Teammate11.md'
)

# --- State helpers -----------------------------------------------------------
function Get-CaptureState {
    if (Test-Path $stateFile) {
        try {
            $raw = Get-Content -Raw -Encoding UTF8 $stateFile | ConvertFrom-Json
            $h = @{}
            foreach ($p in $raw.PSObject.Properties) { $h[$p.Name] = $p.Value }
            return $h
        } catch { Write-Log "WARN: could not parse state file ($_); starting fresh." }
    }
    return @{ date = $dateStr; A = $null; B = $null }
}
function Save-CaptureState {
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $stateFile -Encoding UTF8
}

# --- Validation helpers (pure) ----------------------------------------------
function Test-DailySummaryValid {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return [pscustomobject]@{ Ok = $false; Reason = 'file missing'; People = 0 } }
    $c = Get-Content -Raw -Encoding UTF8 $Path
    if ([string]::IsNullOrWhiteSpace($c) -or $c.Length -lt 120) {
        return [pscustomobject]@{ Ok = $false; Reason = 'file empty/too short'; People = 0 }
    }
    $hasByPerson = ($c -match '(?m)^##\s+(By Person|Activity by Person)\s*$')
    if (-not $hasByPerson) {
        return [pscustomobject]@{ Ok = $false; Reason = 'missing ## By Person section'; People = 0 }
    }
    $people = ([regex]::Matches($c, '(?m)^###\s+.+$')).Count
    $noActivity = ($c -match '(?i)No personal activity captured')
    if ($people -lt 1 -and -not $noActivity) {
        return [pscustomobject]@{ Ok = $false; Reason = 'no ### person blocks and no no-activity sentinel'; People = 0 }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'ok'; People = $people }
}

function Test-PersonaFileValid {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $c = Get-Content -Raw -Encoding UTF8 $Path
    if ([string]::IsNullOrWhiteSpace($c) -or $c.Length -lt 80) { return $false }
    # Every persona file must carry the fidelity caveat (no-verbatim guarantee).
    if ($c -notmatch '(?i)Fidelity note:') { return $false }
    return $true
}

# --- Prompt composition ------------------------------------------------------
function Expand-Prompt {
    param([string]$TemplatePath, [hashtable]$Tokens)
    $t = Get-Content -Raw -Encoding UTF8 $TemplatePath
    foreach ($k in $Tokens.Keys) { $t = $t.Replace('{{' + $k + '}}', [string]$Tokens[$k]) }
    return $t
}

# --- Preflight ---------------------------------------------------------------
$preflightOk = $true
try {
    New-Item -ItemType Directory -Force -Path $handoffSummaryDir, $handoffPersonasDir | Out-Null
} catch {
    $preflightOk = $false
    Write-Log "ERROR: local handoff folder not available and could not be created: $handoffSummaryDir / $handoffPersonasDir ($_)"
}

Write-Log "daily-capture start date=$dateStr backfill=$isBackfill window=[$windowStart .. $windowEnd] force=$Force onlyA=$OnlyA onlyB=$OnlyB dryrun=$DryRun"
$state = Get-CaptureState
$runA = -not $OnlyB
$runB = -not $OnlyA

# Accumulate per-phase outcome for the summary email taxonomy.
$report = [ordered]@{ A = 'not run'; B = 'not run'; A_people = 0; B_files = 0; B_published = @() }

# ============================ PHASE A ========================================
if ($runA) {
    $alreadyA = ($state.A -and ($state.A.status -eq 'published'))
    if ($alreadyA -and -not $Force) {
        $report.A = 'skipped (already published in state)'
        Write-Log "Phase A: skipped - state shows published for $dateStr."
    } else {
        Remove-Item -Path $stagingSummary -Force -ErrorAction SilentlyContinue
        $promptA = Expand-Prompt -TemplatePath $promptAPath -Tokens @{
            DATE         = $dateStr
            STAGING_FILE = $stagingSummary
        }
        if ($DryRun) {
            $report.A = "dry-run (prompt $($promptA.Length) chars -> $stagingSummary)"
            Write-Log "Phase A: DRY-RUN - composed prompt ($($promptA.Length) chars); not spawning."
        } else {
            Write-Log "Phase A: invoking copilot for daily summary..."
            $logA = Join-Path $LogDir ("daily-capture-" + $now.ToString('yyyy-MM-dd_HHmm') + "_A.log")
            $r = Invoke-CopilotAgent -Prompt $promptA -LogFile $logA
            if ($r.ExitCode -ne 0) { Write-Log "Phase A: copilot exited $($r.ExitCode) (continuing to validation)." }

            $v = Test-DailySummaryValid -Path $stagingSummary
            if (-not $v.Ok) {
                $report.A = "FAILED validation: $($v.Reason)"
                $state.A = @{ status = 'failed'; reason = $v.Reason; at = (Get-Date -Format o) }
                Write-Log "Phase A: validation FAILED - $($v.Reason). Not publishing."
            } else {
                try {
                    New-Item -ItemType Directory -Force -Path $handoffSummaryDir | Out-Null
                    Copy-Item -Path $stagingSummary -Destination $publishedSummary -Force
                    $report.A = "published ($($v.People) people)"
                    $report.A_people = $v.People
                    $state.A = @{ status = 'published'; people = $v.People; path = $publishedSummary; at = (Get-Date -Format o) }
                    Write-Log "Phase A: published -> $publishedSummary ($($v.People) people)."
                } catch {
                    $report.A = "validated but PUBLISH failed: $_"
                    $state.A = @{ status = 'publish-failed'; reason = "$_"; at = (Get-Date -Format o) }
                    Write-Log "Phase A: publish FAILED - $_"
                }
            }
            Save-CaptureState -State $state
        }
    }
}

# ============================ PHASE B ========================================
if ($runB) {
    $bPrev = if ($state.B -and $state.B.persons) { $state.B.persons } else { $null }
    $allPublished = $false
    if ($bPrev) {
        $pubCount = @($personaFiles | Where-Object {
            $bPrev.PSObject.Properties[$_] -and $bPrev.$_ -eq 'published'
        }).Count
        $allPublished = ($pubCount -eq $personaFiles.Count)
    }
    if ($allPublished -and -not $Force) {
        $report.B = 'skipped (all 14 already published in state)'
        Write-Log "Phase B: skipped - state shows all 14 published for $dateStr."
    } else {
        Get-ChildItem -Path $stagingPersonas -Filter '*.md' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $promptB = Expand-Prompt -TemplatePath $promptBPath -Tokens @{
            DATE         = $dateStr
            WINDOW_START = $windowStart
            WINDOW_END   = $windowEnd
            STAGING_DIR  = $stagingPersonas
        }
        if ($DryRun) {
            $report.B = "dry-run (prompt $($promptB.Length) chars -> $stagingPersonas)"
            Write-Log "Phase B: DRY-RUN - composed prompt ($($promptB.Length) chars); not spawning."
        } else {
            Write-Log "Phase B: invoking copilot for personas capture (14 reports)..."
            $logB = Join-Path $LogDir ("daily-capture-" + $now.ToString('yyyy-MM-dd_HHmm') + "_B.log")
            $r = Invoke-CopilotAgent -Prompt $promptB -LogFile $logB
            if ($r.ExitCode -ne 0) { Write-Log "Phase B: copilot exited $($r.ExitCode) (continuing to validation)." }

            New-Item -ItemType Directory -Force -Path $handoffPersonasDir | Out-Null
            $persons = @{}
            $publishedNames = New-Object System.Collections.ArrayList
            foreach ($f in $personaFiles) {
                $staged = Join-Path $stagingPersonas $f
                if (Test-PersonaFileValid -Path $staged) {
                    try {
                        Copy-Item -Path $staged -Destination (Join-Path $handoffPersonasDir $f) -Force
                        $persons[$f] = 'published'
                        [void]$publishedNames.Add($f)
                    } catch {
                        $persons[$f] = 'publish-failed'
                        Write-Log "Phase B: publish FAILED for $f - $_"
                    }
                } else {
                    $persons[$f] = 'missing-or-invalid'
                }
            }
            $report.B_files = $publishedNames.Count
            $report.B_published = @($publishedNames)
            $report.B = "$($publishedNames.Count)/$($personaFiles.Count) published"
            $state.B = @{ status = 'done'; published = $publishedNames.Count; total = $personaFiles.Count; path = $handoffPersonasDir; persons = $persons; at = (Get-Date -Format o) }
            Save-CaptureState -State $state
            Write-Log "Phase B: $($publishedNames.Count)/$($personaFiles.Count) persona files published -> $handoffPersonasDir"
        }
    }
}

# ============================ SUMMARY EMAIL ==================================
if ($DryRun) {
    Write-Log "DRY-RUN complete. A=$($report.A) | B=$($report.B). No email sent."
    return
}

if (-not $preflightOk) {
    Write-Log "Preflight failed earlier; attempting summary email anyway."
}

if ($NoEmail) {
    Write-Log "NoEmail: skipping per-run summary email. A=$($report.A) | B=$($report.B)."
    Write-Log "daily-capture complete. A=$($report.A) | B=$($report.B)."
    return
}

$publishedRoot = Join-Path $captureRoot 'published'
$handoffLink = "file:///" + ($publishedRoot -replace '\\','/')
$bodyParts = New-Object System.Collections.ArrayList
[void]$bodyParts.Add("<p>Daily capture for <b>$dateStr</b> (window $windowStart to $windowEnd):</p>")
[void]$bodyParts.Add("<ul>")
[void]$bodyParts.Add("<li><b>Daily summary (A):</b> $($report.A)" + $(if ($report.A -match 'published') { " &mdash; <code>$publishedSummary</code>" } else { '' }) + "</li>")
[void]$bodyParts.Add("<li><b>Personas capture (B):</b> $($report.B)" + $(if ($report.B_files -gt 0) { " &mdash; <code>$handoffPersonasDir</code>" } else { '' }) + "</li>")
[void]$bodyParts.Add("</ul>")
if ($report.B_files -gt 0 -and $report.B_files -lt $personaFiles.Count) {
    $missing = @($personaFiles | Where-Object { $report.B_published -notcontains $_ })
    [void]$bodyParts.Add("<p style='color:#8a5a00'>Personas not published this run: " + ($missing -join ', ') + "</p>")
}
[void]$bodyParts.Add("<p>Handoff folder (local): <a href='$handoffLink'>$publishedRoot</a></p>")
[void]$bodyParts.Add("<p style='color:#666'>The DailySummary file is picked up automatically by DM-DailySummaryImport (every 10 min). Personas files are a raw-ish data drop for later analysis. Fidelity note: WorkIQ summarizes, so personas bodies are paraphrased, not verbatim.</p>")

$jokes = @(
    "WorkIQ paraphrases everything, so if a persona file reads wiser than the original Teams chat, call it a productivity gain.",
    "Cowork clocked out for good on May 28 - I picked up the 18:00 shift, no severance required.",
    "Fourteen personas captured and not one asked why their manager's agent reads their chats at dinnertime.",
    "I summarized the whole day in one file - which is one more file than Cowork managed all last week."
)

try {
    [void](Send-RunnerSummaryEmail `
        -RunnerName 'DM-DailyCapture' `
        -SubjectSuffix "$dateStr - A: $($report.A); B: $($report.B)" `
        -BodyHtml ($bodyParts -join "`n") `
        -JokePool $jokes)
    Write-Log "Summary email sent."
} catch {
    Write-Log "WARN: summary email failed - $_"
}

Write-Log "daily-capture complete. A=$($report.A) | B=$($report.B)."

