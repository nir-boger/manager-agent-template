#Requires -Version 5.1
<#
.SYNOPSIS
    inbox-watch skill implementation - auto-replies to direct reports who address "Nirvana" in their inbox mail.
#>

param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# Bootstrap config: this script is invoked by `copilot -p` (not via runner-prelude).
. (Join-Path $PSScriptRoot '..\_shared\config.ps1')
. (Join-Path $PSScriptRoot '..\_shared\migration-mode.ps1')

$cfg            = Get-AgentConfig
$mgrEmail       = (Get-AgentField -Path 'manager.email'              -Default 'you@example.com'   -Config $cfg).ToLower()
$mgrEmailLower  = $mgrEmail
$idemTag        =  Get-AgentField -Path 'agent.idempotency_tag'      -Default 'NirvanaProcessed'          -Config $cfg
$subjectPrefix  =  Get-AgentField -Path 'agent.mail_subject_prefix'  -Default '[Nirvana]'                 -Config $cfg
$triggerAliases =  Get-AgentField -Path 'agent.trigger_aliases'      -Default @('nirvana','@nirvana')     -Config $cfg
$reportsRoot    =  Get-AgentField -Path 'paths.reports_root'         -Default 'reports'                   -Config $cfg
$personasRel    =  Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $cfg
$pythonExe      =  Get-AgentField -Path 'paths.python_exe'           -Default 'python'                    -Config $cfg

# personal-todos auto-add wiring: every deferred-to-Nir reply also appends a
# follow-up PT-NNN row so the mail (after being moved to Kusto\Co-Workers) is
# not forgotten. See inbox-watch/SKILL.md security-scope write #7 and §10b.
$todosFile  = Join-Path (Resolve-AgentPath $reportsRoot -Config $cfg) 'personal-todos\todos.md'
$addItemPy  = Join-Path $PSScriptRoot '..\personal-todos\add-item.py'

function Format-PtTitle {
    param([string]$FirstName, [string]$Subject)
    $s = $Subject
    if (-not $s) { return "Follow up with $FirstName on their latest mail" }
    $s = $s -replace '^\s*(?i)(re|fwd|fw)\s*:\s*', ''
    $s = $s -replace '^\s*\[Nirvana\]\s*-?\s*', ''
    $s = ($s -replace '\s+', ' ').Trim()
    if (-not $s) { return "Follow up with $FirstName on their latest mail" }
    if ($s.Length -gt 120) { $s = $s.Substring(0, 117).TrimEnd() + '...' }
    return "Follow up with $FirstName on: $s"
}

# Build the trigger regexes from agent.trigger_aliases:
#   - Bareword aliases (e.g. "nirvana") become \b<escaped>\b.
#   - At-prefix aliases (e.g. "@nirvana") become @<escaped>\b.
$_bareWords = @()
$_atWords   = @()
foreach ($a in $triggerAliases) {
    if ($a -match '^@(.+)$') { $_atWords   += [regex]::Escape($matches[1]) }
    else                     { $_bareWords += [regex]::Escape($a) }
}
if (-not $_bareWords) { $_bareWords = @([regex]::Escape($cfg.agent.name)) }
$bareGroup = '(?:' + ($_bareWords -join '|') + ')'
$atGroup   = if ($_atWords) { '(?:' + ($_atWords -join '|') + ')' } else { $bareGroup }
$preambleAddressPatterns = @(
    "(?im)^\s*(hi|hey|hello|shalom|שלום|good\s+morning|good\s+afternoon|good\s+evening|בוקר טוב|ערב טוב)\s*[, ]+\s*$bareGroup\b",
    "(?im)^\s*$bareGroup\s*[,:\-]",
    "(?im)\B@$atGroup\b",
    "(?im)\bdear\s+$bareGroup\b"
)
$subjectMatchPattern   = "\b$bareGroup\b"
$subjectExcludePattern = "$bareGroup\s+(team|group|account)"

# Check Outlook is running
if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    Write-Output "⚠️ Outlook is not running. Skipping inbox-watch."
    exit 0
}

