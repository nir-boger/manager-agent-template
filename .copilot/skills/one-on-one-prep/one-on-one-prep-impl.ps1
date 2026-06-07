#requires -Version 5.1
# one-on-one-prep impl: send prep emails for 1:1s in (Now+22h, Now+26h)
# and process direct-report replies to existing prep emails.
#
# This is the production worker. It is dot-sourced by
# run-one-on-one-prep.ps1 - DO NOT invoke directly without the runner
# prelude (config / log dir / agent root).
#
# IMPORTANT: this file dot-sources every shared helper at TOP-LEVEL
# script scope (NEVER inside a loop / conditional). See memory
# "powershell scoping": helpers loaded in a branch crash silently under
# DM-* scheduling when ErrorActionPreference='Stop' unwinds.

[CmdletBinding()]
param(
    [switch] $WhatIf,
    [switch] $DryRun,
    [int]    $SendHoursMin      = 22,
    [int]    $SendHoursMax      = 26,
    [int]    $PerTickCap        = 5,
    [string] $OnlySlug          = '',
    [string] $PreviewOut        = '',
    [switch] $SummaryMode,
    [string] $SummaryNotesFile  = ''
)

$ErrorActionPreference = 'Stop'

$skillDir = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $skillDir '..\..\..')).Path
$sharedDir = Join-Path $repoRoot '.copilot\skills\_shared'
$reportsRoot = Join-Path $repoRoot 'reports'
$logDir = Join-Path $reportsRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("one-on-one-prep-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")

function Write-PrepLog {
    param([string] $Message)
    $line = "$((Get-Date).ToString('o'))  $Message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# Dot-source every helper we need at the top.
. (Join-Path $skillDir         'helpers.ps1')
. (Join-Path $sharedDir        'signature.ps1')
. (Join-Path $sharedDir        'investigation-email.ps1')

# Fancy follow-up (summary) synthesis: model + the preview-reuse cache dir.
# The model id must be one copilot --model accepts (matches the prep path).
$summaryModel = 'claude-opus-4.7-high'
$summaryCacheDir = Join-Path $reportsRoot 'one-on-one-prep\preview-cache'

# Python helpers (directs resolver lives in the nirvana-board skill).
$boardDir = Join-Path $repoRoot '.copilot\skills\nirvana-board'
$pyResolve = Join-Path ([IO.Path]::GetTempPath()) ("one-on-one-prep-directs-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")

function Resolve-DirectsList {
    $py = @"
# -*- coding: utf-8 -*-
import sys, json
from pathlib import Path
sys.path.insert(0, r'$boardDir')
from directs import resolve_directs
repo = Path(r'$repoRoot')
res = resolve_directs(repo / 'reports' / 'directs-scope' / 'scope-board.md',
                      repo / '.copilot' / 'skills' / 'team-personas' / 'people')
sys.stdout.write(json.dumps(res, ensure_ascii=False))
"@
    [System.IO.File]::WriteAllText($pyResolve, $py, [System.Text.UTF8Encoding]::new($false))
    try {
        $raw = & python $pyResolve 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-PrepLog "ERROR: directs resolver failed exit=${LASTEXITCODE}: $raw"
            return @()
        }
        return ($raw | ConvertFrom-Json)
    } finally {
        Remove-Item -Path $pyResolve -ErrorAction SilentlyContinue
    }
}

function Get-OpenOnItems {
    param([Parameter(Mandatory)] [string] $Slug)
    $md = Join-Path $reportsRoot ("one-on-ones\$Slug.md")
    if (-not (Test-Path $md)) { return @() }
    $py = @"
# -*- coding: utf-8 -*-
import sys, json
from pathlib import Path
sys.path.insert(0, r'$boardDir')
import markdown_io as mio
text = Path(r'$md').read_text(encoding='utf-8')
items = mio.parse_one_on_one(text)
open_items = [i for i in items if i.get('status') == 'open']
sys.stdout.write(json.dumps([
    {'id': i['id'], 'title': i['title'], 'summary': i.get('summary',''), 'next_step': i.get('next_step','')}
    for i in open_items
], ensure_ascii=False))
"@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("one-on-one-prep-on-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
    [System.IO.File]::WriteAllText($tmp, $py, [System.Text.UTF8Encoding]::new($false))
    try {
        $raw = & python $tmp 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-PrepLog "WARN: open-items parse failed for slug=$Slug exit=${LASTEXITCODE}: $raw"
            return @()
        }
        return ($raw | ConvertFrom-Json)
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
}

