#Requires -Version 5.1
<#
.SYNOPSIS
    plus-nirvana runner - acts on Nir's Sent Items where he tagged a reply with the literal "+Nirvana" token.

.DESCRIPTION
    See .copilot/skills/plus-nirvana/SKILL.md for the full spec.

    Picks up tagged Sent replies, sends a polite ack ReplyAll on Nir's behalf,
    creates a PT-NNN in personal-todos, references it inline, ends with a joke,
    and stamps the Sent item idempotently.

.PARAMETER DryRun
    Build everything except sending the ack mail and adding the PT-NNN. Prints what would happen.

.PARAMETER WhatIf
    Alias for DryRun semantics around side effects.

.PARAMETER EntryID
    Process a single Sent item by Outlook EntryID instead of scanning the 7-day window.

.PARAMETER Force
    Ignore the NirvanaPlusProcessed idempotency stamp and re-fire.
#>

param(
    [switch]$DryRun,
    [switch]$WhatIf,
    [string]$EntryID,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')
. (Join-Path $PSScriptRoot '_shared\signature.ps1')
. (Join-Path $PSScriptRoot '_shared\migration-mode.ps1')

$cfg          = $AgentConfig
$mgrFirst     = Get-AgentField -Path 'manager.first_name'         -Default 'Nir'                      -Config $cfg
$agentName    = Get-AgentField -Path 'agent.name'                 -Default 'Nirvana'                  -Config $cfg
$pythonExe    = Get-AgentField -Path 'paths.python_exe'           -Default 'python'                   -Config $cfg
$reportsRoot  = Resolve-AgentPath (Get-AgentField -Path 'paths.reports_root' -Default 'reports' -Config $cfg) -Config $cfg
$idemTag      = 'NirvanaPlusProcessed'
$pattern      = '(?i)\+nirvana\b'

$todosFile    = Join-Path $reportsRoot 'personal-todos\todos.md'
$addItemPy    = Join-Path $PSScriptRoot 'personal-todos\add-item.py'

$logDate      = (Get-Date).ToString('yyyy-MM-dd')
$logPath      = Join-Path $reportsRoot ("plus-nirvana\{0}.md" -f $logDate)
New-Item -ItemType Directory -Force -Path (Split-Path $logPath -Parent) | Out-Null

$dry = ($DryRun.IsPresent -or $WhatIf.IsPresent)

# --- Preflight ---
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isElevated) {
    Write-Output "ABORT: PowerShell is elevated; Outlook COM will fail. Relaunch as a standard user."
    exit 1
}
if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    Write-Output "Outlook is not running. Skipping plus-nirvana run."
    exit 0
}

# --- Helpers ---

function Get-RecipientSmtp {
    param($Recipient)
    $smtp = ''
    try {
        $ae = $Recipient.AddressEntry
        $exUser = $ae.GetExchangeUser()
        if ($exUser) { $smtp = $exUser.PrimarySmtpAddress }
    } catch {}
    if (-not $smtp) {
        try {
            $smtp = $Recipient.PropertyAccessor.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x39FE001E')
        } catch {}
    }
    if (-not $smtp) { return '' }
    return $smtp.ToString().ToLower()
}

function Resolve-SentRecipients {
    param($Item)
    $to = @(); $cc = @()
    foreach ($r in $Item.Recipients) {
        $smtp = Get-RecipientSmtp -Recipient $r
        $entry = [pscustomobject]@{ Name = [string]$r.Name; Smtp = $smtp; Type = $r.Type }
        if     ($r.Type -eq 1) { $to += $entry }
        elseif ($r.Type -eq 2) { $cc += $entry }
    }
    return @{ To = $to; Cc = $cc }
}

function Get-FirstName {
    param([string]$DisplayName, [string]$SmtpAddress)
    if ($DisplayName) {
        $tok = ($DisplayName -split '[ ,]')[0]
        if ($tok) { $tok = $tok.Trim() }
        if ($tok) { return $tok }
    }
    if ($SmtpAddress -and ($SmtpAddress -match '^([^@\.]+)')) {
        $a = $matches[1]
        return ($a.Substring(0,1).ToUpper() + $a.Substring(1))
    }
    return 'there'
}

