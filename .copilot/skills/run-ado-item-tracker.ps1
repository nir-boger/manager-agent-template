# ado-item-tracker -- track a curated set of ADO work items.
#
# Modes:
#   add     -Id N [-Note "..."]   add a work item to the tracked set (validates against ADO, seeds cache+baseline)
#   remove  -Id N                 stop tracking a work item
#   list                          print the tracked items (live fields) to the console
#   digest                        DAILY (Sun-Thu 09:00) Nir-only HTML table email: link / title / owner / status
#   watch                         HOURLY change watcher: email Nir only when a tracked item changed (idempotent)
#   ping    -Id N                 email the item's owner (on Nir's behalf) asking for a status update
#
# Data layout:
#   reports/ado-tracker/tracked.json   source of truth (committed): [{id, note, addedAt}]
#   reports/ado-tracker/cache.json     board cache (gitignored): last-known live ADO fields per id
#   .copilot/skills/ado-item-tracker/state/last-snapshot.json   diff baseline (gitignored; advanced by WATCH only)
#   .copilot/skills/ado-item-tracker/state/digest-last-sent.txt per-day digest idempotency (gitignored)
#
# ADO access: az account get-access-token + org-level workitemsbatch REST (items may live in any project).
# Scheduled by: DM-AdoTrackerDigest (weekly Sun-Thu 09:00) + DM-AdoTrackerWatch (interval PT1H, 24/7).
#
# Manual:
#   pwsh -NoProfile -File .copilot/skills/run-ado-item-tracker.ps1 -Mode list
#   pwsh -NoProfile -File .copilot/skills/run-ado-item-tracker.ps1 -Mode add -Id 12345 -Note "watch for the SDK fix"
#   pwsh -NoProfile -File .copilot/skills/run-ado-item-tracker.ps1 -Mode digest -DryRun -Force

[CmdletBinding()]
param(
    [ValidateSet('add','remove','list','digest','watch','ping')]
    [string] $Mode = 'list',
    [int]    $Id,
    [string] $Note = '',
    [switch] $DryRun,
    [switch] $Force
)

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$skillDir     = Join-Path $AgentRoot '.copilot\skills\ado-item-tracker'
$stateDir     = Join-Path $skillDir 'state'
$reportDir    = Join-Path $AgentRoot 'reports\ado-tracker'
$trackedFile  = Join-Path $reportDir 'tracked.json'
$cacheFile    = Join-Path $reportDir 'cache.json'
$snapshotFile = Join-Path $stateDir 'last-snapshot.json'
$digestSent   = Join-Path $stateDir 'digest-last-sent.txt'
New-Item -ItemType Directory -Force -Path $stateDir, $reportDir | Out-Null

