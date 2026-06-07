# Runs the connect-buddy skill capture mode non-interactively.
#
# Manual / on-demand only - connects are biannual, not poll-friendly.
#
# Pipeline:
#   1. Outlook running check (abort cleanly otherwise).
#   2. PID-aware single-instance lock.
#   3. Build alias roster from team-personas/people/*.md (kebab-case -> title-case
#      display name).
#   4. Load (or initialize) C:\Users\youralias\.copilot\connect-buddy\manifest.json.
#   5. Iterate Inbox: only mails from someone@example.com with subject
#      ^Connect for <Name>$.
#   6. Per mail: strict alias resolution, parse title/period/status, content
#      hash, manifest dedupe.
#   7. New entry: write tmp -> rename -> verify -> manifest -> soft-delete source.
#   8. Append per-item line to reports/connect-buddy/<date>.md (counts/metadata
#      only - no body content).
#   9. Send Nir a counts-only summary email.
#
# All paths are absolute; the script does not chdir.
# Privacy: connect content NEVER leaves
# C:\Users\youralias\.copilot\connect-buddy\connects\<alias>\.

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

# ---- Paths ----
$skillsRoot   = Join-Path $AgentRoot '.copilot\skills'
$personaDir   = Resolve-AgentPath (Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $AgentConfig) -Config $AgentConfig
$dataRoot     = Resolve-AgentPath (Get-AgentField -Path 'paths.connect_buddy_root'  -Default '%USERPROFILE%/.copilot/connect-buddy' -Config $AgentConfig) -Config $AgentConfig
$connectsRoot = Join-Path $dataRoot 'connects'
$manifestPath = Join-Path $dataRoot 'manifest.json'
$reportsRoot  = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root'        -Default 'reports'                              -Config $AgentConfig) -Config $AgentConfig
$activityDir  = Join-Path $reportsRoot 'connect-buddy'

New-Item -ItemType Directory -Force -Path $dataRoot     | Out-Null
New-Item -ItemType Directory -Force -Path $connectsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $activityDir  | Out-Null

$today        = Get-Date -Format 'yyyy-MM-dd'
$activityPath = Join-Path $activityDir "$today.md"
$logPath      = Join-Path $logDir "connect-buddy-$today.log"