function Clean-Subject {
    param([string]$Subject)
    $s = [string]$Subject
    if (-not $s) { return '' }
    $s = $s -replace '^\s*(?i)(re|fwd|fw)\s*:\s*', ''
    $s = $s -replace '(?i)\+nirvana\b', ''
    $s = ($s -replace '\s+', ' ').Trim()
    return $s
}

function Get-RandomJoke {
    param([string]$PtId)
    $bank = @(
        'I asked a CDN for an inbox-zero strategy; it cached the question and ignored the prompt.',
        'Why did the auto-reply join the gym? To work on its delivery times.',
        "Outlook tried to flag this as 'low priority'; I flagged Outlook as 'low context'.",
        ("If a thread has a +Nirvana but no PT, did it really happen? (Yes -- here it is: {0}.)" -f $PtId)
    )
    if ($PtId -eq 'PT-UNKNOWN') {
        # Avoid the self-referential joke when the PT lookup failed -- it would read as a bug.
        $bank = $bank[0..2]
    }
    return ($bank | Get-Random)
}

function Test-PlusNirvanaTrigger {
    param($Item)
    $subj = [string]$Item.Subject
    if ($subj -match $pattern) { return $true }
    $body = [string]$Item.Body
    if (-not $body) { return $false }
    # Nir's intentional tag lives at the very top of his reply, before Outlook's
    # quoted-history separator. Once we send our own ack, the resulting Sent item
    # carries "+Nirvana" only deep in the quoted history -- ignore those, else
    # the scheduled task would loop on its own outputs.
    $head = $body.Substring(0, [Math]::Min(200, $body.Length))
    return ($head -match $pattern)
}

function Add-PtItem {
    param([string]$Title, [string]$Notes)
    if ($dry) {
        Write-Host "  [dry-run] would add todo: $Title"
        return 'PT-DRYRUN'
    }
    $pyArgs = @($addItemPy,
        '--todos-file', $todosFile,
        '--title', $Title,
        '--category', 'work',
        '--priority', 'M',
        '--due', '-',
        '--notes', $Notes)
    try {
        $output = & $pythonExe @pyArgs 2>&1
        $output | ForEach-Object { Write-Host ("  py> {0}" -f $_) }
        $first = ($output | Where-Object { $_ -match '^PT-\d{3}\b' } | Select-Object -First 1)
        if ($first) {
            $id = ($first -split "`t")[0].Trim()
            if ($id -match '^PT-\d{3}$') { return $id }
        }
        Write-Host ("  WARN: could not parse PT-NNN from add-item.py output: {0}" -f ($output -join '|'))
        return 'PT-UNKNOWN'
    } catch {
        Write-Host ("  WARN: add-item.py failed: {0}" -f $_.Exception.Message)
        return 'PT-UNKNOWN'
    }
}

# --- Find candidates ---

$ol   = New-Object -ComObject Outlook.Application
$ns   = $ol.GetNamespace('MAPI')
$sent = $ns.GetDefaultFolder(5)   # olFolderSentMail

$candidates = New-Object System.Collections.Generic.List[object]

if ($EntryID) {
    try {
        $candidates.Add($ns.GetItemFromID($EntryID))
        Write-Output ("Targeting single Sent item by EntryID.")
    } catch {
        Write-Output ("ERROR: failed to get item by EntryID: {0}" -f $_.Exception.Message)
        exit 1
    }
} else {
    $items = $sent.Items
    $items.Sort('[SentOn]', $true)
    $cutoff = (Get-Date).AddDays(-7)
    $inspected = 0
    foreach ($m in $items) {
        $inspected++
        if ($inspected -gt 200) { break }
        try {
            if ($m.Class -ne 43) { continue }
            if ($m.SentOn -lt $cutoff) { break }
            if (Test-PlusNirvanaTrigger -Item $m) {
                $candidates.Add($m)
            }
        } catch {}
    }
    Write-Output ("Scanned {0} recent Sent item(s); {1} carry the +Nirvana token." -f $inspected, $candidates.Count)
}

# --- Process candidates ---