function Get-OutlookOneOnOnesInWindow {
    param(
        [Parameter(Mandatory)] [int] $HoursMin,
        [Parameter(Mandatory)] [int] $HoursMax
    )
    # Returns @() if Outlook is unavailable; otherwise calendar items in
    # the (Now+HoursMin, Now+HoursMax) window whose subject matches the
    # 1:1 regex.
    $items = @()
    try {
        $ol = New-Object -ComObject Outlook.Application
    } catch {
        Write-PrepLog "WARN: Outlook unavailable: $($_.Exception.Message)"
        return @()
    }
    try {
        $ns = $ol.GetNamespace('MAPI')
        $cal = $ns.GetDefaultFolder(9) # olFolderCalendar
        $start = (Get-Date).AddHours($HoursMin)
        $end   = (Get-Date).AddHours($HoursMax)
        $filterStart = $start.ToString('g')
        $filterEnd   = $end.ToString('g')
        $restriction = "[Start] >= '$filterStart' AND [Start] <= '$filterEnd'"
        $col = $cal.Items
        $col.Sort('[Start]')
        $col.IncludeRecurrences = $true
        $filtered = $col.Restrict($restriction)
        foreach ($evt in $filtered) {
            try {
                $subj = [string]$evt.Subject
                if (-not (Test-OneOnOneSubject -Subject $subj)) { continue }
                if (-not $evt.Start) { continue }
                $attendees = @()
                try {
                    foreach ($r in $evt.Recipients) {
                        $smtp = $null
                        try {
                            $ae = $r.AddressEntry
                            if ($ae -and $ae.Type -eq 'EX') {
                                $eu = $ae.GetExchangeUser()
                                if ($eu) { $smtp = [string]$eu.PrimarySmtpAddress }
                            }
                        } catch {}
                        if (-not $smtp) {
                            try { $smtp = [string]$r.Address } catch {}
                        }
                        if ($smtp) { $attendees += $smtp }
                    }
                } catch {}
                $convId = ''
                try { $convId = [string]$evt.ConversationID } catch {}
                $items += [PSCustomObject]@{
                    Subject       = $subj
                    Start         = $evt.Start
                    IsoStart      = $evt.Start.ToUniversalTime().ToString('o')
                    Attendees     = $attendees
                    EntryID       = $evt.EntryID
                    ConversationId = $convId
                }
            } catch {}
        }
    } finally {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol) | Out-Null } catch {}
    }
    return $items
}

function Send-PrepEmail {
    param(
        [Parameter(Mandatory)] [hashtable] $Spec,
        [Parameter(Mandatory)] [string] $ToSmtp,
        [Parameter(Mandatory)] [string] $DirectName,
        [string] $CcSmtp = 'someone@example.com',
        [string] $Mode   = 'prep',
        [string] $PreRenderedHtml = '',
        [switch] $NoSig
    )
    $subjectPrefix = if ($Mode -eq 'summary') { '[Nirvana 1:1 summary]' } else { '[Nirvana 1:1 prep]' }
    $subject = "$subjectPrefix $DirectName"
    if ($PreRenderedHtml) {
        # Approved-preview reuse: send EXACTLY what Nir previewed (already
        # carries the signature). Do not rebuild or re-sign.
        $html = $PreRenderedHtml
    } else {
        if ($Mode -eq 'summary') {
            if ($Spec.SummaryFancy) {
                # Fancy follow-up: the notes were rewritten by the LLM into a
                # structured spec. Defense-in-depth: if the renderer throws,
                # fall back to the slim verbatim body so the email still sends.
                try {
                    $html = Build-InvestigationEmailHtml -Spec $Spec
                } catch {
                    Write-PrepLog "WARN: fancy summary render failed: $($_.Exception.Message). Falling back to slim body."
                    $html = Build-OneOnOneSummaryHtml -DirectName $DirectName -Notes ([string]$Spec.SummaryNotes) -Joke ([string]$Spec.Joke)
                }
            } else {
                # Slim conversational body: greeting + Nir's notes + joke.
                $html = Build-OneOnOneSummaryHtml -DirectName $DirectName -Notes ([string]$Spec.SummaryNotes) -Joke ([string]$Spec.Joke)
            }
        } else {
            $html = Build-InvestigationEmailHtml -Spec $Spec
        }
        if (-not $NoSig) {
            $html += (Get-NirvanaSignature -Variant InboxAuto)
        }
    }
    if ($WhatIf -or $DryRun) {
        Write-PrepLog "DRYRUN: to=$ToSmtp cc=$CcSmtp subject='$subject' bytes=$($html.Length)"
        return @{ Ok = $true; ConversationId = '' ; DryRun = $true; Html = $html }
    }
    try {
        $ol = New-Object -ComObject Outlook.Application
        $mail = $ol.CreateItem(0) # olMailItem
        $mail.Subject = $subject
        $mail.HTMLBody = $html
        $mail.To = $ToSmtp
        if ($CcSmtp) { $mail.CC = $CcSmtp }
        # Resolve recipients against the GAL so Outlook shows the person's
        # display name (e.g. "Your Name") instead of a quoted one-off SMTP
        # like 'someone@example.com'. Safe + silent for full addresses.
        try { $null = $mail.Recipients.ResolveAll() } catch {}
        # Stamp before send so the SentItems entry inherits the property.
        try {
            $stampName = if ($Mode -eq 'summary') { 'NirvanaOneOnOneSummary' } else { 'NirvanaOneOnOnePrep' }
            $up = $mail.UserProperties.Add($stampName, 1) # olText=1
            $up.Value = (Get-Date).ToString('o')
        } catch {}
        $mail.Send()
        $convId = ''
        try { $convId = [string]$mail.ConversationID } catch {}
        return @{ Ok = $true; ConversationId = $convId }
    } catch {
        Write-PrepLog "ERROR: send failed to=$ToSmtp : $($_.Exception.Message)"
        return @{ Ok = $false; ConversationId = '' }
    }
}

