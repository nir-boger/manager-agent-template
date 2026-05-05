# Imports Cowork's daily summary JSON into the team-personas skill.
#
# Source: C:\Users\youralias\OneDrive\YourAgent\DailySummary\DailySummary_<YYYY-MM-DD>.{json,md}
#
# Two JSON shapes are supported (auto-detected after parse):
#
#   1. Markdown-wrapper shape (legacy):
#      { "date": "YYYY-MM-DD", "owner": "Your Name", "format": "markdown",
#        "content": "<markdown blob with ## By Person section>" }
#      The markdown's "## By Person" section has "### <Name> - <Title>" blocks,
#      one per person.
#
#   2. Structured shape (new, produced by some Copilot daily-capture flows):
#      { "date": "...", "owner": "...", "totals": {...}, "top_themes": [...],
#        "urgent_action_items": [...], "teams_activity": {...},
#        "people": [
#          { "name": "...", "email": "...", "role": "...",
#            "actions": [...], "topics": [...], "action_items": [...] },
#          ...
#        ],
#        "devops_prs": [...] }
#      The runner synthesizes the same { Heading; BodyLines } entries the
#      legacy markdown path produces, so the alias/observation/append pipeline
#      stays identical.
#
# This runner:
#   - parses each per-person entry,
#   - skips bots / automation / distribution lists / Nir himself,
#   - resolves the alias (kebab-case firstname-lastname),
#   - appends a "(daily)" observation to:
#       * people/<alias>.md  ## Daily observations    (if the direct persona exists)
#       * contacts/<alias>.md ## Recent interactions  (otherwise; creates the file from the
#         lightweight template in team-personas/SKILL.md when missing)
#   - extracts best-effort behavioral signals for directs and tags them "(behavioral, daily)",
#   - marks the date as processed in daily-summary-state.txt,
#   - logs to reports/logs/daily-summary-import-<YYYY-MM-DD>.log,
#   - appends a one-line summary to sources.txt.
#
# Manual run:  powershell -File <repo>\.copilot\skills\run-daily-summary-import.ps1
# Scheduled by:  DM-DailySummaryImport (daily 00:00, every 10 min for 24h).
# Idempotent — daily-summary-state.txt prevents reprocessing the same date.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$personasSkill = Join-Path $AgentRoot '.copilot\skills\team-personas'
$peopleDir     = Resolve-AgentPath (Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $AgentConfig) -Config $AgentConfig
$contactsDir   = Join-Path $personasSkill 'contacts'
$sourcesFile   = Join-Path $personasSkill 'sources.txt'
$stateFile     = Join-Path $personasSkill 'daily-summary-state.txt'
$summaryRoot   = Join-Path $env:USERPROFILE 'OneDrive\YourAgent\DailySummary'