$logFile = Join-Path $LogDir ("ado-item-tracker-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")
function Write-Log { param([string]$Message)
    $line = "$(Get-Date -Format o) [$Mode] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

. (Join-Path $skillDir 'render.ps1')

$mgrEmail = Get-AgentField -Path 'manager.email' -Default 'you@example.com' -Config $AgentConfig

$org     = 'https://your-ado-org.visualstudio.com'
$project = 'One'

Write-Log "==== start (Id=$Id DryRun=$DryRun Force=$Force) ===="

# --- JSON helpers (atomic write) -----------------------------------------
function Read-JsonFile { param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Write-JsonFile { param([string]$Path, $Object)
    $tmp = "$Path.tmp"
    ($Object | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-TrackedItems {
    $j = Read-JsonFile $trackedFile
    if ($j -and $j.items) { return @($j.items) }
    return @()
}
function Save-TrackedItems { param([object[]]$Items)
    Write-JsonFile -Path $trackedFile -Object ([ordered]@{
        _comment = "Source of truth for the ado-item-tracker skill. Managed via 'track ADO <id>' / -Mode add|remove. Live fields are fetched from ADO; only id+note+addedAt persist here."
        items    = @($Items)
    })
}

# --- ADO ------------------------------------------------------------------
function Get-AdoToken {
    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCmd) { Write-Log 'az CLI not found on PATH.'; return $null }
    $t = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv) 2>$null
    if (-not $t) { Write-Log 'failed to acquire ADO token (run az login).'; return $null }
    return $t
}

function Get-AdoWorkItems {
    # Returns normalized work items for the given ids (org-level batch, omit missing).
    param([int[]]$Ids, [hashtable]$Headers)
    $result = New-Object System.Collections.Generic.List[object]
    if (-not $Ids -or $Ids.Count -eq 0) { return ,$result.ToArray() }
    $fields = @('System.Id','System.Title','System.WorkItemType','System.State',
                'System.AssignedTo','System.ChangedDate','System.ChangedBy','System.TeamProject')
    for ($i = 0; $i -lt $Ids.Count; $i += 200) {
        $batch = @($Ids[$i..([Math]::Min($i + 199, $Ids.Count - 1))])
        $body  = @{ ids = $batch; fields = $fields; errorPolicy = 'omit' } | ConvertTo-Json -Depth 4 -Compress
        $resp  = Invoke-RestMethod -Method POST -Uri "$org/_apis/wit/workitemsbatch?api-version=7.1" -Headers $Headers -Body $body
        foreach ($it in $resp.value) {
            if (-not $it -or -not $it.fields) { continue }
            $f = $it.fields
            $owner = ''; $ownerEmail = ''
            if ($f.'System.AssignedTo') {
                $owner      = [string]$f.'System.AssignedTo'.displayName
                $ownerEmail = [string]$f.'System.AssignedTo'.uniqueName
            }
            $changedBy = ''
            if ($f.'System.ChangedBy') { $changedBy = [string]$f.'System.ChangedBy'.displayName }
            $proj = [string]$f.'System.TeamProject'; if (-not $proj) { $proj = $project }
            $wid  = [int]$f.'System.Id'
            $result.Add([pscustomobject]@{
                Id          = $wid
                Title       = [string]$f.'System.Title'
                Type        = [string]$f.'System.WorkItemType'
                State       = [string]$f.'System.State'
                Owner       = $owner
                OwnerEmail  = $ownerEmail
                Project     = $proj
                Url         = "$org/$([uri]::EscapeDataString($proj))/_workitems/edit/$wid"
                ChangedDate = [string]$f.'System.ChangedDate'
                ChangedBy   = $changedBy
            }) | Out-Null
        }
    }
    return ,$result.ToArray()
}

function Write-Cache {
    # Board-facing cache (reports/ado-tracker/cache.json): live fields keyed by id.
    param([object[]]$Items)
    $map = [ordered]@{}
    foreach ($it in ($Items | Sort-Object Id)) {
        $map["$($it.Id)"] = [ordered]@{
            id = $it.Id; title = $it.Title; type = $it.Type; state = $it.State
            owner = $it.Owner; ownerEmail = $it.OwnerEmail; url = $it.Url
            changedDate = $it.ChangedDate; changedBy = $it.ChangedBy
        }
    }
    Write-JsonFile -Path $cacheFile -Object ([ordered]@{ generatedAt = (Get-Date -Format o); items = $map })
}

function Send-AtEmail {
    # Ensures Outlook is up, then sends via the canonical comms adapter
    # (which appends the Nirvana signature + honors migration-mode).
    param([string]$To, [string]$Subject, [string]$BodyHtml)
    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    $ensureLog = Join-Path $LogDir 'ensure-outlook.log'
    if (-not (Ensure-OutlookRunning -LogFile $ensureLog)) {
        Write-Log 'Outlook not available; not sending.'
        return $false
    }
    $res = Send-NirvanaMessage -Channel email -To $To -Subject $Subject -BodyHtml $BodyHtml
    if ($res.Sent) {
        if ($res.Skipped) { Write-Log "send ok (skipped=$($res.Skipped)) -> $To" } else { Write-Log "sent -> $To" }
        return $true
    }
    Write-Log "send FAILED -> $To : $($res.Error)"
    return $false
}

# Merge tracked notes onto live items, preserving tracked order.
function Join-TrackedWithLive {
    param([object[]]$Tracked, [object[]]$Live)
    $byId = @{}; foreach ($l in $Live) { $byId["$($l.Id)"] = $l }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Tracked) {
        $live = $byId["$($t.id)"]
        if ($live) {
            $out.Add(([pscustomobject]@{
                Id = $live.Id; Title = $live.Title; Type = $live.Type; State = $live.State
                Owner = $live.Owner; OwnerEmail = $live.OwnerEmail; Url = $live.Url
                ChangedDate = $live.ChangedDate; ChangedBy = $live.ChangedBy
                Note = [string]$t.note
            })) | Out-Null
        }
    }
    return ,$out.ToArray()
}

$emDash = [char]0x2014

# =========================================================================
switch ($Mode) {

  'remove' {
    if ($Id -le 0) { Write-Log 'remove requires -Id <n>.'; exit 1 }
    $tracked = Get-TrackedItems
    if (-not ($tracked | Where-Object { [int]$_.id -eq $Id })) {
        Write-Host "Work item #$Id is not in the tracked set."; exit 0
    }
    Save-TrackedItems -Items @($tracked | Where-Object { [int]$_.id -ne $Id })
    foreach ($file in @($cacheFile, $snapshotFile)) {
        $j = Read-JsonFile $file
        if ($j -and $j.items -and $j.items.PSObject.Properties["$Id"]) {
            $j.items.PSObject.Properties.Remove("$Id"); Write-JsonFile -Path $file -Object $j
        }
    }
    Write-Log "Removed #$Id from the tracked set."
    Write-Host "Stopped tracking ADO #$Id."
    exit 0
  }

  default {
    # add / list / digest / watch / ping all need a token.
    $token = Get-AdoToken
    $needToken = $true
    if (-not $token) {
        switch ($Mode) {
            { $_ -in 'digest','watch' } { Write-Log 'No ADO token; degrading gracefully (no send, no stamp).'; exit 0 }
            'list' { Write-Log 'No ADO token; falling back to cache for list.'; $needToken = $false }
            default { Write-Log 'FATAL: no ADO token.'; exit 1 }
        }
    }
    $headers = if ($token) { @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } } else { $null }

    # ---- add ----
    if ($Mode -eq 'add') {
        if ($Id -le 0) { Write-Log 'add requires -Id <n>.'; exit 1 }
        $tracked = @(Get-TrackedItems)
        if ($tracked | Where-Object { [int]$_.id -eq $Id }) {
            Write-Host "ADO #$Id is already tracked."
        } else {
            $live = Get-AdoWorkItems -Ids @($Id) -Headers $headers
            if (-not $live -or $live.Count -eq 0) {
                Write-Log "Work item #$Id not found or not accessible."
                Write-Host "Could not find ADO work item #$Id (check the id / your access)."; exit 1
            }
            $tracked += [pscustomobject]@{ id = $Id; note = $Note; addedAt = (Get-Date -Format o) }
            Save-TrackedItems -Items $tracked
            $wi = $live[0]
            Write-Log "Added #$Id ($($wi.Type) '$($wi.Title)', $($wi.State), owner=$($wi.Owner))."
            Write-Host "Now tracking ADO #$Id $emDash $($wi.Title) [$($wi.State), $($wi.Owner)]"
        }
        # Refresh cache + baseline for the full tracked set so watch won't misfire.
        $all  = @(Get-TrackedItems)
        $live = Get-AdoWorkItems -Ids @($all | ForEach-Object { [int]$_.id }) -Headers $headers
        Write-Cache -Items $live
        $snap = [ordered]@{}; foreach ($it in $live) {
            $snap["$($it.Id)"] = [ordered]@{ state = $it.State; owner = $it.Owner; title = $it.Title; changedDate = $it.ChangedDate }
        }
        Write-JsonFile -Path $snapshotFile -Object ([ordered]@{ capturedAt = (Get-Date -Format o); items = $snap })
        exit 0
    }

    # ---- list ----
    if ($Mode -eq 'list') {
        $tracked = @(Get-TrackedItems)
        if ($tracked.Count -eq 0) { Write-Host 'Not tracking any ADO items yet. Say: track ADO <id>'; exit 0 }
        $rows = $null
        if ($needToken) {
            $live = Get-AdoWorkItems -Ids @($tracked | ForEach-Object { [int]$_.id }) -Headers $headers
            Write-Cache -Items $live
            $rows = Join-TrackedWithLive -Tracked $tracked -Live $live
        } else {
            $cache = Read-JsonFile $cacheFile
            $rows = foreach ($t in $tracked) {
                $c = if ($cache -and $cache.items) { $cache.items."$($t.id)" } else { $null }
                [pscustomobject]@{ Id = [int]$t.id; Title = ($c.title); Owner = ($c.owner); State = ($c.state); Url = ($c.url) }
            }
        }
        $rows | Format-Table @{n='#';e={$_.Id}}, @{n='Title';e={$_.Title}}, @{n='Owner';e={$_.Owner}}, @{n='Status';e={$_.State}} -AutoSize | Out-String | Write-Host
        Write-Host ("Tracking {0} item(s)." -f $tracked.Count)
        exit 0
    }

    # ---- ping ----
    if ($Mode -eq 'ping') {
        if ($Id -le 0) { Write-Log 'ping requires -Id <n>.'; exit 1 }
        $live = Get-AdoWorkItems -Ids @($Id) -Headers $headers
        if (-not $live -or $live.Count -eq 0) { Write-Log "ping: #$Id not found."; Write-Host "Work item #$Id not found."; exit 1 }
        $wi = $live[0]
        if ([string]::IsNullOrWhiteSpace($wi.OwnerEmail)) {
            Write-Log "ping: #$Id is unassigned; nobody to ping."; Write-Host "#$Id is unassigned $emDash no owner to ping."; exit 0
        }
        if ($wi.OwnerEmail -notmatch '(?i)@microsoft\.com$') {
            Write-Log "ping: owner $($wi.OwnerEmail) is not @microsoft.com; refusing to send."
            Write-Host "Owner is external ($($wi.OwnerEmail)); not sending."; exit 0
        }
        $body =
            "<p>Hi $(ConvertTo-AtHtml ($wi.Owner.Split(' ')[0])),</p>" +
            "<p>Nir is keeping an eye on this work item and would appreciate a quick status update when you have a moment:</p>" +
            "<p style='margin:10px 0'><a href='$($wi.Url)' style='color:#1967d2;text-decoration:none;font-weight:600'>#$($wi.Id) $(ConvertTo-AtHtml $wi.Title)</a><br>" +
            "<span style='color:#5f6368;font-size:13px'>$(ConvertTo-AtHtml $wi.Type) &middot; currently $(Get-AtStatusPill -State $wi.State)</span></p>" +
            "<p>Anything blocking it, or an ETA? A one-liner is plenty.</p>" +
            "<p style='color:#555;font-style:italic'>$(Get-AtPingJoke)</p>"
        $subject = "Quick status check on #$($wi.Id): $($wi.Title)"
        if ($DryRun) {
            $prev = Join-Path $stateDir "ping-preview-$Id.html"
            $body | Set-Content -Path $prev -Encoding UTF8
            Write-Log "[DryRun] ping preview -> $prev (would email $($wi.OwnerEmail))."
            Write-Host "[DryRun] would ping $($wi.Owner) <$($wi.OwnerEmail)> about #$Id."
            exit 0
        }
        if (Send-AtEmail -To $wi.OwnerEmail -Subject $subject -BodyHtml $body) {
            Write-Host "Pinged $($wi.Owner) about #$Id."
        }
        exit 0
    }

    # ---- digest (daily Sun-Thu 09:00) ----
    if ($Mode -eq 'digest') {
        $tracked = @(Get-TrackedItems)
        if ($tracked.Count -eq 0) { Write-Log 'Nothing tracked; no digest.'; exit 0 }
        $dayKey = (Get-Date).ToString('yyyy-MM-dd')
        if (-not $Force -and (Test-Path $digestSent) -and ((Get-Content $digestSent -Encoding UTF8) -contains $dayKey)) {
            Write-Log "Digest already sent today ($dayKey). Use -Force to resend."; exit 0
        }
        $live = Get-AdoWorkItems -Ids @($tracked | ForEach-Object { [int]$_.id }) -Headers $headers
        Write-Cache -Items $live
        $rows  = Join-TrackedWithLive -Tracked $tracked -Live $live
        $missing = @($tracked | Where-Object { $id = [int]$_.id; -not ($live | Where-Object { $_.Id -eq $id }) })

        $doneN = @($rows | Where-Object { (Get-AtStateClass $_.State) -eq 'done' }).Count
        $header = "<p style='font-size:15px;margin:0 0 2px'><b>ADO tracker $emDash daily digest</b></p>" +
                  "<p style='color:#777;font-size:12px;margin:0 0 8px'>$(Get-Date -Format 'dddd, MMM d') &middot; $($rows.Count) tracked &middot; $doneN done</p>"
        $table  = Render-AtTable -Items $rows
        $foot   = ''
        if ($missing.Count -gt 0) {
            $foot = "<p style='color:#c5221f;font-size:12px'>Heads up: $($missing.Count) tracked id(s) were not returned by ADO (removed or access lost): " +
                    (($missing | ForEach-Object { "#$($_.id)" }) -join ', ') + "</p>"
        }
        $foot  += "<p style='color:#666;font-size:12px;margin-top:10px'>Manage me by chat: <code>track ADO &lt;id&gt;</code> / <code>untrack ADO &lt;id&gt;</code>, or open the Nirvana Board &rarr; ADO Tracker.</p>"
        $joke   = "<p style='color:#555;font-style:italic;margin-top:12px'>$(Get-AtDigestJoke -Count $rows.Count)</p>"
        $bodyHtml = $header + $table + $foot + $joke
        $subject  = "ADO tracker $emDash $($rows.Count) item$(if($rows.Count -ne 1){'s'}) ($doneN done)"

        if ($DryRun) {
            $prev = Join-Path $stateDir 'digest-preview.html'
            "<html><body style='font-family:Segoe UI,Arial,sans-serif'>$bodyHtml</body></html>" | Set-Content -Path $prev -Encoding UTF8
            Write-Log "[DryRun] digest preview -> $prev (not sending, not stamping)."; exit 0
        }
        if (Send-AtEmail -To $mgrEmail -Subject $subject -BodyHtml $bodyHtml) {
            Add-Content -Path $digestSent -Value $dayKey -Encoding UTF8
            Write-Log "Digest sent + stamped ($dayKey)."
        }
        exit 0
    }

    # ---- watch (hourly change watcher) ----
    if ($Mode -eq 'watch') {
        $tracked = @(Get-TrackedItems)
        if ($tracked.Count -eq 0) { Write-Log 'Nothing tracked; nothing to watch.'; exit 0 }
        $live = Get-AdoWorkItems -Ids @($tracked | ForEach-Object { [int]$_.id }) -Headers $headers
        Write-Cache -Items $live

        $prevSnap = Read-JsonFile $snapshotFile
        $prev = @{}
        if ($prevSnap -and $prevSnap.items) {
            foreach ($p in $prevSnap.items.PSObject.Properties) { $prev[$p.Name] = $p.Value }
        }
        $noteById = @{}; foreach ($t in $tracked) { $noteById["$($t.id)"] = [string]$t.note }

        $changes = New-Object System.Collections.Generic.List[object]
        foreach ($it in $live) {
            $key = "$($it.Id)"; $p = $prev[$key]
            $lines = New-Object System.Collections.Generic.List[string]
            if (-not $p) {
                $lines.Add("Now tracking $(if($noteById[$key]){"($($noteById[$key])) "})$(if($it.Owner){"&middot; owner $($it.Owner)"}) &middot; $($it.State)") | Out-Null
            } else {
                if ([string]$p.state -ne $it.State) { $lines.Add("Status: $($p.state) $emDash> $($it.State)") | Out-Null }
                if ([string]$p.owner -ne $it.Owner) {
                    $from = if ($p.owner) { $p.owner } else { 'Unassigned' }
                    $to   = if ($it.Owner) { $it.Owner } else { 'Unassigned' }
                    $lines.Add("Owner: $from $emDash> $to") | Out-Null
                }
                if ([string]$p.title -ne $it.Title) { $lines.Add("Title changed to: $($it.Title)") | Out-Null }
                if ($lines.Count -eq 0 -and ([string]$p.changedDate) -ne $it.ChangedDate -and $it.ChangedDate) {
                    $by = if ($it.ChangedBy) { " by $($it.ChangedBy)" } else { '' }
                    $lines.Add("Edited$by ($(Format-AtRelative $it.ChangedDate))") | Out-Null
                }
            }
            if ($lines.Count -gt 0) {
                $changes.Add([pscustomobject]@{ Id = $it.Id; Title = $it.Title; Url = $it.Url; Lines = @($lines) }) | Out-Null
            }
        }

        if ($changes.Count -eq 0) { Write-Log 'No updates since last watch.'; exit 0 }
        Write-Log "Detected $($changes.Count) updated item(s)."

        $header = "<p style='font-size:15px;margin:0 0 2px'><b>ADO tracker $emDash update$(if($changes.Count -ne 1){'s'})</b></p>" +
                  "<p style='color:#777;font-size:12px;margin:0 0 8px'>$($changes.Count) of your $($live.Count) tracked item(s) changed</p>"
        $panel = Render-AtUpdatePanel -Changes @($changes)
        $joke  = "<p style='color:#555;font-style:italic;margin-top:12px'>$(Get-AtWatchJoke -Count $changes.Count)</p>"
        $bodyHtml = $header + $panel + $joke
        $subject  = "ADO tracker $emDash $($changes.Count) update$(if($changes.Count -ne 1){'s'})"

        if ($DryRun) {
            $prev2 = Join-Path $stateDir 'watch-preview.html'
            "<html><body style='font-family:Segoe UI,Arial,sans-serif'>$bodyHtml</body></html>" | Set-Content -Path $prev2 -Encoding UTF8
            Write-Log "[DryRun] watch preview -> $prev2 (not sending, not advancing baseline)."; exit 0
        }
        if (Send-AtEmail -To $mgrEmail -Subject $subject -BodyHtml $bodyHtml) {
            $snap = [ordered]@{}; foreach ($it in $live) {
                $snap["$($it.Id)"] = [ordered]@{ state = $it.State; owner = $it.Owner; title = $it.Title; changedDate = $it.ChangedDate }
            }
            Write-JsonFile -Path $snapshotFile -Object ([ordered]@{ capturedAt = (Get-Date -Format o); items = $snap })
            Write-Log 'Update sent + baseline advanced.'
        }
        exit 0
    }
  }
}