function Invoke-OneOnOnePrepReplyWatch {
    <#
    .SYNOPSIS
    Reply-watcher pass for the one-on-one-prep skill. Scans Outlook Inbox
    for direct-report replies to prep emails (matched by subject prefix
    `Re: [Nirvana 1:1 prep]` OR ConversationID in state/sent.txt within
    -WindowDays). For each unprocessed match, extracts 1-5 topics via
    copilot Opus 4.7 (high reasoning) and appends them as ON-NNN items in
    reports/one-on-ones/<slug>.md via one-on-one-agenda/add-item.py.
    Idempotent via the NirvanaOneOnOnePrepReplyProcessed UserProperty.

    Honors $script:DryRun / $script:WhatIf - in dry-run mode it logs the
    extracted topics and the planned add-item.py invocations but neither
    writes to the agenda file nor stamps the inbox item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Directs,
        [Parameter(Mandatory)] [string]   $StatePath,
        [int] $WindowDays = 7
    )
    $recent = @(Get-RecentPrepConversationIds -StatePath $StatePath -WindowDays $WindowDays)
    $convToSlug = @{}
    foreach ($r in $recent) {
        if ($r.ConversationId) { $convToSlug[[string]$r.ConversationId] = [string]$r.Slug }
    }

    $smtpToDirect = @{}
    foreach ($d in $Directs) {
        if ($d.smtp) { $smtpToDirect[([string]$d.smtp).Trim().ToLowerInvariant()] = $d }
    }

    $ol = $null
    try { $ol = New-Object -ComObject Outlook.Application } catch {
        Write-PrepLog "REPLY-WATCH: Outlook unavailable: $($_.Exception.Message). Skipping reply pass."
        return
    }
    $stampName = 'NirvanaOneOnOnePrepReplyProcessed'
    $processed = 0
    $topicsAdded = 0
    try {
        $ns = $ol.GetNamespace('MAPI')
        $inbox = $ns.GetDefaultFolder(6) # olFolderInbox
        $since = (Get-Date).AddDays(-1 * [Math]::Max(1, $WindowDays)).ToString('g')
        $col = $inbox.Items
        $col.Sort('[ReceivedTime]', $true)
        $filtered = $col.Restrict("[ReceivedTime] >= '$since'")

        $addScript = Join-Path $repoRoot '.copilot\skills\one-on-one-agenda\add-item.py'

        foreach ($m in $filtered) {
            try {
                $subj = ''
                try { $subj = [string]$m.Subject } catch { continue }
                $convId = ''
                try { $convId = [string]$m.ConversationID } catch {}

                $subjectMatch = [regex]::IsMatch($subj, '(?i)^re:\s*\[nirvana 1:1 prep\]')
                $convMatch = ($convId -and $convToSlug.ContainsKey($convId))
                if (-not $subjectMatch -and -not $convMatch) { continue }

                $senderSmtp = ''
                try { $senderSmtp = [string]$m.SenderEmailAddress } catch {}
                if (-not $senderSmtp -or $senderSmtp -notlike '*@*') {
                    try {
                        $ae = $m.Sender
                        if ($ae -and $ae.Type -eq 'EX') {
                            $eu = $ae.GetExchangeUser()
                            if ($eu) { $senderSmtp = [string]$eu.PrimarySmtpAddress }
                        }
                    } catch {}
                }
                if (-not $senderSmtp) {
                    Write-PrepLog "REPLY-WATCH: skip subject='$subj' reason=no-sender-smtp"
                    continue
                }
                $senderLower = $senderSmtp.Trim().ToLowerInvariant()
                $direct = $smtpToDirect[$senderLower]
                if (-not $direct) {
                    Write-PrepLog "REPLY-WATCH: skip sender=$senderLower subject='$subj' reason=not-a-direct-report"
                    continue
                }

                $alreadyProcessed = $false
                try {
                    $up = $m.UserProperties.Find($stampName)
                    if ($up) { $alreadyProcessed = $true }
                } catch {}
                if ($alreadyProcessed) { continue }

                $bodyRaw = ''
                try { $bodyRaw = [string]$m.Body } catch {}
                $bodyForExtract = Format-ReplyTextForExtraction -Body $bodyRaw -MaxChars 8000
                if (-not $bodyForExtract) {
                    Write-PrepLog "REPLY-WATCH: skip slug=$($direct.slug) subject='$subj' reason=empty-body"
                    continue
                }

                $topics = @()
                try {
                    $prompt = Build-ReplyExtractAgentPrompt -DirectName $direct.name -ReplyText $bodyForExtract
                    $promptFile = New-TemporaryFile
                    [System.IO.File]::WriteAllText($promptFile.FullName, $prompt, [System.Text.UTF8Encoding]::new($false))
                    try {
                        $raw = Get-Content -Path $promptFile.FullName -Raw -Encoding UTF8 | & copilot --allow-all-tools --no-ask-user --model claude-opus-4.7-high 2>&1 | Out-String
                        $topics = @(Format-ReplyTopicsFromAgentJson -RawText $raw)
                    } finally {
                        Remove-Item -Path $promptFile.FullName -ErrorAction SilentlyContinue
                    }
                } catch {
                    Write-PrepLog "REPLY-WATCH: topic extraction failed slug=$($direct.slug) : $($_.Exception.Message). Leaving item un-stamped for retry."
                    continue
                }

                $topicsAddedThisMail = 0
                $agendaFile = Join-Path $reportsRoot ("one-on-ones\$($direct.slug).md")
                foreach ($topic in $topics) {
                    if ($WhatIf -or $DryRun) {
                        Write-PrepLog "DRYRUN: would add ON for slug=$($direct.slug) topic='$topic'"
                        $topicsAddedThisMail++
                        continue
                    }
                    try {
                        $pyArgs = @(
                            $addScript,
                            '--agenda-file', $agendaFile,
                            '--person', $direct.name,
                            '--title', $topic,
                            '--kind', 'discussion',
                            '--opened-by', $direct.name,
                            '--owner', $direct.name,
                            '--summary', $topic,
                            '--why-matters', "Raised by $($direct.name) in the [Nirvana 1:1 prep] reply.",
                            '--next-step', 'Discuss at the upcoming 1:1.'
                        )
                        $pyOut = & python @pyArgs 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) {
                            Write-PrepLog "REPLY-WATCH: add-item.py failed slug=$($direct.slug) topic='$topic' exit=${LASTEXITCODE} out=$pyOut"
                        } else {
                            $topicsAddedThisMail++
                            $topicsAdded++
                        }
                    } catch {
                        Write-PrepLog "REPLY-WATCH: add-item.py error slug=$($direct.slug) topic='$topic' : $($_.Exception.Message)"
                    }
                }

                if (-not ($WhatIf -or $DryRun)) {
                    try {
                        $up = $m.UserProperties.Add($stampName, 1) # olText=1
                        $up.Value = (Get-Date).ToString('o')
                        $m.Save()
                    } catch {
                        Write-PrepLog "REPLY-WATCH: stamp failed slug=$($direct.slug) subject='$subj' : $($_.Exception.Message)"
                    }
                }

                $processed++
                Write-PrepLog "REPLY-WATCH: slug=$($direct.slug) sender=$senderLower topics_added=$topicsAddedThisMail subject='$subj'"

                if (-not ($WhatIf -or $DryRun) -and $topicsAddedThisMail -gt 0) {
                    try {
                        $confirmHtml = "<p>Hi Nir,</p><p>$($direct.name) replied to today's <code>[Nirvana 1:1 prep]</code> thread. I added <b>$topicsAddedThisMail</b> topic(s) to <code>reports/one-on-ones/$($direct.slug).md</code>:</p><ul>"
                        foreach ($topic in $topics) {
                            $esc = ($topic -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
                            $confirmHtml += "<li>$esc</li>"
                        }
                        $confirmHtml += '</ul><p>They will show on the Board under their persona before the next 1:1.</p>'
                        $confirmHtml += "<p style='color:#666;'>Adding a topic via mail beats finding it taped to the back of your monitor day-of.</p>"
                        $confirmHtml += (Get-NirvanaSignature -Variant InboxAuto)

                        $confirm = $ol.CreateItem(0)
                        $confirm.Subject = "[Nirvana] $($direct.name) added $topicsAddedThisMail topic(s) for the next 1:1"
                        $confirm.HTMLBody = $confirmHtml
                        $confirm.To = 'someone@example.com'
                        try { $null = $confirm.Recipients.ResolveAll() } catch {}
                        $confirm.Send()
                    } catch {
                        Write-PrepLog "REPLY-WATCH: confirmation send failed slug=$($direct.slug) : $($_.Exception.Message)"
                    }
                }
            } catch {
                Write-PrepLog "REPLY-WATCH: error processing item: $($_.Exception.Message)"
            }
        }

        Write-PrepLog "REPLY-WATCH: complete. replies_processed=$processed topics_added=$topicsAdded"
    } finally {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol) | Out-Null } catch {}
    }
}