$processed = 0; $skipped = 0
foreach ($m in $candidates) {
    $subj = [string]$m.Subject

    # Idempotency check
    $alreadyStamped = $false
    try {
        $existing = $m.UserProperties.Find($idemTag)
        if ($existing) { $alreadyStamped = $true }
    } catch {}
    if ($alreadyStamped -and -not $Force.IsPresent) {
        Write-Output ("SKIP (already-processed): {0}" -f $subj)
        $skipped++; continue
    }

    $audience = Resolve-SentRecipients -Item $m
    if (-not $audience.To -or $audience.To.Count -eq 0) {
        Write-Output ("SKIP (no-to-recipient): {0}" -f $subj)
        $skipped++; continue
    }

    # Audience guardrail: every recipient must be @microsoft.com
    $bad = @()
    foreach ($r in @($audience.To + $audience.Cc)) {
        if (-not $r.Smtp -or ($r.Smtp -notlike '*@microsoft.com')) { $bad += $r }
    }
    if ($bad.Count -gt 0) {
        $names = ($bad | ForEach-Object { if ($_.Smtp) { $_.Smtp } else { ('?:' + $_.Name) } }) -join ','
        Write-Output ("SKIP (non-microsoft-or-unresolved-recipient): {0} | bad={1}" -f $subj, $names)
        $skipped++; continue
    }

    $primary = $audience.To[0]
    $firstName = Get-FirstName -DisplayName $primary.Name -SmtpAddress $primary.Smtp
    $cleanSubj = Clean-Subject -Subject $subj
    if (-not $cleanSubj) { $cleanSubj = '(no subject)' }

    $sentOnStr = $m.SentOn.ToString('yyyy-MM-dd HH:mm')
    $ptTitle = ("Follow up with {0} on: {1}" -f $firstName, $cleanSubj)
    if ($ptTitle.Length -gt 140) { $ptTitle = $ptTitle.Substring(0,137).TrimEnd() + '...' }
    $ptNotes = ("Tagged via +Nirvana in {0}'s Sent reply at {1}. Recipient: {2} <{3}>." -f $mgrFirst, $sentOnStr, $primary.Name, $primary.Smtp)

    $ptId = Add-PtItem -Title $ptTitle -Notes $ptNotes

    $joke = Get-RandomJoke -PtId $ptId

    $bodyHtml = @"
<p>Hi $firstName,</p>
<p>Thanks &mdash; $mgrFirst and I will pick this up together and circle back. Tracking it on our side as <strong>$ptId</strong>.</p>
<p><em>$joke</em></p>
<p>&mdash; $agentName</p>
"@
    $bodyHtml += (Get-NirvanaSignature -Variant InboxAuto)

    Write-Output ""
    Write-Output "=== ITEM ==="
    Write-Output ("Subject: {0}" -f $subj)
    Write-Output ("Audience: to=[{0}] cc=[{1}]" -f (($audience.To | ForEach-Object { $_.Smtp }) -join ','), (($audience.Cc | ForEach-Object { $_.Smtp }) -join ','))
    Write-Output ("Primary: {0} <{1}>" -f $primary.Name, $primary.Smtp)
    Write-Output ("PT:      {0}" -f $ptId)

    if ($dry) {
        Write-Output "[dry-run] Skipping ReplyAll.Send() and idempotency stamp."
        $processed++; continue
    }
    if (Test-MigrationMode) {
        Write-Output "[migration-mode] Skipping ReplyAll.Send() and PT-NNN write."
        $processed++; continue
    }

    $reply = $m.ReplyAll()
    $reply.HTMLBody = $bodyHtml + $reply.HTMLBody
    $reply.Send()

    # Stamp the Sent item
    try {
        $up = $m.UserProperties.Add($idemTag, 1, $false)
        $up.Value = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        $m.Save()
    } catch {
        Write-Output ("  WARN: failed to stamp idempotency property: {0}" -f $_.Exception.Message)
    }

    # Log
    $ccCsv = ($audience.Cc | ForEach-Object { $_.Smtp }) -join ','
    $line = "- {0} sent=`"{1}`" to={2} cc={3} pt={4} subject=`"{5}`"" -f (Get-Date -Format 'HH:mm'), $sentOnStr, $primary.Smtp, $ccCsv, $ptId, $cleanSubj
    Add-Content -Path $logPath -Value $line -Encoding UTF8

    Write-Output ("SENT: ReplyAll to {0} | {1}" -f $primary.Smtp, $ptId)
    $processed++
}

Write-Output ""
Write-Output ("Done. processed={0} skipped={1} candidates={2} dry={3} force={4}" -f $processed, $skipped, $candidates.Count, $dry, $Force.IsPresent)

try {
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sent) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ns)   | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ol)   | Out-Null
} catch {}
