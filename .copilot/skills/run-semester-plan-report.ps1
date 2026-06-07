param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$PreviewOnly
)

$ErrorActionPreference = "Stop"

$ROOT      = "<repo>"
$SKILL_DIR = Join-Path $ROOT ".copilot\skills\semester-plan-report"
$STATE_DIR = Join-Path $SKILL_DIR "state"
$LOG_DIR   = Join-Path $ROOT "reports\logs"
$LOCK_PATH = Join-Path $LOG_DIR "semester-plan-report.lock"

New-Item -ItemType Directory -Force -Path $STATE_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $LOG_DIR   | Out-Null

$ts       = Get-Date -Format "yyyy-MM-dd_HHmm"
$LOG_FILE = Join-Path $LOG_DIR "semester-plan-report-$ts.log"

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
    Write-Output $line
}

# ---- single-instance lock ----
if (Test-Path $LOCK_PATH) {
    $pidInLock = (Get-Content $LOCK_PATH -Raw -ErrorAction SilentlyContinue).Trim()
    $alive = $false
    if ($pidInLock -match '^\d+$') {
        if (Get-Process -Id ([int]$pidInLock) -ErrorAction SilentlyContinue) { $alive = $true }
    }
    if ($alive) {
        Log "Another instance is running (PID $pidInLock). Exiting."
        exit 0
    }
    Remove-Item $LOCK_PATH -Force -ErrorAction SilentlyContinue
}
$PID | Set-Content -Path $LOCK_PATH -Encoding ASCII

