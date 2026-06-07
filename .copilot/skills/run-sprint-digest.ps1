# Weekly sprint-digest email (Nir-only) focused on schedule slippage.
#
# Pulls the current iteration for "Your Team" from ADO, classifies
# Task+Bug items, and emails Nir a pace read (working-day elapsed vs work done,
# current-scope AND baseline-scope), a not-started table, a by-person breakdown,
# and an item delta since the last digest.
#
# Distinct from:
#   - sprint-report-daily  (a daily markdown file, no email)
#   - semester-plan-report (Feature/PBI external dashboard for leadership)
#
# Manual run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\.copilot\skills\run-sprint-digest.ps1
# Flags:
#   -DryRun    fetch + compute + log + render, do NOT send and do NOT stamp state
#   -Force     bypass the per-iteration-per-week idempotency check
#   -AsOfDate  override "today" for testing (YYYY-MM-DD)
# Scheduled by: DM-SprintDigest (weekly, Sundays 09:00 IST).
# Idempotency: state\last-sent.txt keyed on "<iterationId>|<sunday-week-start>".

[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Force,
    [string] $AsOfDate
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$skillDir      = Join-Path $AgentRoot '.copilot\skills\sprint-digest'
$stateDir      = Join-Path $skillDir 'state'
$sentFile      = Join-Path $stateDir 'last-sent.txt'
$snapshotFile  = Join-Path $stateDir 'last-snapshot.json'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$logFile = Join-Path $LogDir ("sprint-digest-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

$mgrEmail      = Get-AgentField -Path 'manager.email'             -Default 'you@example.com' -Config $AgentConfig
$subjectPrefix = Get-AgentField -Path 'agent.mail_subject_prefix' -Default '[Nirvana]'               -Config $AgentConfig

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

. (Join-Path $skillDir 'render.ps1')

$today = if ($AsOfDate) { [DateTime]::ParseExact($AsOfDate, 'yyyy-MM-dd', $null).Date } else { (Get-Date).Date }
# Sunday on/before today starts the Sun-Thu work week.
$sundayStart   = $today.AddDays(-[int]$today.DayOfWeek)
$sundayStartIso = $sundayStart.ToString('yyyy-MM-dd')

Write-Log "==== sprint-digest start (DryRun=$DryRun Force=$Force AsOf=$($today.ToString('yyyy-MM-dd'))) ===="

# --- ADO auth ------------------------------------------------------------
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) { Write-Log "FATAL: 'az' CLI not found on PATH. Cannot reach ADO."; exit 1 }
Write-Log "az resolved: $($azCmd.Source)"

$token = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv) 2>$null
if (-not $token) { Write-Log "FATAL: failed to acquire ADO token via az. Run 'az login'."; exit 1 }
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

$org     = "https://your-ado-org.visualstudio.com"
$project = "One"
$team    = "Your Team"
$teamEnc = [uri]::EscapeDataString($team)

# --- current iteration ---------------------------------------------------
$cur = $null
try {
    $iterUrl  = "$org/$project/$teamEnc/_apis/work/teamsettings/iterations?`$timeframe=current&api-version=7.1"
    $iterResp = Invoke-RestMethod -Method GET -Uri $iterUrl -Headers $headers
    if ($iterResp.value -and $iterResp.value.Count -gt 0) { $cur = $iterResp.value[0] }
} catch {
    Write-Log "FATAL: iteration lookup failed: $($_.Exception.Message)"
    exit 1
}
if (-not $cur) {
    Write-Log "No current iteration for '$team'. Nothing to digest (not stamping state)."
    exit 0
}

$iterId   = $cur.id
$iterName = $cur.name
$startDate  = if ($cur.attributes.startDate)  { ([datetime]$cur.attributes.startDate).ToLocalTime().Date }  else { $null }
$finishDate = if ($cur.attributes.finishDate) { ([datetime]$cur.attributes.finishDate).ToLocalTime().Date } else { $null }
Write-Log "Iteration: $iterName ($iterId)  start=$startDate finish=$finishDate"

if (-not $startDate -or -not $finishDate) {
    Write-Log "Iteration is missing start/finish dates; cannot compute pace. Exiting without stamping."
    exit 0
}