# Initialize
$ol = New-Object -ComObject Outlook.Application
$ns = $ol.GetNamespace('MAPI')
$now = Get-Date
$logDate = $now.ToString('yyyy-MM-dd')
$logPath = Join-Path (Resolve-AgentPath $reportsRoot -Config $cfg) "inbox-watch\$logDate.md"
$summaries = @()
$processedCount = 0

# Ensure log directory exists
$logDir = Split-Path $logPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Build direct-report roster
Write-Output "Building roster..."
$personaFiles = Get-ChildItem (Join-Path (Resolve-AgentPath $personasRel -Config $cfg) '*.md')
$roster = @()

foreach ($pf in $personaFiles) {
    $content = Get-Content $pf.FullName -Raw
    $alias = $pf.BaseName
    
    # Parse display name
    $displayName = ''
    if ($content -match '(?m)^#\s+(.+)$') {
        $displayName = $matches[1] -replace 'Working-Style Persona:\s*', '' -replace '—', '-'
    }
    
    # Parse email
    $email = ''
    $lines = ($content -split "`n")[0..14]
    foreach ($line in $lines) {
        if ($line -match '([a-z0-9.-]+)@microsoft\.com') {
            $email = $matches[1] + '@microsoft.com'
            break
        }
    }
    if (-not $email) {
        $email = ($alias -replace '-', '.') + '@microsoft.com'
    }
    
    # Resolve via GAL
    $firstName = ($displayName -split '\s+')[0]
    $exSmtp = ''
    try {
        $r = $ns.CreateRecipient($email)
        $null = $r.Resolve()
        if ($r.Resolved) {
            $exUser = $r.AddressEntry.GetExchangeUser()
            if ($exUser) {
                $exSmtp = $exUser.PrimarySmtpAddress
            }
        }
    } catch {
        # Skip unresolved
    }
    
    if ($exSmtp) {
        $roster += [PSCustomObject]@{
            Alias = $alias
            DisplayName = $displayName
            FirstName = $firstName
            Email = $exSmtp.ToLower()
        }
    }
}

Write-Output "OK Roster: $($roster.Count) direct reports"

# Read unread inbox items (last 24h only)
Write-Output "Scanning inbox..."
$inbox = $ns.GetDefaultFolder(6)  # olFolderInbox
$cutoff = $now.AddHours(-24)
$candidates = @()

foreach ($m in $inbox.Items) {
    if ($m.Class -ne 43) { continue }  # 43 = olMail
    if (-not $m.UnRead) { continue }
    if ($m.ReceivedTime -lt $cutoff) { continue }
    $candidates += $m
}

Write-Output "✓ Found $($candidates.Count) unread items in last 24h"

# Hard cap
if ($candidates.Count -gt 50) {
    Write-Output "⚠️ WARNING: >50 items. Processing first 50 only."
    $candidates = $candidates[0..49]
}