function Get-DirectsContext {
    param([Parameter(Mandatory)] [string] $ContextFile)
    if (-not (Test-Path $ContextFile)) { return @{} }
    try {
        $obj = Get-Content -Path $ContextFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-PrepLog "WARN: failed to parse $ContextFile : $($_.Exception.Message)"
        return @{}
    }
    $map = @{}
    if ($obj.directs) {
        foreach ($prop in $obj.directs.PSObject.Properties) {
            $map[$prop.Name] = $prop.Value
        }
    }
    return $map
}

# --- Main ---------------------------------------------------------------

$directs = @(Resolve-DirectsList)
if ($directs.Count -eq 0) {
    Write-PrepLog "one-on-one-prep: 0 directs resolved. Exiting."
    return
}
Write-PrepLog "one-on-one-prep: $($directs.Count) direct(s) resolved."

$statePath = Get-PrepSentStatePath -ReportsRoot $reportsRoot
$contextFile = Join-Path $reportsRoot 'directs-scope\directs-context.json'
$directsContext = Get-DirectsContext -ContextFile $contextFile

# directs-context.json is the authoritative (GAL-resolved) source for each
# direct's SMTP. The persona-file heuristic used by resolve_directs
# (directs.py _extract_smtp grabs the first email found in the persona prose)
# is unreliable: it yields $null for most directs and can capture the wrong
# address (e.g. Nir's own) from narrative text -- a mis-send risk. Override
# every direct's smtp from the context whenever it carries a non-empty value
# for that slug; fall back to the persona-derived smtp only when the context
# has nothing for that slug.
foreach ($d in $directs) {
    if (-not $d.slug) { continue }
    $ctx = $directsContext[[string]$d.slug]
    if ($ctx -and $ctx.smtp -and ([string]$ctx.smtp).Trim()) {
        $ctxSmtp = ([string]$ctx.smtp).Trim()
        if ($d.PSObject.Properties['smtp']) { $d.smtp = $ctxSmtp }
        else { $d | Add-Member -NotePropertyName smtp -NotePropertyValue $ctxSmtp -Force }
    } elseif (-not $d.smtp) {
        Write-PrepLog "WARN: no authoritative smtp in directs-context for slug=$($d.slug); persona-derived smtp is empty too."
    }
}