New-Item -ItemType Directory -Force -Path $contactsDir | Out-Null
$logFile = Join-Path $LogDir ("daily-summary-import-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Helpers --------------------------------------------------------------

# Convert "Vincent-Philippe Lauzon" -> "vincent-philippe-lauzon"
function ConvertTo-Alias {
    param([string]$DisplayName)
    if (-not $DisplayName) { return $null }
    $s = $DisplayName.Trim()
    # Strip trailing parenthetical metadata if any.
    $s = [regex]::Replace($s, '\s*\([^)]*\)\s*$', '')
    # Replace any whitespace run with a single dash.
    $s = [regex]::Replace($s, '\s+', '-')
    # Lowercase.
    $s = $s.ToLowerInvariant()
    # Drop anything that's not a-z 0-9 dash.
    $s = [regex]::Replace($s, '[^a-z0-9\-]', '')
    # Collapse multiple dashes.
    $s = [regex]::Replace($s, '-+', '-')
    $s = $s.Trim('-')
    if (-not $s) { return $null }
    return $s
}

# Names / patterns we never want to treat as a person.
$botPatterns = @(
    'kopsmi', 'gitops', 'microsoft security', 'azure user access review',
    'incident automation', 'auto-restart', 'auto restart', 'workflows',
    '\(bot\)', 'service accounts?', 'azure devops automation', 'automation \('
)

function Test-IsBot {
    param([string]$Heading)
    $h = $Heading.ToLowerInvariant()
    foreach ($p in $botPatterns) { if ($h -match $p) { return $true } }
    # If the heading literally contains "(direct report)" we keep it; otherwise still allow.
    return $false
}

function Get-MdSection {
    param([string]$Content, [string]$Heading)
    if (-not $Content) { return $null }
    $escaped = [regex]::Escape($Heading)
    $pattern = "(?ms)^##\s+$escaped\s*\r?\n(.*?)(?=^##\s|\Z)"
    $m = [regex]::Match($Content, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.TrimEnd("`r","`n"," ","`t") }
    return $null
}

# Extract the "## By Person" block from the daily-summary markdown.
function Get-ByPersonBlock {
    param([string]$Markdown)
    return Get-MdSection -Content $Markdown -Heading 'By Person'
}

# Split a "By Person" block into per-person entries.
# Returns array of [pscustomobject]@{ Heading; Body }
function Split-PersonEntries {
    param([string]$ByPersonBlock)
    if (-not $ByPersonBlock) { return @() }
    $lines = $ByPersonBlock -split "`r?`n"
    $entries = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($l in $lines) {
        if ($l -match '^###\s+(.+?)\s*$') {
            if ($current) { [void]$entries.Add($current) }
            $current = [pscustomobject]@{ Heading = $Matches[1]; BodyLines = @() }
        }
        elseif ($current) {
            $current.BodyLines += $l
        }
    }
    if ($current) { [void]$entries.Add($current) }
    return $entries
}

# Convert the structured-shape "people" array into the same { Heading; BodyLines }
# entries Split-PersonEntries produces, so the rest of the pipeline (Test-IsBot,
# Parse-PersonHeading, ConvertTo-Alias, Build-DailyObservation, behavioral signals,
# Append-ToSection) works without modification.
#
# Pre-filters here cover ground the markdown shape never had to: in the "## By
# Person" world the upstream summarizer never emitted a heading for an automated
# system or for Nir himself. The structured schema does, so we drop them up front.
function ConvertFrom-StructuredJsonPeople {
    param($Obj)
    $entries = New-Object System.Collections.ArrayList
    if (-not $Obj) { return @() }
    $peopleProp = $Obj.PSObject.Properties['people']
    if (-not $peopleProp -or -not $peopleProp.Value) { return @() }
    $people = @($peopleProp.Value)
    foreach ($p in $people) {
        if (-not $p) { continue }
        $name = if ($p.PSObject.Properties['name']) { ([string]$p.name).Trim() } else { '' }
        if (-not $name) { continue }
        $email = if ($p.PSObject.Properties['email']) { ([string]$p.email).Trim() } else { '' }
        # Drop automated systems and Nir himself - the markdown shape never surfaced these.
        if ($email -ieq 'automated') { continue }
        if ($email -ieq 'you@example.com') { continue }
        $role = if ($p.PSObject.Properties['role']) { ([string]$p.role).Trim() } else { '' }
        $heading = if ($role) { "$name - $role" } else { $name }

        $body = New-Object System.Collections.ArrayList
        # Synthesize a "Discussion topic:" line from topics[0] so Build-DailyObservation
        # picks it up first (matches the legacy preference order: topic > bullet).
        if ($p.PSObject.Properties['topics'] -and $p.topics) {
            foreach ($t in @($p.topics)) {
                if ($t -is [string] -and $t.Trim()) {
                    [void]$body.Add('Discussion topic: ' + $t.Trim())
                    break
                }
            }
        }
        if ($p.PSObject.Properties['actions'] -and $p.actions) {
            foreach ($a in @($p.actions)) {
                if ($a -is [string] -and $a.Trim()) { [void]$body.Add('- ' + $a.Trim()) }
            }
        }
        if ($p.PSObject.Properties['action_items'] -and $p.action_items) {
            foreach ($ai in @($p.action_items)) {
                if ($ai -is [string] -and $ai.Trim()) { [void]$body.Add('- Action item: ' + $ai.Trim()) }
            }
        }
        if ($body.Count -eq 0) { continue }
        [void]$entries.Add([pscustomobject]@{ Heading = $heading; BodyLines = $body.ToArray() })
    }
    return $entries.ToArray()
}

# Pull the display name out of a heading like "Vincent-Philippe Lauzon - Microsoft (Senior SDE)"
# (with em-dash or hyphen). Returns @{ Name; Role }.
function Parse-PersonHeading {
    param([string]$Heading)
    $h = $Heading.Trim()
    # Em-dash, en-dash, or " - " separator between name and role/org.
    $sep = [regex]::Match($h, '\s+[\u2014\u2013\-]\s+')
    if ($sep.Success) {
        $name = $h.Substring(0, $sep.Index).Trim()
        $role = $h.Substring($sep.Index + $sep.Length).Trim()
    }
    else {
        $name = $h
        $role = ''
    }
    return [pscustomobject]@{ Name = $name; Role = $role }
}

# Build a one-line neutral observation from the per-person body. Prefers the
# "Discussion topic:" line, then the first substantive bullet.
function Build-DailyObservation {
    param([string[]]$BodyLines, [string]$Role)
    $body = ($BodyLines -join "`n").Trim()
    if (-not $body) { return $null }

    # Prefer "Discussion topic:" line.
    $topic = [regex]::Match($body, '(?im)^\s*Discussion topic:\s*(.+?)\s*$')
    if ($topic.Success) {
        $line = $topic.Groups[1].Value.Trim()
        # Truncate to a single sentence-ish, max ~220 chars.
        if ($line.Length -gt 220) { $line = $line.Substring(0, 217) + '...' }
        return $line
    }

    # Fallback: first bullet.
    $bullet = [regex]::Match($body, '(?m)^\s*-\s*(.+?)\s*$')
    if ($bullet.Success) {
        $line = $bullet.Groups[1].Value.Trim()
        if ($line.Length -gt 220) { $line = $line.Substring(0, 217) + '...' }
        return $line
    }

    # Last resort: first non-empty line.
    foreach ($l in $BodyLines) {
        $t = $l.Trim()
        if ($t -and $t -notmatch '^Channel:') {
            if ($t.Length -gt 220) { $t = $t.Substring(0, 217) + '...' }
            return $t
        }
    }
    return $null
}

# Best-effort behavioral signals for directs only. Returns an array of strings
# (each will be appended as a "(behavioral, daily)" line). Intentionally narrow
# - we'd rather miss signal than fabricate it.
function Build-BehavioralSignals {
    param([string[]]$BodyLines)
    $body = ($BodyLines -join "`n")
    $signals = New-Object System.Collections.ArrayList

    # Channel preferences ("Preference: phone calls beat Teams ...").
    $m = [regex]::Match($body, '(?im)^\s*[\-\*]?\s*Preference:\s*(.+?)\s*$')
    if ($m.Success) { [void]$signals.Add('Channel preference: ' + $m.Groups[1].Value.Trim()) }

    # Stated position / position-of-record ("Position: ...", "Plan of record: ...").
    $m = [regex]::Match($body, '(?im)^\s*[\-\*]?\s*Position:\s*(.+?)\s*$')
    if ($m.Success) { [void]$signals.Add('Stated position: ' + $m.Groups[1].Value.Trim()) }

    # Asked-for-pushback / decisive-but-open patterns.
    if ($body -match '(?i)asked\s+(?:nir\s+boger\s+)?to\s+push\s+back\s+if\s+(?:he|they)\s+disagrees') {
        [void]$signals.Add('Open to pushback: explicitly invited Nir to disagree on a stated plan')
    }

    # Friday / weekend boundary discipline.
    if ($body -match "(?i)Sorry to bother you on a Friday|wait until Sunday|won't merit a hotfix|not\s+a\s+hotfix") {
        [void]$signals.Add('Boundary discipline: declined weekend hotfix path; deferred to next working day')
    }

    return ,$signals.ToArray()
}

# Append a line to a markdown section, creating the section if missing.
function Append-ToSection {
    param([string]$FilePath, [string]$Heading, [string]$Line)
    $content = Get-Content $FilePath -Raw -Encoding UTF8
    $escaped = [regex]::Escape($Heading)
    $pattern = "(?ms)^(##\s+$escaped\s*\r?\n)(.*?)(?=^##\s|\Z)"
    $m = [regex]::Match($content, $pattern)
    if ($m.Success) {
        $body = $m.Groups[2].Value.TrimEnd("`r","`n"," ","`t")
        # Idempotency: skip exact-duplicate line.
        if ($body -split "`r?`n" -contains $Line) { return $false }
        $newBody = if ($body) { $body + "`r`n" + $Line + "`r`n`r`n" } else { $Line + "`r`n`r`n" }
        $newContent = $content.Substring(0, $m.Index) + $m.Groups[1].Value + $newBody + $content.Substring($m.Index + $m.Length)
        Set-Content -Path $FilePath -Value $newContent -Encoding UTF8 -NoNewline:$false
        return $true
    }
    else {
        # Section missing - append at end of file.
        $append = "`r`n## $Heading`r`n$Line`r`n"
        Add-Content -Path $FilePath -Value $append -Encoding UTF8
        return $true
    }
}

# Build a brand-new contacts/<alias>.md from the contact template.
function New-ContactFile {
    param([string]$FilePath, [string]$DisplayName, [string]$Alias, [string]$Role, [string]$Date)
    $relationship = if ($Role -match '(?i)customer|external|LTIMINDTREE|Centific') { 'external / customer' }
                    elseif ($Role -match '(?i)direct report')                       { 'direct report'        }
                    elseif ($Role -match '(?i)Microsoft')                            { 'Microsoft (non-direct)' }
                    else                                                             { 'unknown' }

    $template = @"
# $DisplayName ($Alias)

- **Role / org:** $Role
- **Relationship to Nir:** $relationship
- **First seen:** $Date
- **Last seen:** $Date
- **Last refreshed:** $Date

## Snapshot
<2-4 lines: who they are, why they show up in Nir's world, what they tend to interact on>

## Recent interactions

## Notes
"@
    Set-Content -Path $FilePath -Value $template -Encoding UTF8 -NoNewline:$false
}

# Update "Last seen" header in an existing contact file.
function Update-ContactLastSeen {
    param([string]$FilePath, [string]$Date)
    $content = Get-Content $FilePath -Raw -Encoding UTF8
    $content = [regex]::Replace($content, '(?m)^- \*\*Last seen:\*\*\s*.*$', "- **Last seen:** $Date")
    Set-Content -Path $FilePath -Value $content -Encoding UTF8 -NoNewline:$false
}

# --- Main -----------------------------------------------------------------

if (-not (Test-Path $summaryRoot)) {
    Write-Log "DailySummary root missing: $summaryRoot - nothing to do."
    exit 0
}

$processed = @{}
if (Test-Path $stateFile) {
    foreach ($l in Get-Content $stateFile -Encoding UTF8) {
        $t = $l.Trim()
        if ($t -and $t -notmatch '^#') { $processed[$t] = $true }
    }
}

# Sweep already-processed orphans first. Cowork sometimes saves the daily
# summary as DailySummary_<date>.md (single-key JSON envelope with the same
# .content field). The post-ingest cleanup only fires when the .json triggers
# the main loop, so a stranded .md whose date is already in state would
# otherwise sit forever. Catch them here regardless of which extension landed.
$orphanCandidates = @(Get-ChildItem $summaryRoot -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^DailySummary_(\d{4}-\d{2}-\d{2})\.(json|md)$' })
foreach ($o in $orphanCandidates) {
    $od = ([regex]::Match($o.Name, 'DailySummary_(\d{4}-\d{2}-\d{2})\.')).Groups[1].Value
    if ($processed.ContainsKey($od)) {
        try {
            Remove-Item $o.FullName -Force
            Write-Log "Swept orphan $($o.Name) (date $od already in state)."
        }
        catch {
            Write-Log "WARN: could not sweep orphan $($o.Name): $($_.Exception.Message)"
        }
    }
}

$srcFiles = @(Get-ChildItem $summaryRoot -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^DailySummary_\d{4}-\d{2}-\d{2}\.(json|md)$' } |
              Sort-Object Name)

if (-not $srcFiles) {
    Write-Log "No DailySummary_*.{json,md} files found in $summaryRoot."
    exit 0
}

# Cross-file aggregates for the end-of-run summary email.
$runAgg = [pscustomobject]@{
    DatesProcessed   = New-Object System.Collections.ArrayList
    DatesSkipped     = New-Object System.Collections.ArrayList
    DatesErrored     = New-Object System.Collections.ArrayList
    Directs          = 0
    Contacts         = 0
    ContactsCreated  = 0
    Behavioral       = 0
    Bots             = 0
    Skipped          = 0
    DirectsTouched   = New-Object System.Collections.Generic.HashSet[string]
    ContactsTouched  = New-Object System.Collections.Generic.HashSet[string]
    NewContacts      = New-Object System.Collections.Generic.HashSet[string]
}

foreach ($f in $srcFiles) {
    $dateMatch = [regex]::Match($f.Name, 'DailySummary_(\d{4}-\d{2}-\d{2})\.(json|md)')
    if (-not $dateMatch.Success) { Write-Log "Skip $($f.Name): unrecognized name."; continue }
    $date = $dateMatch.Groups[1].Value

    if ($processed.ContainsKey($date)) {
        Write-Log "Skip $($f.Name): already processed."
        [void]$runAgg.DatesSkipped.Add($date)
        # Cleanup: file slipped past prior cleanup (e.g. earlier inline ingest, or runner crash).
        # State already records the date, so it's safe to delete the stranded source now.
        try {
            Remove-Item $f.FullName -Force
            Write-Log "  Deleted stranded source $($f.FullName) (was already in state)."
        }
        catch {
            Write-Log "  WARN: could not delete stranded source: $($_.Exception.Message)"
        }
        $companionMd = Join-Path $summaryRoot ("DailySummary_" + $date + ".md")
        if (Test-Path $companionMd) {
            try { Remove-Item $companionMd -Force; Write-Log "  Deleted stranded companion $companionMd." }
            catch { Write-Log "  WARN: could not delete stranded companion .md: $($_.Exception.Message)" }
        }
        continue
    }

    Write-Log "Processing $($f.FullName) (date=$date)"

    try {
        $obj = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Log "  ERROR parsing JSON: $($_.Exception.Message)"
        [void]$runAgg.DatesErrored.Add($date)
        continue
    }

    $md = $obj.content
    $entries = $null
    if ($md -is [string] -and $md.Length -gt 0) {
        # Legacy markdown-wrapper shape: parse "## By Person".
        $byPerson = Get-ByPersonBlock -Markdown $md
        if (-not $byPerson) {
            Write-Log "  ERROR: no '## By Person' section in 'content' markdown. Not marking processed."
            [void]$runAgg.DatesErrored.Add($date)
            continue
        }
        $entries = Split-PersonEntries -ByPersonBlock $byPerson
        Write-Log ("  Found " + $entries.Count + " person entries (markdown shape).")
    }
    else {
        $hasPeople = ($obj.PSObject.Properties['people'] -and (@($obj.people).Count -gt 0))
        if ($hasPeople) {
            # New structured shape: walk obj.people[] directly.
            $entries = ConvertFrom-StructuredJsonPeople -Obj $obj
            Write-Log ("  Found " + $entries.Count + " person entries (structured shape).")
        }
        else {
            Write-Log "  ERROR: file has neither 'content' (markdown wrapper) nor 'people' (structured) - unknown schema. Not marking processed."
            [void]$runAgg.DatesErrored.Add($date)
            continue
        }
    }

    $stats = [pscustomobject]@{
        Directs = 0; Contacts = 0; ContactsCreated = 0; Bots = 0; Skipped = 0; Behavioral = 0
    }

    foreach ($e in $entries) {
        if (Test-IsBot $e.Heading) { $stats.Bots++; continue }

        $parsed = Parse-PersonHeading $e.Heading
        $alias = ConvertTo-Alias $parsed.Name
        if (-not $alias) { $stats.Skipped++; Write-Log "  Skip (no alias): $($e.Heading)"; continue }

        $obs = Build-DailyObservation -BodyLines $e.BodyLines -Role $parsed.Role
        if (-not $obs) { $stats.Skipped++; Write-Log "  Skip (no observation): $alias"; continue }

        $obsLine = "- $date (daily): $obs [src: DailySummary_$date.json]"

        $directPath  = Join-Path $peopleDir   ($alias + '.md')
        $contactPath = Join-Path $contactsDir ($alias + '.md')

        if (Test-Path $directPath) {
            $appended = Append-ToSection -FilePath $directPath -Heading 'Daily observations' -Line $obsLine
            if ($appended) { $stats.Directs++; Write-Log "  direct ${alias}: appended" }
            else            { Write-Log "  direct ${alias}: duplicate, skipped" }
            [void]$runAgg.DirectsTouched.Add($parsed.Name)

            $signals = Build-BehavioralSignals -BodyLines $e.BodyLines
            foreach ($sig in $signals) {
                $sigLine = "- $date (behavioral, daily): $sig [src: DailySummary_$date.json]"
                if (Append-ToSection -FilePath $directPath -Heading 'Daily observations' -Line $sigLine) {
                    $stats.Behavioral++
                    Write-Log "  direct ${alias}: behavioral signal appended"
                }
            }
        }
        else {
            $createdNew = $false
            if (-not (Test-Path $contactPath)) {
                New-ContactFile -FilePath $contactPath -DisplayName $parsed.Name -Alias $alias -Role $parsed.Role -Date $date
                $stats.ContactsCreated++
                $createdNew = $true
                [void]$runAgg.NewContacts.Add($parsed.Name)
                Write-Log "  contact ${alias}: created"
            }
            else {
                Update-ContactLastSeen -FilePath $contactPath -Date $date
            }
            $appended = Append-ToSection -FilePath $contactPath -Heading 'Recent interactions' -Line $obsLine
            if ($appended -or $createdNew) { $stats.Contacts++; Write-Log "  contact ${alias}: appended" }
            [void]$runAgg.ContactsTouched.Add($parsed.Name)
        }
    }

    Write-Log ("  Summary: directs={0} contacts={1} created={2} behavioral={3} bots={4} skipped={5}" -f `
        $stats.Directs, $stats.Contacts, $stats.ContactsCreated, $stats.Behavioral, $stats.Bots, $stats.Skipped)

    # Roll into the per-run aggregate.
    $runAgg.Directs         += $stats.Directs
    $runAgg.Contacts        += $stats.Contacts
    $runAgg.ContactsCreated += $stats.ContactsCreated
    $runAgg.Behavioral      += $stats.Behavioral
    $runAgg.Bots            += $stats.Bots
    $runAgg.Skipped         += $stats.Skipped
    [void]$runAgg.DatesProcessed.Add($date)

    Add-Content -Path $stateFile -Encoding UTF8 -Value $date

    $logEntry = '# {0} ingested DailySummary_{1}.json - directs={2} contacts={3} created={4} behavioral={5} bots={6}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm'), $date, $stats.Directs, $stats.Contacts, $stats.ContactsCreated, $stats.Behavioral, $stats.Bots
    Add-Content -Path $sourcesFile -Encoding UTF8 -Value $logEntry

    # Cleanup: delete the source JSON and companion .md stub now that we've persisted
    # everything we need. State file keeps the date as a belt-and-suspenders idempotency
    # guard in case the file ever reappears.
    try {
        Remove-Item $f.FullName -Force
        Write-Log "  Deleted source $($f.FullName)."
    }
    catch {
        Write-Log "  WARN: could not delete source JSON: $($_.Exception.Message)"
    }
    $companionMd = Join-Path $summaryRoot ("DailySummary_" + $date + ".md")
    if (Test-Path $companionMd) {
        try {
            Remove-Item $companionMd -Force
            Write-Log "  Deleted companion $companionMd."
        }
        catch {
            Write-Log "  WARN: could not delete companion .md: $($_.Exception.Message)"
        }
    }
}

Write-Log "Done."

# --- End-of-run summary email ---------------------------------------------
. (Join-Path $PSScriptRoot '_runner-email.ps1')

$datesDone = @($runAgg.DatesProcessed)
$datesSkip = @($runAgg.DatesSkipped)
$datesErr  = @($runAgg.DatesErrored)

$subjectSuffix = if ($datesDone.Count -gt 0) {
    "$($datesDone -join ', ') - directs=$($runAgg.Directs), contacts=$($runAgg.Contacts) ($($runAgg.ContactsCreated) new), behavioral=$($runAgg.Behavioral)"
}
elseif ($datesErr.Count -gt 0)  { "ERRORS on $($datesErr -join ', ')" }
elseif ($datesSkip.Count -gt 0) { "no new files (already-processed: $($datesSkip -join ', '))" }
else                            { "no work today" }

$bodyParts = New-Object System.Collections.ArrayList

if ($datesDone.Count -gt 0) {
    [void]$bodyParts.Add("<p><b>Processed:</b> $($datesDone -join ', ')</p>")
    [void]$bodyParts.Add("<ul>" +
        "<li><b>Directs touched:</b> $($runAgg.Directs) observation(s) across $($runAgg.DirectsTouched.Count) " +
        "person(s)" + $(if ($runAgg.DirectsTouched.Count) { " &mdash; " + (($runAgg.DirectsTouched | Sort-Object) -join ', ') } else { '' }) + "</li>" +
        "<li><b>Behavioral signals (directs):</b> $($runAgg.Behavioral)</li>" +
        "<li><b>Contacts touched:</b> $($runAgg.Contacts) interaction(s) across $($runAgg.ContactsTouched.Count) person(s); " +
        "<b>$($runAgg.ContactsCreated) new</b>" + $(if ($runAgg.NewContacts.Count) { " (" + (($runAgg.NewContacts | Sort-Object) -join ', ') + ")" } else { '' }) + "</li>" +
        "<li><b>Bots filtered:</b> $($runAgg.Bots)</li>" +
        "<li><b>Other skips:</b> $($runAgg.Skipped)</li>" +
    "</ul>")
}
if ($datesErr.Count -gt 0) {
    [void]$bodyParts.Add("<p style='color:#b00'><b>Errors on:</b> $($datesErr -join ', ') &mdash; check the log; nothing was marked processed for these.</p>")
}
if ($datesDone.Count -eq 0 -and $datesErr.Count -eq 0) {
    [void]$bodyParts.Add("<p>No new daily summaries to ingest.</p>")
}

[void]$bodyParts.Add("<p style='color:#888;font-size:12px'>Log: <code>$logFile</code></p>")

$jokes = @(
    "If a daily summary lands in OneDrive and no one ingests it, did your team really work yesterday?",
    "Persona enrichment, now with extra Kool-aid (K for Kusto, of course).",
    "Today's behavioral signal: yours truly *did* the dishes. Allegedly.",
    "Contacts: now lighter than your average ICM postmortem.",
    "Filed under 'Sapir abandoned a PR': the most Sapir thing on the timeline."
)

$bodyHtml = ($bodyParts -join "`n")

[void](Send-RunnerSummaryEmail `
    -RunnerName 'DM-DailySummaryImport' `
    -SubjectSuffix $subjectSuffix `
    -BodyHtml $bodyHtml `
    -JokePool $jokes)