# --- idempotency ---------------------------------------------------------
$idemKey = "$iterId|$sundayStartIso"
$alreadySent = $false
if (-not $Force -and (Test-Path $sentFile)) {
    foreach ($line in (Get-Content $sentFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line.Trim() -eq $idemKey) { $alreadySent = $true; break }
    }
}
if ($alreadySent) {
    Write-Log "Digest already sent for this iteration/week ($idemKey). Skipping. Use -Force to override."
    exit 0
}

# --- iteration work items ------------------------------------------------
$ids = @()
try {
    $wiUrl = "$org/$project/$teamEnc/_apis/work/teamsettings/iterations/$iterId/workitems?api-version=7.1"
    $wi    = Invoke-RestMethod -Method GET -Uri $wiUrl -Headers $headers
    $ids   = @($wi.workItemRelations | ForEach-Object { [int]$_.target.id } | Select-Object -Unique)
} catch {
    Write-Log "FATAL: iteration workitems lookup failed: $($_.Exception.Message)"
    exit 1
}
Write-Log "Iteration has $($ids.Count) work item(s)."

if ($ids.Count -eq 0) {
    Write-Log "Iteration has zero work items; nothing to measure. Exiting without stamping."
    exit 0
}

# --- batch fetch fields --------------------------------------------------
$fieldList = @('System.Id','System.Title','System.WorkItemType','System.State','System.AssignedTo')
$fetched = New-Object System.Collections.Generic.List[object]
try {
    for ($i = 0; $i -lt $ids.Count; $i += 200) {
        $batch = @($ids[$i..([Math]::Min($i+199, $ids.Count - 1))])
        $body  = @{ ids = $batch; fields = $fieldList } | ConvertTo-Json -Depth 4 -Compress
        $resp  = Invoke-RestMethod -Method POST -Uri "$org/$project/_apis/wit/workitemsbatch?api-version=7.1" -Headers $headers -Body $body
        foreach ($it in $resp.value) { $fetched.Add($it) | Out-Null }
    }
} catch {
    Write-Log "FATAL: workitemsbatch failed: $($_.Exception.Message)"
    exit 1
}
Write-Log "Fetched $($fetched.Count) work item(s)."

# --- normalize -----------------------------------------------------------
$items = foreach ($it in $fetched) {
    $f = $it.fields
    $assignee = ''
    if ($f.'System.AssignedTo' -and $f.'System.AssignedTo'.displayName) { $assignee = [string]$f.'System.AssignedTo'.displayName }
    [pscustomobject]@{
        Id         = [int]$f.'System.Id'
        Title      = [string]$f.'System.Title'
        Type       = [string]$f.'System.WorkItemType'
        State      = [string]$f.'System.State'
        AssignedTo = $assignee
        Class      = Get-WorkItemStateClass -State ([string]$f.'System.State')
    }
}

# Pace measures delivery units: Task + Bug only, exclude removed/cut.
$units = @($items | Where-Object { $_.Type -in @('Task','Bug') -and $_.Class -ne 'removed' })
$total = $units.Count
$done  = @($units | Where-Object { $_.Class -eq 'done' }).Count
Write-Log "Delivery units (Task+Bug, not removed): $total ; done: $done"

# --- baseline scope (snapshot of IDs on first run for this iteration) -----
$baselineFile = Join-Path $stateDir ("baseline-$iterId.json")
$baselineIds  = $null
if (Test-Path $baselineFile) {
    try {
        $b = Get-Content $baselineFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $baselineIds = @($b.ids | ForEach-Object { [int]$_ })
    } catch { $baselineIds = $null }
}
if (-not $baselineIds) {
    $baselineIds = @($units | ForEach-Object { $_.Id })
    if (-not $DryRun) {
        (@{ iterationId = "$iterId"; capturedOn = (Get-Date -Format o); ids = $baselineIds } | ConvertTo-Json -Depth 4 -Compress) |
            Set-Content -Path $baselineFile -Encoding UTF8
        Write-Log "Captured baseline scope ($($baselineIds.Count) ids) -> $baselineFile"
    } else {
        Write-Log "[DryRun] would capture baseline scope ($($baselineIds.Count) ids)."
    }
}
$baselineSet  = @{}; foreach ($bid in $baselineIds) { $baselineSet["$bid"] = $true }
$unitById     = @{}; foreach ($u in $units) { $unitById["$($u.Id)"] = $u }

$baselinePresent = @($baselineIds | Where-Object { $unitById.ContainsKey("$_") })
$baselineTotal   = $baselinePresent.Count
$baselineDone    = @($baselinePresent | Where-Object { $unitById["$_"].Class -eq 'done' }).Count
$addedSinceStart = @($units | Where-Object { -not $baselineSet.ContainsKey("$($_.Id)") }).Count