try {
    Log "==== semester-plan-report run start (DryRun=$DryRun Force=$Force PreviewOnly=$PreviewOnly) ===="

    # ---- ADO token ----
    $token = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv) 2>$null
    if (-not $token) { throw "Failed to acquire ADO token via az CLI. Run 'az login' first." }
    $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

    $org     = "https://your-ado-org.visualstudio.com"
    $project = "One"
    $team    = "Your Team"
    $teamEnc = [uri]::EscapeDataString($team)

    # ---- sprint-end self-gate ----
    $today = (Get-Date).Date
    $sprintFinishDate = $null
    $sprintName = $null
    try {
        $iterUrl = "$org/$project/$teamEnc/_apis/work/teamsettings/iterations?`$timeframe=current&api-version=7.1"
        $iterResp = Invoke-RestMethod -Method GET -Uri $iterUrl -Headers $headers
        if ($iterResp.value -and $iterResp.value.Count -gt 0) {
            $cur = $iterResp.value[0]
            $sprintName = $cur.name
            if ($cur.attributes.finishDate) {
                $sprintFinishDate = ([datetime]$cur.attributes.finishDate).ToLocalTime().Date
            }
            Log "Current iteration: $sprintName  finishDate(local)=$sprintFinishDate"
        }
    } catch {
        Log "WARN: iteration lookup failed: $($_.Exception.Message)"
    }

    if (-not $Force) {
        if ($today.DayOfWeek -ne 'Thursday') {
            Log "Skipped: today is $($today.DayOfWeek), not Thursday. Use -Force to override."
            exit 0
        }
        if ($sprintFinishDate) {
            $delta = ($sprintFinishDate - $today).Days
            if ($delta -gt 3 -or $delta -lt 0) {
                Log "Skipped: today is $delta days from sprint $sprintName finishDate ($sprintFinishDate); only firing within 3 days before sprint end."
                exit 0
            }
        } else {
            Log "WARN: no finishDate known, proceeding on Thursday cadence alone."
        }
    } else {
        Log "Force flag set, skipping sprint-end gate."
    }

    # ---- load Feature IDs ----
    $featIdsPath = Join-Path $SKILL_DIR "feature-ids.json"
    if (-not (Test-Path $featIdsPath)) { throw "Missing $featIdsPath" }
    $featRaw = Get-Content $featIdsPath -Raw -Encoding UTF8
    $features = $featRaw | ConvertFrom-Json
    $featureIds = @($features | ForEach-Object { [int]$_.id })
    Log "Loaded $($featureIds.Count) Feature IDs from feature-ids.json"

    # ---- WIQL recursive descendant tree ----
    $idsCsv = ($featureIds -join ", ")
    $wiqlBody = @{ query = "SELECT [System.Id] FROM WorkItemLinks WHERE Source.[System.Id] IN ($idsCsv) AND [System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward' MODE (Recursive)" } | ConvertTo-Json -Compress
    $wiqlUrl  = "$org/$project/_apis/wit/wiql?api-version=7.1"
    $wiqlResp = Invoke-RestMethod -Method POST -Uri $wiqlUrl -Headers $headers -Body $wiqlBody
    if (-not $wiqlResp.workItemRelations) { throw "WIQL returned no workItemRelations" }
    Log "WIQL returned $($wiqlResp.workItemRelations.Count) relations"

    $allIds = New-Object 'System.Collections.Generic.HashSet[int]'
    $parents = @{}
    foreach ($rel in $wiqlResp.workItemRelations) {
        $tgt = $null
        if ($rel.target -and $rel.target.id) { $tgt = [int]$rel.target.id; [void]$allIds.Add($tgt) }
        if ($rel.source -and $rel.source.id) {
            $src = [int]$rel.source.id
            [void]$allIds.Add($src)
            if ($tgt) {
                if (-not $parents.ContainsKey($src)) { $parents[$src] = New-Object 'System.Collections.Generic.List[int]' }
                $parents[$src].Add($tgt) | Out-Null
            }
        }
    }
    foreach ($fid in $featureIds) { [void]$allIds.Add($fid) }
    Log "Total work item IDs in tree: $($allIds.Count)"

    $parentsObj = @{}
    foreach ($k in $parents.Keys) { $parentsObj["$k"] = @($parents[$k]) }
    $linkTree = @{ parents = $parentsObj; ids = @($allIds) }
    $linkTreePath = Join-Path $STATE_DIR "link-tree.json"
    ($linkTree | ConvertTo-Json -Depth 6 -Compress) | Set-Content -Path $linkTreePath -Encoding UTF8
    Log "Wrote $linkTreePath"

    # ---- batch fetch items ----
    $fieldList = @(
        "System.Id","System.Title","System.WorkItemType","System.State",
        "System.AssignedTo","System.AreaPath","System.IterationPath",
        "System.Tags","System.Parent","Microsoft.VSTS.Common.Priority"
    )
    $idsArr = @($allIds)
    $batches = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $idsArr.Count; $i += 200) {
        $batches.Add(@($idsArr[$i..([Math]::Min($i+199, $idsArr.Count - 1))])) | Out-Null
    }
    Log "Batching fetch in $($batches.Count) call(s)"

    $allItems = New-Object System.Collections.Generic.List[object]
    foreach ($batch in $batches) {
        $body = @{ ids = $batch; fields = $fieldList } | ConvertTo-Json -Depth 4 -Compress
        $url  = "$org/$project/_apis/wit/workitemsbatch?api-version=7.1"
        $resp = Invoke-RestMethod -Method POST -Uri $url -Headers $headers -Body $body
        foreach ($it in $resp.value) { $allItems.Add($it) | Out-Null }
    }
    Log "Fetched $($allItems.Count) work items"

    $allItemsPath = Join-Path $STATE_DIR "all-items.json"
    ($allItems | ConvertTo-Json -Depth 8 -Compress) | Set-Content -Path $allItemsPath -Encoding UTF8
    Log "Wrote $allItemsPath"

    # ---- render dashboard ----
    $buildPy = Join-Path $SKILL_DIR "build.py"
    $pyOut = & python $buildPy 2>&1
    foreach ($l in $pyOut) { Log "py: $l" }
    $dashboard = Join-Path $STATE_DIR "dashboard.html"
    if (-not (Test-Path $dashboard)) { throw "build.py did not produce $dashboard" }

    # parse the python summary line to extract pulse stats
    $summary = ($pyOut | Where-Object { "$_" -match "features:" } | Select-Object -First 1) -as [string]
    $pbisDone = 0; $pbisTotal = 0; $pctDone = 0; $pctTime = 0; $verdict = "On track"
    if ($summary -match "pbis-done:\s*(\d+)/(\d+)\s*\(([\d\.]+)%\)") {
        $pbisDone = [int]$Matches[1]; $pbisTotal = [int]$Matches[2]; $pctDone = [double]$Matches[3]
    }
    if ($summary -match "time-elapsed:\s*([\d\.]+)%") { $pctTime = [double]$Matches[1] }
    if ($summary -match "verdict:\s*(.+)$") { $verdict = $Matches[1].Trim() }

    # semester math (mirrors build.py)
    $semStart = Get-Date -Year 2026 -Month 4 -Day 1 -Hour 0 -Minute 0 -Second 0
    $semEnd   = Get-Date -Year 2026 -Month 9 -Day 30 -Hour 0 -Minute 0 -Second 0
    $totalDays   = ($semEnd - $semStart).Days + 1
    $elapsedDays = [Math]::Min([Math]::Max(($today - $semStart.Date).Days + 1, 0), $totalDays)
    $remainingDays = $totalDays - $elapsedDays
    $totalSprints  = [Math]::Ceiling($totalDays / 14.0)
    $sprintIdx     = [Math]::Ceiling($elapsedDays / 14.0)
    Log "Pulse: day $elapsedDays of $totalDays, sprint $sprintIdx of $totalSprints, PBIs $pbisDone/$pbisTotal ($pctDone%), time $pctTime%, verdict $verdict"

    # ---- email ----
    if ($DryRun) {
        Log "DryRun: skipping send. Dashboard at $dashboard"
        exit 0
    }

    # idempotency stamp: skip external send if already sent today
    $stampPath = Join-Path $STATE_DIR "last-sent.json"
    if (-not $PreviewOnly -and -not $Force -and (Test-Path $stampPath)) {
        try {
            $stamp = Get-Content $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($stamp.date -eq $today.ToString("yyyy-MM-dd") -and $stamp.mode -eq "external") {
                Log "Skipped: external send already recorded for $($stamp.date) at $($stamp.sentAt). Use -Force to resend."
                exit 0
            }
        } catch {
            Log "WARN: failed to parse stamp file: $($_.Exception.Message)"
        }
    }

    . (Join-Path $ROOT ".copilot\skills\_shared\signature.ps1")
    $sig = Get-NirvanaSignature

    $verdictLower = $verdict.ToLower()
    if ($PreviewOnly) {
        $toLine = "you@example.com"
        $ccLine = ""
        $subj = "[Nirvana] Semester dashboard - preview (Sprint $sprintIdx of $totalSprints, $verdictLower)"
    } else {
        $toLine = "someone@example.com; someone@example.com; someone@example.com"
        $ccLine = "you@example.com; team@example.com"
        $subj = "DM Semester Plan - bi-weekly progress (Sprint $sprintIdx of $totalSprints, $verdictLower)"
    }

    $jokePool = @(
        "$pbisDone of $pbisTotal PBIs landed against $([Math]::Round($pctTime))% of the calendar gone - holding the <em>Plateau</em>, for now.",
        "$([Math]::Round($pctDone))% done, $([Math]::Round($pctTime))% gone - <em>in bloom</em>, mostly.",
        "Sprint $sprintIdx of $totalSprints in flight; $([Math]::Round($pctDone))% of PBIs done. <em>Stay away</em> from the backlog edge.",
        "$([Math]::Round($pctDone))% of PBIs through the door. <em>All apologies</em> to the ones still stuck in <em>New</em>.",
        "Calendar at $([Math]::Round($pctTime))%, work at $([Math]::Round($pctDone))% - <em>drain you</em>, sprint after sprint.",
        "$pbisDone PBIs done, $($pbisTotal - $pbisDone) to go - <em>territorial pissings</em> against the backlog, one PBI at a time."
    )
    $joke = Get-Random -InputObject $jokePool

    $bodyHtml = @"