# Load summary notes early - used only when -SummaryMode is set.
$summaryNotesText = ''
if ($SummaryMode) {
    if (-not $OnlySlug) {
        Write-PrepLog "ERROR: -SummaryMode requires -OnlySlug. Exiting."
        return
    }
    if ($SummaryNotesFile -and (Test-Path $SummaryNotesFile)) {
        try {
            $summaryNotesText = [System.IO.File]::ReadAllText($SummaryNotesFile, [System.Text.UTF8Encoding]::new($false))
        } catch {
            Write-PrepLog "WARN: failed to read SummaryNotesFile=$SummaryNotesFile : $($_.Exception.Message)"
        }
    }
    Write-PrepLog "SUMMARY-MODE: slug=$OnlySlug notes-bytes=$($summaryNotesText.Length)"
}

# In summary mode we synthesize a single candidate up-front and skip the
# calendar scan entirely - this is post-meeting, not pre-meeting.
$candidates = @()
if ($SummaryMode) {
    $targetDirect = $directs | Where-Object { $_.slug -eq $OnlySlug } | Select-Object -First 1
    if (-not $targetDirect) {
        Write-PrepLog "ERROR: -SummaryMode -OnlySlug '$OnlySlug' did not match any direct. Exiting."
        return
    }
    if (-not $targetDirect.smtp) {
        Write-PrepLog "ERROR: -SummaryMode slug='$OnlySlug' resolved no SMTP (absent from directs-context.json and none found in persona). Cannot compose the summary. Exiting."
        return
    }
    $fakeStart = (Get-Date).AddHours(-1)
    $synthesized = [PSCustomObject]@{
        Subject       = "[summary] $($targetDirect.name) / Nir 1:1"
        Start         = $fakeStart
        IsoStart      = $fakeStart.ToUniversalTime().ToString('o')
        Attendees     = @($targetDirect.smtp)
        EntryID       = "summary-$OnlySlug"
        ConversationId = ''
    }
    $candidates = @($synthesized)
} else {
    $candidates = @(Get-OutlookOneOnOnesInWindow -HoursMin $SendHoursMin -HoursMax $SendHoursMax)
    Write-PrepLog "one-on-one-prep: $($candidates.Count) calendar candidate(s) in window (Now+${SendHoursMin}h, Now+${SendHoursMax}h)."
}