# --- pace math -----------------------------------------------------------
$totalDays   = Get-WorkingDaysInRange -Start $startDate -End $finishDate
$elapsedDays = [Math]::Min((Get-ElapsedWorkingDays -Start $startDate -Today $today), $totalDays)
$daysLeft    = Get-WorkingDaysInRange -Start $today -End $finishDate

$elapsedFraction    = Get-Fraction -Numerator $elapsedDays -Denominator $totalDays
$completionFraction = Get-Fraction -Numerator $done -Denominator $total
$baselineFraction   = Get-Fraction -Numerator $baselineDone -Denominator $baselineTotal
$verdict            = Get-PaceVerdict -CompletionFraction $completionFraction -ElapsedFraction $elapsedFraction

$pace = [pscustomobject]@{
    ElapsedFraction    = $elapsedFraction
    CompletionFraction = $completionFraction
    BaselineFraction   = $baselineFraction
    ElapsedDays        = $elapsedDays
    TotalDays          = $totalDays
    Done               = $done
    Total              = $total
    BaselineDone       = $baselineDone
    BaselineTotal      = $baselineTotal
    AddedSinceStart    = $addedSinceStart
    WorkingDaysLeft    = $daysLeft
    Verdict            = $verdict.Verdict
    Color              = $verdict.Color
}
Write-Log "Pace: elapsed=$(Format-Pct $elapsedFraction) done=$(Format-Pct $completionFraction) baseline=$(Format-Pct $baselineFraction) verdict=$($verdict.Verdict) daysLeft=$daysLeft"

# --- not-started + by-person ---------------------------------------------
$notStarted = @($units | Where-Object { $_.Class -eq 'notstarted' } | Sort-Object @{e={ (Get-AssigneeName $_) }}, Id)

$byPerson = @(
    $units | Group-Object { Get-AssigneeName $_ } | ForEach-Object {
        $g = $_.Group
        [pscustomobject]@{
            Person     = $_.Name
            NotStarted = @($g | Where-Object { $_.Class -eq 'notstarted' }).Count
            InProgress = @($g | Where-Object { $_.Class -eq 'inprogress' }).Count
            Done       = @($g | Where-Object { $_.Class -eq 'done' }).Count
            Total      = $g.Count
        }
    } | Sort-Object @{e='NotStarted';Descending=$true}, @{e='Total';Descending=$true}, Person
)

# --- delta since last digest ---------------------------------------------
$prev = $null
if (Test-Path $snapshotFile) {
    try { $prev = Get-Content $snapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $prev = $null }
}
$hasPrev = ($prev -and ("$($prev.iterationId)" -eq "$iterId"))

function Get-ItemLabel { param($Item) $t = [string]$Item.Title; if ($t.Length -gt 42) { $t = $t.Substring(0,40) + '..' }; return "#$($Item.Id) $t" }

$delta = [pscustomobject]@{ Completed = @(); Added = @(); Removed = @(); Reopened = @() }
if ($hasPrev) {
    $prevMap = @{}
    foreach ($p in $prev.items.PSObject.Properties) { $prevMap[$p.Name] = $p.Value }
    foreach ($u in $units) {
        $key = "$($u.Id)"
        if ($prevMap.ContainsKey($key)) {
            $prevClass = [string]$prevMap[$key].class
            if ($u.Class -eq 'done'  -and $prevClass -ne 'done') { $delta.Completed += (Get-ItemLabel $u) }
            if ($u.Class -ne 'done'  -and $prevClass -eq 'done') { $delta.Reopened  += (Get-ItemLabel $u) }
        } else {
            $delta.Added += (Get-ItemLabel $u)
        }
    }
    $curKeys = @{}; foreach ($u in $units) { $curKeys["$($u.Id)"] = $true }
    foreach ($k in $prevMap.Keys) {
        if (-not $curKeys.ContainsKey($k)) {
            $pv = $prevMap[$k]
            $t = [string]$pv.title; if ($t.Length -gt 42) { $t = $t.Substring(0,40) + '..' }
            $delta.Removed += "#$k $t"
        }
    }
    Write-Log "Delta: completed=$($delta.Completed.Count) added=$($delta.Added.Count) removed=$($delta.Removed.Count) reopened=$($delta.Reopened.Count)"
} else {
    Write-Log "No comparable prior snapshot for this iteration (first digest)."
}