<p>Hi VP, A Peer, Your Manager,</p>

<p>Bi-weekly DM semester-plan progress dashboard - attached as a single self-contained HTML file (opens in any browser, light/dark toggle in the top-right).</p>

<p><strong>Semester Pulse</strong></p>
<ul>
  <li>Window: Apr 1 - Sep 30, 2026 ($totalDays days, $totalSprints sprints)</li>
  <li>Day <strong>$elapsedDays of $totalDays</strong> - $([Math]::Round($pctTime))% of calendar burned, $remainingDays days remaining</li>
  <li>Sprint <strong>$sprintIdx of $totalSprints</strong> in flight</li>
  <li>PBI completion: <strong>$pbisDone of $pbisTotal done = $([Math]::Round($pctDone))%</strong></li>
  <li>Verdict: <strong>$verdict</strong></li>
</ul>

<p><strong>What is in the dashboard</strong></p>
<ul>
  <li>Pulse intro: time-elapsed vs PBIs-done bars with verdict pill.</li>
  <li>Feature + PBI level (no Task-level noise). Grouped by area, with sprint pins per Feature.</li>
  <li>Filters and search in the toolbar.</li>
  <li>Transparency: Features marked &#9888; have no PBI breakdown yet; Features marked &#9675; are still <em>New</em> in ADO.</li>
</ul>

<p>$joke</p>

<p>(Drafted by Nirvana on Nir's behalf.)</p>

$sig
"@

    $ol = New-Object -ComObject Outlook.Application
    $mail = $ol.CreateItem(0)
    $mail.To = $toLine
    if ($ccLine) { $mail.CC = $ccLine }
    $mail.Subject = $subj
    $mail.HTMLBody = $bodyHtml
    $null = $mail.Attachments.Add($dashboard)
    $mail.Send()

    Log "Sent: To=$toLine  CC=$ccLine  Subject=$subj"

    # write idempotency stamp
    $mode = if ($PreviewOnly) { "preview" } else { "external" }
    $stamp = @{
        date    = $today.ToString("yyyy-MM-dd")
        sentAt  = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
        mode    = $mode
        sprint  = "$sprintIdx of $totalSprints"
        verdict = $verdict
        pbis    = "$pbisDone of $pbisTotal"
    }
    ($stamp | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $STATE_DIR "last-sent.json") -Encoding UTF8

    Log "==== done ===="
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    Log $_.ScriptStackTrace
    throw
}
finally {
    Remove-Item $LOCK_PATH -ErrorAction SilentlyContinue
}