if ($OnlySlug -and -not $SummaryMode) {
    $targetDirect = $directs | Where-Object { $_.slug -eq $OnlySlug } | Select-Object -First 1
    if (-not $targetDirect) {
        Write-PrepLog "ERROR: -OnlySlug '$OnlySlug' did not match any direct. Exiting."
        return
    }
    if (-not $targetDirect.smtp) {
        Write-PrepLog "ERROR: -OnlySlug '$OnlySlug' resolved no SMTP (absent from directs-context.json and none found in persona). Cannot synthesize a candidate. Exiting."
        return
    }
    $fakeStart = (Get-Date).AddHours(24)
    $synthesized = [PSCustomObject]@{
        Subject       = "[synthesized] $($targetDirect.name) / Nir 1:1"
        Start         = $fakeStart
        IsoStart      = $fakeStart.ToUniversalTime().ToString('o')
        Attendees     = @($targetDirect.smtp)
        EntryID       = "preview-$OnlySlug"
        ConversationId = ''
    }
    $candidates = @($synthesized)
    Write-PrepLog "ONLY-SLUG: overriding calendar scan; synthesized 1 candidate for slug=$OnlySlug iso=$($synthesized.IsoStart)"
}

$sent = 0
foreach ($evt in $candidates) {
    if ($sent -ge $PerTickCap) {
        Write-PrepLog "one-on-one-prep: per-tick cap=$PerTickCap reached. Stopping send loop."
        break
    }
    # Skip group meetings that just happen to match a 1:1 keyword like "sync".
    # A real 1:1 has Nir + the direct as attendees (sometimes a resource);
    # any meeting with more than 3 attendees is not a 1:1 even if a single
    # direct is among them. SummaryMode synthesizes a candidate so this
    # check only matters for the calendar-scan path.
    if (-not $SummaryMode -and -not $OnlySlug -and $evt.Attendees -and $evt.Attendees.Count -gt 3) {
        Write-PrepLog "SKIP: subject='$($evt.Subject)' iso=$($evt.IsoStart) reason=not-a-1-on-1 (attendees=$($evt.Attendees.Count))"
        continue
    }
    $direct = Resolve-DirectFromAttendees -AttendeeSmtps $evt.Attendees -Directs $directs
    if (-not $direct) {
        Write-PrepLog "SKIP: subject='$($evt.Subject)' iso=$($evt.IsoStart) reason=no-single-direct"
        continue
    }
    if (Test-PrepAlreadySent -StatePath $statePath -Slug $direct.slug -MeetingIsoStart $evt.IsoStart) {
        Write-PrepLog "SKIP: slug=$($direct.slug) iso=$($evt.IsoStart) reason=already-sent"
        continue
    }
    if (-not $direct.smtp) {
        Write-PrepLog "SKIP: slug=$($direct.slug) reason=no-smtp"
        continue
    }
    $openItems = @(Get-OpenOnItems -Slug $direct.slug)
    $openSummaries = @()
    foreach ($oi in $openItems) {
        $sum = if ($oi.summary -and $oi.summary -ne '-') { $oi.summary } else { $oi.title }
        if ($sum) { $openSummaries += [string]$sum }
    }
    $ctx = $directsContext[$direct.slug]
    $recentPrs = @()
    $activeWis = @()
    $highlights = @()
    $recentWins = @()
    $personalNotes = ''
    $milestones = @()
    if ($ctx) {
        if ($ctx.recent_prs)          { $recentPrs     = @($ctx.recent_prs) }
        if ($ctx.active_work_items)   { $activeWis     = @($ctx.active_work_items) }
        if ($ctx.persona_highlights)  { $highlights    = @($ctx.persona_highlights) }
        if ($ctx.recent_wins)         { $recentWins    = @($ctx.recent_wins) }
        if ($ctx.personal_notes)      { $personalNotes = [string]$ctx.personal_notes }
        if ($ctx.upcoming_milestones) { $milestones    = @($ctx.upcoming_milestones) }
    }
    # NOTE: LLM topic synthesis is intentionally guarded behind a try/catch
    # so a failed copilot invocation never blocks the deterministic prep
    # email. The deterministic sections (scope, open follow-ups, recent
    # threads) alone are still very useful. Skip it on summary mode -
    # this is a post-meeting recap, not a pre-meeting topic list.
    # NOTE: LLM synthesis is intentionally guarded behind try/catch so a
    # failed copilot invocation never blocks the deterministic email.
    #  - prep mode    : synthesize ranked discussion topics.
    #  - summary mode : REWRITE Nir's rough notes into a fancy follow-up
    #                   (Build-OneOnOneSummarySpec). A real Send reuses the
    #                   exact HTML Nir previewed (preview cache, notes-hash
    #                   keyed); only a cache miss / dry-run regenerates.
    $topics = @()
    $summaryFancySpec = $null
    $preRenderedHtml = ''
    $notesHash = ''
    if ($SummaryMode) {
        if ($summaryNotesText.Trim()) {
            $notesHash = Get-SummaryNotesHash -Slug $direct.slug -Notes $summaryNotesText
            $isRealSend = -not ($DryRun -or $WhatIf)
            if ($isRealSend) {
                $cachedHtml = Get-SummaryPreviewCache -CacheDir $summaryCacheDir -Slug $direct.slug -NotesHash $notesHash -MaxAgeHours 12
                if ($cachedHtml) {
                    $preRenderedHtml = $cachedHtml
                    Write-PrepLog "SUMMARY: reusing cached preview render for slug=$($direct.slug) (notes unchanged since dry-run)."
                }
            }
            if (-not $preRenderedHtml) {
                try {
                    $prompt = Build-OneOnOneSummaryAgentPrompt `
                        -DirectName $direct.name `
                        -Notes $summaryNotesText `
                        -ScopeNow $direct.scope_now `
                        -ScopeNext $direct.scope_next
                    $promptFile = New-TemporaryFile
                    [System.IO.File]::WriteAllText($promptFile.FullName, $prompt, [System.Text.UTF8Encoding]::new($false))
                    try {
                        $raw = Get-Content -Path $promptFile.FullName -Raw -Encoding UTF8 | & copilot --allow-all-tools --no-ask-user --model $summaryModel 2>&1 | Out-String
                        $struct = Format-SummaryFromAgentJson -RawText $raw
                        if ($struct -and (Test-SummaryStructUsable -Summary $struct)) {
                            $summaryFancySpec = Build-OneOnOneSummarySpec `
                                -DirectName $direct.name `
                                -Summary $struct `
                                -Joke '' `
                                -MeetingIsoStart $evt.IsoStart
                            Write-PrepLog "SUMMARY: synthesized fancy follow-up for slug=$($direct.slug) (sections=$($summaryFancySpec.Sections.Count))."
                        } else {
                            Write-PrepLog "WARN: summary synthesis produced no usable content for slug=$($direct.slug). Falling back to slim body."
                        }
                    } finally {
                        Remove-Item -Path $promptFile.FullName -ErrorAction SilentlyContinue
                    }
                } catch {
                    Write-PrepLog "WARN: summary synthesis failed for slug=$($direct.slug) : $($_.Exception.Message). Falling back to slim body."
                }
            }
        } else {
            Write-PrepLog "SUMMARY: notes empty for slug=$($direct.slug); using slim '(no notes captured)' body."
        }
    } else {
        try {
            $prompt = Build-OneOnOnePrepAgentPrompt `
                -DirectName $direct.name `
                -DirectSmtp $direct.smtp `
                -ScopeNow   $direct.scope_now `
                -ScopeNext  $direct.scope_next `
                -OpenItems  $openSummaries `
                -RecentSubjects @() `
                -RecentPrs $recentPrs `
                -ActiveWorkItems $activeWis `
                -PersonaHighlights $highlights
            $promptFile = New-TemporaryFile
            [System.IO.File]::WriteAllText($promptFile.FullName, $prompt, [System.Text.UTF8Encoding]::new($false))
            try {
                $raw = Get-Content -Path $promptFile.FullName -Raw -Encoding UTF8 | & copilot --allow-all-tools --no-ask-user --model claude-opus-4.7-high 2>&1 | Out-String
                $topics = @(Format-TopicsFromAgentJson -RawText $raw)
            } finally {
                Remove-Item -Path $promptFile.FullName -ErrorAction SilentlyContinue
            }
        } catch {
            Write-PrepLog "WARN: topic-synthesis failed for slug=$($direct.slug) : $($_.Exception.Message). Sending without LLM topics."
        }
    }

    $joke = ''
    $mode = if ($SummaryMode) { 'summary' } else { 'prep' }
    if ($SummaryMode -and $summaryFancySpec) {
        $spec = $summaryFancySpec
    } else {
        $spec = Build-PrepEmailSpec `
            -DirectName $direct.name `
            -ScopeNow $direct.scope_now `
            -ScopeNext $direct.scope_next `
            -OpenItems $openSummaries `
            -RecentSubjects @() `
            -Topics $topics `
            -RecentPrs $recentPrs `
            -ActiveWorkItems $activeWis `
            -PersonaHighlights $highlights `
            -RecentWins $recentWins `
            -PersonalNotes $personalNotes `
            -UpcomingMilestones $milestones `
            -SummaryNotes $summaryNotesText `
            -Mode $mode `
            -MeetingIsoStart $evt.IsoStart `
            -Joke $joke
    }

    $send = Send-PrepEmail -Spec $spec -ToSmtp $direct.smtp -DirectName $direct.name -Mode $mode -PreRenderedHtml $preRenderedHtml
    if ($send.Ok) {
        if ($PreviewOut -and $send.Html) {
            try {
                $previewDir = Split-Path -Parent $PreviewOut
                if ($previewDir -and -not (Test-Path $previewDir)) { New-Item -ItemType Directory -Path $previewDir -Force | Out-Null }
                [System.IO.File]::WriteAllText($PreviewOut, [string]$send.Html, [System.Text.UTF8Encoding]::new($false))
                Write-PrepLog "PREVIEW: wrote $PreviewOut ($($send.Html.Length) bytes)"
            } catch {
                Write-PrepLog "WARN: failed to write preview file $PreviewOut : $($_.Exception.Message)"
            }
        }
        # Cache the previewed fancy render so the matching real Send is
        # byte-identical to what Nir approved (notes-hash keyed).
        if ($SummaryMode -and $summaryFancySpec -and $send.Html -and $notesHash -and ($DryRun -or $WhatIf)) {
            try {
                $cp = Set-SummaryPreviewCache -CacheDir $summaryCacheDir -Slug $direct.slug -NotesHash $notesHash -Html ([string]$send.Html)
                Write-PrepLog "SUMMARY: cached preview render for slug=$($direct.slug) -> $cp"
            } catch {
                Write-PrepLog "WARN: failed to cache preview render for slug=$($direct.slug) : $($_.Exception.Message)"
            }
        }
        if ($OnlySlug -or $send.DryRun) {
            # Skip state writes on -OnlySlug / dry-run paths so we don't poison
            # idempotency for the real meeting if/when it appears in calendar.
            Write-PrepLog "PREVIEW: slug=$($direct.slug) to=$($direct.smtp) topics=$($topics.Count) (no state write)"
        } else {
            $sentIso = (Get-Date).ToUniversalTime().ToString('o')
            Add-PrepSent -StatePath $statePath `
                -SentIso $sentIso `
                -Slug $direct.slug `
                -MeetingIsoStart $evt.IsoStart `
                -ConversationId $send.ConversationId
            Write-PrepLog "SENT: slug=$($direct.slug) to=$($direct.smtp) iso=$($evt.IsoStart) topics=$($topics.Count)"
        }
        $sent++
    }
}

Write-PrepLog "one-on-one-prep: complete. sent=$sent"

# --- Reply-watcher pass --------------------------------------------------
# Scan Inbox for direct-report replies to recent [Nirvana 1:1 prep] mails
# and persist the topics they raised into reports/one-on-ones/<slug>.md.
# Single-shot modes (SummaryMode / OnlySlug) skip this pass - they target
# one specific direct and don't enumerate the calendar / inbox broadly.
if (-not $SummaryMode -and -not $OnlySlug) {
    try {
        Invoke-OneOnOnePrepReplyWatch -Directs $directs -StatePath $statePath
    } catch {
        Write-PrepLog "REPLY-WATCH: unhandled exception: $($_.Exception.Message)"
    }
}