# --- compose email -------------------------------------------------------
$winLabel = "$($startDate.ToString('MMM d')) &ndash; $($finishDate.ToString('MMM d'))"
$header = "<p style='font-size:15px;margin:0 0 2px 0'><b>Sprint digest &mdash; $(Format-SdField $iterName)</b></p>" +
          "<p style='color:#777;font-size:12px;margin:0 0 6px 0'>$winLabel &middot; as of $($today.ToString('ddd MMM d'))</p>"

$ribbon     = Render-PaceRibbon  -Pace $pace
$nsTable    = Render-ItemTable   -Heading 'Not started' -Items $notStarted -Cap 20
$personTbl  = Render-ByPersonTable -Rows $byPerson
$deltaPanel = Render-DeltaPanel  -Delta $delta -HasPrev $hasPrev

$footer = "<p style='color:#666;font-size:12px;margin-top:14px'>Scope: Task + Bug in the current iteration (PBIs and Removed excluded from the pace math). " +
          "Working week is Sun&ndash;Thu. See something worth tracking? Tell me &mdash; <code>add a risk: &lt;text&gt;</code>.</p>"

$jokes = @(
    "Burndown charts: the only place 'behind' is a measurable state, not a feeling.",
    "Smells like sprint spirit &mdash; about 50% of it, anyway.",
    "A To Do item left untouched all sprint is just a New Year's resolution with a work-item ID.",
    "The plan was on track; the calendar disagreed.",
    "Velocity is a vector &mdash; direction matters, and ours points at Thursday.",
    "Come as you are, but please move your card to In Progress."
)
$joke = $jokes | Get-Random
$jokeHtml = "<p style='color:#555;font-style:italic;margin-top:14px'>$joke</p>"

. (Join-Path $PSScriptRoot '_shared\signature.ps1')
$signature = Get-NirvanaSignature

# Subject is a plain-text field: use a real em-dash (built from ASCII source) instead of the HTML entity, which would show literally.
$emDash  = [char]0x2014
$subject = "$subjectPrefix Sprint digest $emDash ${iterName}: $($verdict.Verdict.ToLower()) ($(Format-Pct $completionFraction) done, $(Format-Pct $elapsedFraction) elapsed)"

$html = "<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#242424'>" +
        $header + $ribbon + $nsTable + $personTbl + $deltaPanel + $footer + $jokeHtml + $signature +
        "</body></html>"

Write-Log "Subject: $subject"

# --- snapshot to write on success ----------------------------------------
$snapItems = @{}
foreach ($u in $units) {
    $snapItems["$($u.Id)"] = @{ state = $u.State; type = $u.Type; assignee = $u.AssignedTo; title = $u.Title; class = $u.Class }
}
$snapshotObj = @{ key = $idemKey; iterationId = "$iterId"; capturedOn = (Get-Date -Format o); items = $snapItems }

if ($DryRun) {
    $previewPath = Join-Path $stateDir 'preview.html'
    $html | Set-Content -Path $previewPath -Encoding UTF8
    Write-Log "[DryRun] wrote preview -> $previewPath ; not sending, not stamping."
    return
}

# --- send via Outlook COM ------------------------------------------------
. (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
. (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')
$_ensureLog = Join-Path $LogDir 'ensure-outlook.log'
if (-not (Ensure-OutlookRunning -LogFile $_ensureLog)) { Write-Log "Outlook not available; exiting without stamping."; exit 0 }

try {
    $ol   = New-Object -ComObject Outlook.Application
    $mail = $ol.CreateItem(0)
    $mail.To       = $mgrEmail
    $mail.Subject  = $subject
    $mail.HTMLBody = $html
    if (Test-MigrationMode) {
        Write-Log "  [migration-mode] Skipping Send() for: $subject"
    } else {
        $mail.Send() | Out-Null
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
    Write-Log "Sent."

    ($snapshotObj | ConvertTo-Json -Depth 6 -Compress) | Set-Content -Path $snapshotFile -Encoding UTF8
    Add-Content -Path $sentFile -Value $idemKey -Encoding UTF8
    Write-Log "Stamped idempotency key + wrote snapshot."
}
catch {
    Write-Log "  WARN: email send failed: $($_.Exception.Message). email=skipped:$($_.Exception.GetType().Name)"
    return
}