# Process each item
foreach ($m in $candidates) {
    try {
        $subject = $m.Subject
        $receivedTime = $m.ReceivedTime
        $skip = $false
        $skipReason = ''
        $class = ''
        
        # Step 3: Filter automated/loop/list mail
        if ($m.MessageClass -notlike 'IPM.Note*') {
            $skip = $true
            $skipReason = 'not-a-note'
        }
        
        if (-not $skip) {
            try {
                $pa = $m.PropertyAccessor
                $headers = $pa.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x007D001F')
                
                # Check for automated headers
                if ($headers -match '(?i)(Auto-Submitted:\s*(?!no)|X-Auto-Response-Suppress|X-Autoreply|X-Autorespond|Precedence:\s*(bulk|list|junk)|List-Id|List-Unsubscribe)') {
                    $skip = $true
                    $skipReason = 'automated'
                }
            } catch {
                # No headers or error reading - continue
            }
        }
        
        # Check sender
        if (-not $skip) {
            $senderSmtp = ''
            try {
                $sender = $m.Sender
                if ($sender) {
                    $exUser = $sender.GetExchangeUser()
                    if ($exUser) {
                        $senderSmtp = $exUser.PrimarySmtpAddress
                    }
                }
            } catch {}
            
            if (-not $senderSmtp) {
                try {
                    $senderSmtp = $pa.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x39FE001E')
                } catch {}
            }
            
            if (-not $senderSmtp) {
                $senderSmtp = $m.SenderEmailAddress
            }
            
            if (-not $senderSmtp -or $senderSmtp -notlike '*@*') {
                $skip = $true
                $skipReason = 'no-sender-smtp'
            } elseif ($senderSmtp.ToLower() -eq $mgrEmailLower) {
                $skip = $true
                $skipReason = 'sender-is-manager'
            } elseif ($senderSmtp -notlike '*@microsoft.com') {
                $skip = $true
                $skipReason = 'external'
            } else {
                # Match roster
                $senderSmtpLower = $senderSmtp.ToLower()
                $match = $roster | Where-Object { $_.Email -eq $senderSmtpLower } | Select-Object -First 1
                if (-not $match) {
                    $skip = $true
                    $skipReason = 'not-direct-report'
                }
            }
        }
        
        # Step 5: Extract preamble
        $preamble = ''
        $plain = $m.Body
        
        # Cut at quoted history markers
        $cutPos = -1
        $patterns = @(
            '(?m)^-{3,}\s*Original Message\s*-{3,}',
            '(?m)^_{3,}',
            '(?m)^From:.+Sent:',
            '(?m)^On .+ wrote:\s*$',
            '(?m)^בתאריך .+ כתב',
            '(?m)^>'
        )
        
        foreach ($pat in $patterns) {
            if ($plain -match $pat) {
                $pos = $matches[0].Index
                if ($cutPos -eq -1 -or $pos -lt $cutPos) {
                    $cutPos = $pos
                }
            }
        }
        
        if ($cutPos -gt 0) {
            $plain = $plain.Substring(0, $cutPos)
        }
        
        # First 8 non-empty lines
        $lines = $plain -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 8
        $preamble = ($lines -join "`n").ToLower()
        
        # Step 6: Match agent name address (preamble + subject)
        if (-not $skip) {
            $subjectLine = ($subject -replace '(?i)^(Re|RE|Fwd|FW):\s*', '').ToLower()
            
            $matched = $false
            foreach ($pat in $preambleAddressPatterns) {
                if (($preamble -match $pat) -or ($subjectLine -match $pat)) {
                    $matched = $true
                    break
                }
            }
            
            # Subject-only permissive match (skill name appears in subject, length-bounded).
            if (-not $matched -and $subjectLine.Length -le 80 -and $subjectLine -match $subjectMatchPattern) {
                if ($subjectLine -notmatch $subjectExcludePattern) {
                    $matched = $true
                }
            }
            
            if (-not $matched) {
                $skip = $true
                $skipReason = 'no-agent-address'
            }
        }
        
        # Step 7: Idempotency check
        if (-not $skip) {
            $existing = $m.UserProperties.Find($idemTag)
            if ($existing) {
                $skip = $true
                $skipReason = 'already-processed'
            }
        }
        
        # Step 8: ReplyAll audience guardrail
        if (-not $skip) {
            $recips = @()
            foreach ($r in $m.Recipients) {
                $recips += $r
            }
            
            if ($recips.Count -gt 8) {
                $skip = $true
                $skipReason = 'large-audience'
            } else {
                foreach ($r in $recips) {
                    try {
                        $ae = $r.AddressEntry
                        $aetype = $ae.AddressEntryUserType
                        
                        # Check for DL
                        if ($aetype -in @(1, 4, 5)) {  # olDistList, olOutlookDistributionList, olRemoteUser
                            $skip = $true
                            $skipReason = 'dl-in-recipients'
                            break
                        }
                        
                        # Check for external
                        $exUser = $ae.GetExchangeUser()
                        if ($exUser) {
                            $rSmtp = $exUser.PrimarySmtpAddress
                            if ($rSmtp -notlike '*@microsoft.com') {
                                $skip = $true
                                $skipReason = 'external-recipient'
                                break
                            }
                        }
                    } catch {
                        # Conservative - skip if we can't verify
                        $skip = $true
                        $skipReason = 'unresolved-recipient'
                        break
                    }
                }
            }
        }
        
        # If skipped, continue to next item (no summary, no log)
        if ($skip) {
            if ($skipReason -notin @('not-a-note', 'automated', 'no-sender-smtp', 'sender-is-manager', 'external', 'not-direct-report', 'no-agent-address', 'already-processed')) {
                # These warrant a log entry
                Write-Output "⚠️ SKIPPED: $subject | reason=$skipReason"
            }
            continue
        }
        
        # At this point, we have a valid item to process
        Write-Output "✓ PROCESSING: $subject | from=$($match.DisplayName)"
        
        # Classify (simplified for now - defer to Nir)
        $class = 'general'
        $wasDeferredToNir = $true  # Every successful send here uses the §10b fallback today.
        
        # Use deferred-to-manager fallback for safety
        $firstName  = $match.FirstName
        $managerFn  = Get-AgentField -Path 'manager.first_name' -Default 'Nir'     -Config $cfg
        $agentName  = Get-AgentField -Path 'agent.name'         -Default 'Nirvana' -Config $cfg
        $bodyHtml = @"
<p>Hi $firstName,</p>
<p>Thanks for the note. This one needs $managerFn to weigh in directly &mdash; I'm holding off on an answer so we don't get it wrong. $managerFn will follow up.</p>
<p><em>Why did the database administrator break up with their partner? Too many foreign key constraints in the relationship.</em></p>
<p>&mdash; $agentName</p>
"@
        # Append shared signature (auto-reply variant) for parity with downstream sends.
        . (Join-Path $PSScriptRoot '..\_shared\signature.ps1')
        $bodyHtml += (Get-NirvanaSignature -Variant InboxAuto)
        
        # Sendability filter (basic check)
        if ($bodyHtml.Length -lt 20) {
            Write-Output "⚠️ BLOCKED: Body too short"
            continue
        }
        
        # Step 12: Atomic post-send sequence
        if (-not $WhatIf) {
            # Find Co-Workers folder
            $root = $inbox.Parent
            
            function Find-FolderByName($folder, $namesRegex, $depth = 0) {
                if ($depth -gt 6) { return $null }
                foreach ($f in $folder.Folders) {
                    if ($f.Name -match $namesRegex) { return $f }
                    $r = Find-FolderByName $f $namesRegex ($depth + 1)
                    if ($r) { return $r }
                }
                return $null
            }
            
            $kusto  = Find-FolderByName $root '^(?i)Kusto$'
            $cowork = if ($kusto) { Find-FolderByName $kusto '^(?i)co[-]?workers?$' } else { $null }
            
            # Send ReplyAll (gated by migration mode)
            $reply = $m.ReplyAll()
            $reply.HTMLBody = $bodyHtml + $reply.HTMLBody
            if (Test-MigrationMode) {
                Write-Output "  [migration-mode] Skipping ReplyAll.Send() for: $subject"
            } else {
                $reply.Send()
            }
            
            # Mark read
            $m.UnRead = $false
            
            # Stamp processed
            $up = $m.UserProperties.Add($idemTag, 1, $false)
            $up.Value = $now.ToString('yyyy-MM-ddTHH:mm:ssK')
            $m.Save()
            
            # Move to Co-Workers
            $filed = 'inbox'
            if ($cowork) {
                $null = $m.Move($cowork)
                $filed = 'co-workers'
            } else {
                Write-Output "WARN: Co-Workers folder not found; leaving in Inbox"
            }
            
            Write-Output "✅ SENT + MOVED to $filed"
            
            # Auto-add a follow-up todo so Nir doesn't forget about the mail
            # now that it's been moved out of Inbox. Only fires on deferred-to-Nir
            # replies (§10b) — substantive auto-answers don't need a follow-up.
            # Skipped in migration mode to avoid polluting the live todo list.
            $todoPtId = $null
            if ($wasDeferredToNir -and (Test-Path $todosFile) -and (Test-Path $addItemPy) -and -not (Test-MigrationMode)) {
                try {
                    $ptTitle = Format-PtTitle -FirstName $firstName -Subject $subject
                    $preambleSnippet = ($preamble -replace '\s+', ' ').Trim()
                    if ($preambleSnippet.Length -gt 180) { $preambleSnippet = $preambleSnippet.Substring(0, 177) + '...' }
                    $ptNotes  = "From $($match.DisplayName) <$senderSmtpLower>; auto-replied $($now.ToString('yyyy-MM-dd HH:mm')); mail moved to Kusto\Co-Workers.<br>What they asked: $preambleSnippet"
                    $pyArgs   = @(
                        $addItemPy,
                        '--todos-file', $todosFile,
                        '--title',      $ptTitle,
                        '--category',   'work',
                        '--notes',      $ptNotes
                    )
                    $ptStdout = & $pythonExe @pyArgs 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $firstLine = ($ptStdout | Select-Object -First 1) -as [string]
                        if ($firstLine -match '^(PT-\d{3})\b') {
                            $todoPtId = $Matches[1]
                            Write-Output "  ✓ Added follow-up todo: $todoPtId"
                        } else {
                            Write-Output "  ⚠️ add-item.py succeeded but PT-NNN not parsed from: $firstLine"
                        }
                    } else {
                        Write-Output "  ⚠️ add-item.py exit=$LASTEXITCODE; output: $(($ptStdout | Out-String).Trim())"
                    }
                } catch {
                    Write-Output "  ⚠️ Failed to add follow-up todo: $_"
                }
            }
            
            # Log
            $logTime = $now.ToString('HH:mm')
            $ptTag   = if ($todoPtId) { ";pt=$todoPtId" } else { '' }
            $logLine = "- $logTime from=$senderSmtpLower class=$class status=sent filed=$filed subject=`"$subject`" notes=deferred-to-nir$ptTag"
            Add-Content -Path $logPath -Value $logLine -Encoding UTF8
            
            # Build summary
            $summaries += [PSCustomObject]@{
                From = "$($match.DisplayName) &lt;$senderSmtp&gt;"
                Subject = $subject
                Class = $class
                Status = 'Sent OK'
                Filed = if ($filed -eq 'co-workers') { 'Kusto\Co-Workers OK' } else { 'left in Inbox - Co-Workers folder not found' }
                Preamble = $preamble.Substring(0, [Math]::Min(200, $preamble.Length))
                Reply = $bodyHtml
                Todo = $todoPtId
            }
            
            $processedCount++
        } else {
            Write-Output "[WhatIf] Would send reply and move to Co-Workers"
        }
        
    } catch {
        Write-Output "ERROR processing item: $_"
        continue
    }
}

# Send summary email(s)
if ($summaries.Count -gt 0 -and -not $WhatIf) {
    Write-Output "`nSending summary emails..."
    
    foreach ($s in $summaries) {
        $summaryMail = $ol.CreateItem(0)  # olMailItem
        $summaryMail.To = $mgrEmail
        $summaryMail.Subject = "$subjectPrefix Auto-reply sent: $($s.Subject)"
        
        $todoLine = if ($s.Todo) { "<p><b>Added to your todo list:</b> $($s.Todo) (reports\personal-todos\todos.md)</p>" } else { '' }
        $summaryBody = "<p><b>From:</b> $($s.From)</p>" + `
            "<p><b>Subject:</b> $($s.Subject)</p>" + `
            "<p><b>What they asked:</b></p>" + `
            "<blockquote style='border-left:3px solid #ccc;padding-left:10px;color:#666;'>$($s.Preamble)</blockquote>" + `
            "<p><b>Classification:</b> $($s.Class)</p>" + `
            $todoLine + `
            "<p><b>What I replied:</b></p>" + `
            "<blockquote style='border-left:3px solid #ccc;padding-left:10px;'>$($s.Reply)</blockquote>" + `
            "<p><b>Status:</b> $($s.Status)</p>" + `
            "<p><b>Filed to:</b> $($s.Filed)</p>"
        
        $summaryMail.HTMLBody = $summaryBody
        if (Test-MigrationMode) {
            Write-Output "  [migration-mode] Skipping summary.Send() for: $($s.Subject)"
        } else {
            $summaryMail.Send()
        }
    }
    
    Write-Output "✅ Sent $($summaries.Count) summary email(s)"
}

Write-Output "`n✓ inbox-watch complete: $processedCount items processed"