function Write-Log { param([string]$msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $msg" | Add-Content -Path $logPath -Encoding UTF8
    Write-Host "$ts  $msg"
}

# ---- Single-instance lock ----
$lockPath = Join-Path $logDir 'connect-buddy.lock'
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
        Write-Log "Another connect-buddy run is in progress (PID $lockPid, age $([int]$lockAge.TotalMinutes)m). Exiting."
        exit 0
    }
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {
    . (Join-Path $PSScriptRoot '_shared\ensure-outlook.ps1')
    if (-not (Ensure-OutlookRunning -LogFile (Join-Path $logDir 'ensure-outlook.log'))) {
        Write-Log 'Outlook unavailable after ensure-outlook preflight. Aborting.'
        exit 0
    }

    Write-Log 'Starting connect-buddy capture run.'

    # ---- Build alias roster from persona files ----
    function Convert-AliasToDisplayName {
        param([string]$alias)
        ($alias -split '-' | ForEach-Object {
            if ($_.Length -eq 0) { '' }
            else { $_.Substring(0,1).ToUpper() + $_.Substring(1) }
        }) -join ' '
    }

    $roster = @{}  # display-name (lowercased, ws-collapsed) -> alias
    foreach ($f in Get-ChildItem $personaDir -Filter '*.md') {
        $alias       = $f.BaseName
        $displayName = Convert-AliasToDisplayName $alias
        $key         = ($displayName -replace '\s+', ' ').Trim().ToLower()
        if ($roster.ContainsKey($key)) {
            Write-Log "WARN: duplicate roster key '$key' (alias '$alias' collides with '$($roster[$key])')."
            continue
        }
        $roster[$key] = $alias
    }
    # Self-connect: also accept Nir's own connect mails. Stored under alias 'nir-boger'
    # alongside the directs. Nir is intentionally NOT in team-personas/people/ (would
    # skew sprint/persona skills), so we register him here, scoped to this skill only.
    $selfAlias       = 'nir-boger'
    $selfDisplayName = 'Your Name'
    $selfKey         = ($selfDisplayName -replace '\s+', ' ').Trim().ToLower()
    if (-not $roster.ContainsKey($selfKey)) {
        $roster[$selfKey] = $selfAlias
    }
    Write-Log "Roster built: $($roster.Count) entries (directs + self)."

    # ---- Load manifest ----
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $manifest.entries) { $manifest | Add-Member -NotePropertyName entries -NotePropertyValue @() -Force }
        } catch {
            Write-Log "WARN: failed to parse manifest ($($_.Exception.Message)). Starting fresh."
            $manifest = [pscustomobject]@{ version = 1; entries = @() }
        }
    } else {
        $manifest = [pscustomobject]@{ version = 1; entries = @() }
    }

    $entryIdsSeen = @{}
    $hashesSeen   = @{}
    foreach ($e in $manifest.entries) {
        if ($e.entry_id)        { $entryIdsSeen[$e.entry_id] = $e }
        if ($e.content_sha256)  { $hashesSeen[$e.content_sha256] = $e }
    }

    # ---- Helpers ----
    function Resolve-SenderSmtp {
        param($mail)
        $smtp = $null
        try {
            if ($mail.Sender) {
                $exUser = $mail.Sender.GetExchangeUser()
                if ($exUser) { $smtp = $exUser.PrimarySmtpAddress }
            }
        } catch {}
        if (-not $smtp) {
            try {
                $pa = $mail.PropertyAccessor
                $smtp = $pa.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x39FE001E')
            } catch {}
        }
        if (-not $smtp) {
            $sea = $mail.SenderEmailAddress
            if ($sea -and $sea -like '*@*') { $smtp = $sea }
        }
        return $smtp
    }

    function Normalize-Body {
        param([string]$body)
        if (-not $body) { return '' }
        # Decode common HTML entities (Outlook plaintext is usually clean already).
        $body = $body -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
        # Normalize line endings.
        $body = $body -replace "`r`n", "`n" -replace "`r", "`n"
        $lines = $body -split "`n"
        $cleaned = New-Object System.Collections.Generic.List[string]
        foreach ($ln in $lines) {
            $t = $ln.TrimEnd()
            if ($t -match '^_{20,}\s*$') { $t = '---' }
            elseif ($t -match '^\*[\s\t]+(.+)$') { $t = '- ' + $matches[1] }
            $cleaned.Add($t)
        }
        $out = $cleaned -join "`n"
        # Collapse 3+ blank lines to 2.
        while ($out -match "\n\n\n\n") { $out = $out -replace "\n\n\n\n", "`n`n`n" }
        $out = $out -replace "\n{3,}", "`n`n"
        return $out.Trim()
    }

    function Parse-ConnectMeta {
        param([string]$body)
        $meta = [ordered]@{
            connect_title             = $null
            reflection_period_start   = $null
            reflection_period_end     = $null
            status                    = $null
        }
        # Get first ~30 non-empty lines (Outlook puts meta at top).
        $lines = ($body -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $top = if ($lines.Count -gt 30) { $lines[0..29] } else { $lines }
        foreach ($ln in $top) {
            if (-not $meta.connect_title -and $ln -match '^(Connect\s+(?:\d{4}|[A-Za-z]{3,9}\s+\d{4}))\s*$') {
                $meta.connect_title = $matches[1]
                continue
            }
            if (-not $meta.reflection_period_start -and $ln -match '^Reflection\s+Period:\s*(.+?)\s*[-\u2013]\s*(.+?)\s*$') {
                $startStr = $matches[1].Trim()
                $endStr   = $matches[2].Trim()
                try {
                    $startD = [datetime]::Parse($startStr, [System.Globalization.CultureInfo]::InvariantCulture)
                    $endD   = [datetime]::Parse($endStr,   [System.Globalization.CultureInfo]::InvariantCulture)
                    $meta.reflection_period_start = $startD.ToString('yyyy-MM-dd')
                    $meta.reflection_period_end   = $endD.ToString('yyyy-MM-dd')
                } catch {
                    # Leave as null - fall back to title for filename.
                }
                continue
            }
            if (-not $meta.status -and $ln -match '^Connect\s+Status:\s*(.+)$') {
                $meta.status = $matches[1].Trim()
                continue
            }
        }
        return [pscustomobject]$meta
    }

    function Get-ConnectFilenameStem {
        param($meta)
        if ($meta.reflection_period_end) { return $meta.reflection_period_end }
        if ($meta.connect_title) {
            $t = $meta.connect_title -replace '\s+', '-'
            return $t.ToLower()  # e.g. "connect-2026" or "connect-nov-2025"
        }
        return $null
    }

    function Get-ContentHash {
        param([string]$text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $hash = $sha.ComputeHash($bytes)
        $sha.Dispose()
        return ([System.BitConverter]::ToString($hash) -replace '-','').ToLower()
    }

    function Write-FileAtomic {
        param([string]$path, [string]$content)
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $tmp = $path + '.tmp'
        # UTF-8 with BOM helps Hebrew render correctly in Notepad / git GUIs.
        [System.IO.File]::WriteAllText($tmp, $content, [System.Text.UTF8Encoding]::new($true))
        if (Test-Path $path) { Remove-Item $path -Force }
        Move-Item -Force -Path $tmp -Destination $path
    }

    function Save-Manifest {
        param($manifestObj)
        $tmp = $manifestPath + '.tmp'
        $json = $manifestObj | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($true))
        if (Test-Path $manifestPath) { Remove-Item $manifestPath -Force }
        Move-Item -Force -Path $tmp -Destination $manifestPath
    }

    # ---- Iterate Inbox ----
    $ol = New-Object -ComObject Outlook.Application
    $ns = $ol.GetNamespace('MAPI')
    $inbox = $ns.GetDefaultFolder(6)  # olFolderInbox

    $captured     = New-Object System.Collections.ArrayList
    $deduped      = New-Object System.Collections.ArrayList
    $quarantined  = New-Object System.Collections.ArrayList
    $deletedCount = 0
    $perAlias     = @{}

    # Snapshot mail items first (we'll delete during iteration; can't iterate live collection while mutating it).
    $mailsToProcess = New-Object System.Collections.ArrayList
    foreach ($m in $inbox.Items) {
        if ($m.Class -ne 43) { continue }  # 43 = olMail
        if ($m.Subject -notmatch '(?i)^Connect for\s+(.+)$') { continue }
        $smtp = Resolve-SenderSmtp -mail $m
        if (-not $smtp -or $smtp.ToLower() -ne 'someone@example.com') { continue }
        [void]$mailsToProcess.Add($m)
    }
    Write-Log "Found $($mailsToProcess.Count) candidate Connect mails in Inbox."

    foreach ($m in $mailsToProcess) {
        $subject = $m.Subject
        $entryId = $m.EntryID
        $received = $m.ReceivedTime

        try {
            # Already processed by EntryID?
            if ($entryIdsSeen.ContainsKey($entryId)) {
                Write-Log "  SKIP (entry-id dupe): $subject  [$entryId]"
                [void]$deduped.Add([pscustomobject]@{ subject = $subject; reason = 'entry-id dupe' })
                # Don't auto-delete an already-known message - it was already deleted on the prior run.
                continue
            }

            # Strict alias resolution.
            $null = $subject -match '(?i)^Connect for\s+(.+)$'
            $rawName = $matches[1].Trim()
            $key = ($rawName -replace '\s+', ' ').ToLower()
            if (-not $roster.ContainsKey($key)) {
                Write-Log "  QUARANTINE (no roster match): $subject  ('$rawName' not in $($roster.Count) directs)"
                [void]$quarantined.Add([pscustomobject]@{ subject = $subject; reason = "no roster match for '$rawName'"; rawName = $rawName })
                continue
            }
            $alias = $roster[$key]

            # Parse meta.
            $body = $m.Body
            $cleaned = Normalize-Body -body $body
            $meta = Parse-ConnectMeta -body $cleaned

            if (-not $meta.connect_title -or -not $meta.status) {
                Write-Log "  QUARANTINE (parse fail title/status): $subject"
                [void]$quarantined.Add([pscustomobject]@{ subject = $subject; reason = 'parse fail (title or status missing)'; alias = $alias; meta = $meta })
                continue
            }

            $stem = Get-ConnectFilenameStem -meta $meta
            if (-not $stem) {
                Write-Log "  QUARANTINE (no filename stem): $subject"
                [void]$quarantined.Add([pscustomobject]@{ subject = $subject; reason = 'no filename stem'; alias = $alias; meta = $meta })
                continue
            }

            $contentHash = Get-ContentHash -text $cleaned

            # Already have this exact content?
            if ($hashesSeen.ContainsKey($contentHash)) {
                Write-Log "  DEDUPE (content hash known): $subject (alias=$alias hash=$($contentHash.Substring(0,8)))"
                [void]$deduped.Add([pscustomobject]@{ subject = $subject; reason = 'content-hash dupe'; alias = $alias; entry_id = $entryId })
                # The content already lives locally - safe to delete this redundant inbox copy.
                try {
                    [void]$m.Delete()
                    $deletedCount++
                    Write-Log "    soft-deleted redundant copy."
                } catch {
                    Write-Log "    WARN: delete of redundant copy failed: $($_.Exception.Message)"
                }
                continue
            }

            # Decide filename - if same (alias, stem) already exists locally, append -r2, -r3...
            $aliasDir = Join-Path $connectsRoot $alias
            New-Item -ItemType Directory -Force -Path $aliasDir | Out-Null
            $candidate = Join-Path $aliasDir "$stem.md"
            $rev = 1
            while (Test-Path $candidate) {
                $rev++
                $candidate = Join-Path $aliasDir "$stem-r$rev.md"
            }
            $rawCandidate = [System.IO.Path]::ChangeExtension($candidate, '.txt')
            $relFile = $candidate.Substring($connectsRoot.Length).TrimStart('\','/')

            $captureTs = (Get-Date).ToString('o')

            # Build markdown.
            $titleLine = if ($meta.reflection_period_start -and $meta.reflection_period_end) {
                "> **Reflection period:** $($meta.reflection_period_start) - $($meta.reflection_period_end)"
            } else { '' }

            $frontMatter = @(
                '---',
                "person: $(Convert-AliasToDisplayName $alias)",
                "alias: $alias",
                "connect_title: $($meta.connect_title)",
                "reflection_period_start: $($meta.reflection_period_start)",
                "reflection_period_end: $($meta.reflection_period_end)",
                "status: $($meta.status)",
                "captured_at: $captureTs",
                "source_subject: $subject",
                "source_received: $($received.ToString('o'))",
                "source_entry_id: $entryId",
                "content_sha256: $contentHash",
                '---',
                ''
            )
            $bodyHeader = @(
                "# $($meta.connect_title) - $(Convert-AliasToDisplayName $alias)",
                ''
            )
            if ($titleLine) { $bodyHeader += $titleLine }
            $bodyHeader += "> **Status:** $($meta.status)"
            $bodyHeader += "> **Captured:** $today"
            $bodyHeader += ''
            $bodyHeader += '---'
            $bodyHeader += ''
            $mdText = ($frontMatter + $bodyHeader) -join "`n"
            $mdText += $cleaned + "`n"

            # Atomic write of both files.
            Write-FileAtomic -path $candidate    -content $mdText
            Write-FileAtomic -path $rawCandidate -content $body

            # Verify both files exist and are non-empty.
            $mdInfo  = Get-Item $candidate
            $rawInfo = Get-Item $rawCandidate
            if ($mdInfo.Length -lt 200 -or $rawInfo.Length -lt 100) {
                throw "Saved files look truncated (md=$($mdInfo.Length) bytes, raw=$($rawInfo.Length) bytes). Aborting save."
            }

            # Append manifest entry; persist; THEN delete source.
            $entry = [pscustomobject]@{
                entry_id                 = $entryId
                content_sha256           = $contentHash
                alias                    = $alias
                connect_title            = $meta.connect_title
                reflection_period_start  = $meta.reflection_period_start
                reflection_period_end    = $meta.reflection_period_end
                status                   = $meta.status
                file                     = ($relFile -replace '\\', '/')
                captured_at              = $captureTs
                source_received          = $received.ToString('o')
            }
            $manifest.entries = @($manifest.entries) + $entry
            $entryIdsSeen[$entryId] = $entry
            $hashesSeen[$contentHash] = $entry
            Save-Manifest -manifestObj $manifest

            # Soft-delete the source mail.
            try {
                [void]$m.Delete()
                $deletedCount++
                Write-Log "  CAPTURED: $alias  $($meta.connect_title) ($($meta.status))  -> $relFile  [deleted source]"
            } catch {
                Write-Log "  CAPTURED: $alias  $($meta.connect_title) ($($meta.status))  -> $relFile  [WARN delete failed: $($_.Exception.Message)]"
            }

            [void]$captured.Add([pscustomobject]@{
                alias        = $alias
                title        = $meta.connect_title
                status       = $meta.status
                period_start = $meta.reflection_period_start
                period_end   = $meta.reflection_period_end
                file         = $relFile
            })
            if (-not $perAlias.ContainsKey($alias)) { $perAlias[$alias] = 0 }
            $perAlias[$alias]++
        }
        catch {
            Write-Log "  ERROR processing '$subject': $($_.Exception.Message)"
            [void]$quarantined.Add([pscustomobject]@{ subject = $subject; reason = "exception: $($_.Exception.Message)" })
        }
    }

    # ---- Activity log (counts/metadata only, NEVER content) ----
    $logLines = New-Object System.Collections.ArrayList
    [void]$logLines.Add("# connect-buddy activity - $today")
    [void]$logLines.Add('')
    [void]$logLines.Add("**Run at:** $(Get-Date -Format 'HH:mm:ss')")
    [void]$logLines.Add("**Captured:** $($captured.Count)  |  **Deduped:** $($deduped.Count)  |  **Quarantined:** $($quarantined.Count)  |  **Source mails deleted:** $deletedCount")
    [void]$logLines.Add('')
    if ($captured.Count -gt 0) {
        [void]$logLines.Add('## Captured')
        [void]$logLines.Add('')
        [void]$logLines.Add('| Alias | Title | Period start | Period end | Status |')
        [void]$logLines.Add('|---|---|---|---|---|')
        foreach ($c in $captured) {
            [void]$logLines.Add("| $($c.alias) | $($c.title) | $($c.period_start) | $($c.period_end) | $($c.status) |")
        }
        [void]$logLines.Add('')
    }
    if ($deduped.Count -gt 0) {
        [void]$logLines.Add('## Deduped (already had this exact content)')
        [void]$logLines.Add('')
        foreach ($d in $deduped) {
            [void]$logLines.Add("- $($d.subject) ($($d.reason))")
        }
        [void]$logLines.Add('')
    }
    if ($quarantined.Count -gt 0) {
        [void]$logLines.Add('## Quarantined (NOT saved, NOT deleted - manual review needed)')
        [void]$logLines.Add('')
        foreach ($q in $quarantined) {
            [void]$logLines.Add("- $($q.subject) ($($q.reason))")
        }
        [void]$logLines.Add('')
    }
    Add-Content -Path $activityPath -Value (($logLines -join "`r`n") + "`r`n") -Encoding UTF8

    # ---- Summary email to Nir (counts only - NEVER body content) ----
    $bodyHtml = New-Object System.Text.StringBuilder
    [void]$bodyHtml.Append("<p>connect-buddy capture run finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm').</p>")
    [void]$bodyHtml.Append("<p><b>Captured:</b> $($captured.Count) &nbsp; <b>Deduped:</b> $($deduped.Count) &nbsp; <b>Quarantined:</b> $($quarantined.Count) &nbsp; <b>Source mails deleted:</b> $deletedCount</p>")

    if ($captured.Count -gt 0) {
        [void]$bodyHtml.Append('<h3>Captured</h3>')
        [void]$bodyHtml.Append('<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:13px"><tr><th>Alias</th><th>Title</th><th>Period</th><th>Status</th></tr>')
        foreach ($c in ($captured | Sort-Object alias, period_end)) {
            $period = if ($c.period_start -and $c.period_end) { "$($c.period_start) - $($c.period_end)" } else { '(no reflection period in mail)' }
            [void]$bodyHtml.Append("<tr><td>$($c.alias)</td><td>$($c.title)</td><td>$period</td><td>$($c.status)</td></tr>")
        }
        [void]$bodyHtml.Append('</table>')

        # Per-alias rollup.
        [void]$bodyHtml.Append('<h3>Per-direct counts</h3><ul>')
        foreach ($k in ($perAlias.Keys | Sort-Object)) {
            [void]$bodyHtml.Append("<li><b>$k</b>: $($perAlias[$k]) connect(s)</li>")
        }
        [void]$bodyHtml.Append('</ul>')
    }

    if ($quarantined.Count -gt 0) {
        [void]$bodyHtml.Append('<h3>Quarantined (need manual review)</h3><ul>')
        foreach ($q in $quarantined) {
            $line = $q.subject
            if ($q.reason) { $line += " &mdash; <i>$($q.reason)</i>" }
            [void]$bodyHtml.Append("<li>$line</li>")
        }
        [void]$bodyHtml.Append('</ul><p><i>These mails are still in the Inbox; nothing was saved or deleted for them.</i></p>')
    }

    if ($deduped.Count -gt 0) {
        [void]$bodyHtml.Append("<p style='color:#666'><i>$($deduped.Count) message(s) skipped as duplicates of content already captured locally.</i></p>")
    }

    [void]$bodyHtml.Append("<p style='color:#666;font-size:90%'>Storage: <code>$dataRoot</code> (outside the repo). Body content is never quoted in this summary.</p>")

    # Send via shared helper.
    . (Join-Path $skillsRoot '_runner-email.ps1')

    $jokes = @(
        "Captured $($captured.Count) Connects without leaking a single bullet point - `summarize` would be jealous.",
        "Connects filed under the user profile, not the repo. ``.gitignore`` is a fence; this is a moat.",
        "Manifest now tracks $($manifest.entries.Count) connects. Hashes don't lie - even when the calibration meeting does.",
        "Posted > In review > Draft. The status ladder, like the promo ladder, has fewer rungs than you'd hope."
    )

    $stats = "$($captured.Count) captured, $($quarantined.Count) quarantined, $deletedCount deleted"
    $sent = Send-RunnerSummaryEmail -RunnerName 'connect-buddy capture' `
                                    -SubjectSuffix "${today}: $stats" `
                                    -BodyHtml $bodyHtml.ToString() `
                                    -JokePool $jokes
    if ($sent) { Write-Log 'Summary email sent.' } else { Write-Log 'WARN: summary email send failed.' }

    Write-Log "Run complete. captured=$($captured.Count) deduped=$($deduped.Count) quarantined=$($quarantined.Count) deleted=$deletedCount"
}
finally {
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

