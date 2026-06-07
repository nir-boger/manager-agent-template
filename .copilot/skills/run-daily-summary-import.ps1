# Imports the daily summary file into the team-personas skill.
#
# Source: <agent-root>\reports\daily-capture\published\daily-summary\DailySummary_<YYYY-MM-DD>.{json,md}
#         (local handoff from run-daily-capture.ps1; configurable via
#          paths.daily_capture_summary in config/agent.json)
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

$personasSkill  = Join-Path $AgentRoot '.copilot\skills\team-personas'
$peopleDir      = Resolve-AgentPath (Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $AgentConfig) -Config $AgentConfig
$contactsDir    = Join-Path $personasSkill 'contacts'
$sourcesFile    = Join-Path $personasSkill 'sources.txt'
$stateFile      = Join-Path $personasSkill 'daily-summary-state.txt'
$emptyStateFile = Join-Path $personasSkill 'daily-summary-empty-state.txt'
$summaryRoot    = Resolve-AgentPath (Get-AgentField -Path 'paths.daily_capture_summary' -Default 'reports/daily-capture/published/daily-summary' -Config $AgentConfig) -Config $AgentConfig

New-Item -ItemType Directory -Force -Path $contactsDir | Out-Null
$logFile = Join-Path $LogDir ("daily-summary-import-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Helpers --------------------------------------------------------------

# Convert "Your VP" -> "your-vp"
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

# Extract the "By Person" block from the daily-summary markdown. The summarizer
# has used at least two heading variants for this section over time:
#   - "## By Person"
#   - "## Activity by Person"
# Both produce the same downstream shape (### Name subheadings + body bullets),
# so we accept either. Returns the body text of the first matching section.
function Get-ByPersonBlock {
    param([string]$Markdown)
    foreach ($h in @('By Person', 'Activity by Person')) {
        $section = Get-MdSection -Content $Markdown -Heading $h
        if ($section) { return $section }
    }
    return $null
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

# Convert the newer "communications" shape into the same { Heading; BodyLines } entries.
# Shape (per the 2026-05-19 drop and later):
#   { "communications": [
#       { "person": "Teammate1 (someone@example.com, Senior SWE, direct report)",
#         "channel": "Teams", "time_utc": "2026-05-19T11:21Z",
#         "subject": "...", "summary": "...", "action": "..." },
#       { "person": "Azure DevOps Notifications (on behalf of Teammate67)", ... },
#       { "person": "Nirvana Agent (automated)", ... }
#   ] }
# - Unwraps "X (on behalf of Y)" so Y is the credited person.
# - Drops automated/bot/notification-only rows.
# - Splits the "(<email>, <role>, ...)" parenthetical into Name + Role so the
#   legacy Parse-PersonHeading / ConvertTo-Alias / role-based contact-classification
#   pipeline works without modification.
function ConvertFrom-CommunicationsJson {
    param($Obj)
    $entries = New-Object System.Collections.ArrayList
    if (-not $Obj) { return @() }
    $prop = $Obj.PSObject.Properties['communications']
    if (-not $prop -or -not $prop.Value) { return @() }

    foreach ($c in @($prop.Value)) {
        if (-not $c) { continue }

        $personRaw = ''
        foreach ($field in @('person', 'from', 'name')) {
            if ($c.PSObject.Properties[$field] -and $c.$field) {
                $personRaw = ([string]$c.$field).Trim()
                if ($personRaw) { break }
            }
        }
        if (-not $personRaw) { continue }

        # Unwrap "Azure DevOps Notifications (on behalf of <RealName>)" -> "<RealName>".
        $obo = [regex]::Match($personRaw, '(?i)on\s+behalf\s+of\s+(.+?)\s*\)\s*$')
        if ($obo.Success) { $personRaw = $obo.Groups[1].Value.Trim() }

        # Drop self, automated systems, and notification senders.
        if ($personRaw -match '(?i)\((?:bot|automated|automation|noreply|no-reply)\)') { continue }
        if ($personRaw -imatch '^Your Name\b')      { continue }
        if ($personRaw -imatch '^Nirvana Agent\b')  { continue }
        if ($personRaw -imatch '^Nirvana \(') { continue }
        # Bare "X Notifications" / "X Notification" / "X Bot" with no on-behalf hint.
        if (-not $obo.Success -and $personRaw -imatch '\b(?:Notifications?|Bot)\b') { continue }

        # Split "Teammate1 (someone@example.com, Senior SWE, direct report)"
        # into Name = "Teammate1", Role = "Senior SWE, direct report".
        $nameClean = $personRaw
        $role      = ''
        $par = [regex]::Match($personRaw, '^(.+?)\s*\(([^)]+)\)\s*$')
        if ($par.Success) {
            $nameClean = $par.Groups[1].Value.Trim()
            $bits = @()
            foreach ($p in ($par.Groups[2].Value -split ',')) {
                $pt = $p.Trim()
                if (-not $pt) { continue }
                if ($pt -match '^[^@\s]+@[^@\s]+$') { continue }  # skip the email part
                $bits += $pt
            }
            $role = ($bits -join ', ')
        }
        if (-not $nameClean) { continue }

        $heading = if ($role) { "$nameClean - $role" } else { $nameClean }

        $body = New-Object System.Collections.ArrayList
        $summary = if ($c.PSObject.Properties['summary']) { ([string]$c.summary).Trim() } else { '' }
        $subject = if ($c.PSObject.Properties['subject']) { ([string]$c.subject).Trim() } else { '' }
        $action  = if ($c.PSObject.Properties['action'])  { ([string]$c.action).Trim()  } else { '' }
        $channel = if ($c.PSObject.Properties['channel']) { ([string]$c.channel).Trim() } else { '' }
        $time    = if ($c.PSObject.Properties['time_utc']){ ([string]$c.time_utc).Trim() } else { '' }

        if ($summary) {
            $line = if ($subject) { "$subject -- $summary" } else { $summary }
            [void]$body.Add('Discussion topic: ' + $line)
        }
        elseif ($subject) {
            [void]$body.Add('Discussion topic: ' + $subject)
        }
        # "None"/"Completed" actions carry no follow-up signal.
        if ($action -and $action -inotmatch '^(?:None|Completed|N/A|\-)\b') {
            [void]$body.Add('- Action item: ' + $action)
        }
        if ($channel -or $time) {
            $tag = @($channel, $time | Where-Object { $_ }) -join ' @ '
            [void]$body.Add('- ' + $tag)
        }
        if ($body.Count -eq 0) { continue }

        [void]$entries.Add([pscustomobject]@{ Heading = $heading; BodyLines = $body.ToArray() })
    }
    return $entries.ToArray()
}

# Generic last-resort fallback for forward-compat with future Cowork schemas.
# Scans top-level properties for an array of objects that look person-shaped
# (has a "name-ish" field AND a "body-ish" field on most entries). The highest-
# scoring array wins. Catches drift like 'interactions[]', 'messages[]',
# 'activities[]', 'items[]' without needing a code change for each.
function ConvertFrom-GenericPersonArrayJson {
    param($Obj)
    if (-not $Obj) { return @() }

    $nameFields = @('person','name','display_name','displayname','from','who','user','author','speaker','sender')
    $bodyFields = @('summary','description','body','message','content','text','notes','note','topic','action','action_item','detail','observation')

    $bestProp  = $null
    $bestScore = 0.0
    foreach ($prop in $Obj.PSObject.Properties) {
        # Only top-level arrays of objects qualify.
        $val = $prop.Value
        if ($null -eq $val) { continue }
        $arr = @($val)
        if ($arr.Count -eq 0) { continue }

        $total = 0; $named = 0; $bodied = 0
        foreach ($item in $arr) {
            if ($null -eq $item) { continue }
            # Strings / primitives don't qualify as person records.
            if ($item -is [string] -or $item -is [int] -or $item -is [bool] -or $item -is [double]) { continue }
            if (-not $item.PSObject) { continue }
            $total++
            $hasName = $false
            foreach ($f in $nameFields) {
                if ($item.PSObject.Properties[$f] -and $item.$f) { $hasName = $true; break }
            }
            $hasBody = $false
            foreach ($f in $bodyFields) {
                if ($item.PSObject.Properties[$f] -and $item.$f) { $hasBody = $true; break }
            }
            if ($hasName) { $named++ }
            if ($hasBody) { $bodied++ }
        }
        if ($total -eq 0 -or $named -eq 0) { continue }
        # Score: average of (named-coverage, body-coverage), in 0..1.
        $score = (($named / $total) + ($bodied / $total)) / 2.0
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestProp  = $prop
        }
    }
    # Demand at least 50% of items have a name field AND something body-ish.
    if (-not $bestProp -or $bestScore -lt 0.5) { return @() }

    $entries = New-Object System.Collections.ArrayList
    foreach ($item in @($bestProp.Value)) {
        if ($null -eq $item -or $item -is [string]) { continue }
        if (-not $item.PSObject) { continue }

        $name = $null
        foreach ($f in $nameFields) {
            if ($item.PSObject.Properties[$f] -and $item.$f) {
                $v = ([string]$item.$f).Trim()
                if ($v) { $name = $v; break }
            }
        }
        if (-not $name) { continue }

        # Skip obvious bots/automations - generic shape sees more noise than
        # the curated shapes.
        if ($name -imatch '^(?:Your Name|Nirvana Agent)\b') { continue }
        if ($name -match '(?i)\((?:bot|automated|automation|noreply|no-reply)\)') { continue }

        $body = $null
        foreach ($f in $bodyFields) {
            if ($item.PSObject.Properties[$f] -and $item.$f) {
                $v = ([string]$item.$f).Trim()
                if ($v) { $body = $v; break }
            }
        }
        if (-not $body) { continue }

        [void]$entries.Add([pscustomobject]@{
            Heading   = $name
            BodyLines = @('Discussion topic: ' + $body)
        })
    }
    return $entries.ToArray()
}

# Flatten every string value in a JSON object graph into a synthetic markdown
# blob (one bullet per non-trivial string), so theme-mode name-matching can
# fire even when the file has none of the per-person shapes. This is the
# absolute last resort before declaring "unknown schema" - if a future Cowork
# JSON drift still mentions a real persona name in ANY string field, we'll
# pick it up here.
function ConvertTo-FlattenedThemeMarkdown {
    param($Obj)
    if ($null -eq $Obj) { return $null }

    $lines = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($Obj)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }
        if ($node -is [string]) {
            $t = $node.Trim()
            if ($t.Length -ge 10) { [void]$lines.Add('- ' + $t) }
            continue
        }
        if ($node -is [bool] -or $node -is [int] -or $node -is [double] -or $node -is [decimal]) { continue }
        if ($node -is [PSCustomObject]) {
            foreach ($p in $node.PSObject.Properties) { $stack.Push($p.Value) }
            continue
        }
        if ($node -is [System.Collections.IEnumerable]) {
            foreach ($i in $node) { $stack.Push($i) }
            continue
        }
    }
    if ($lines.Count -eq 0) { return $null }
    return "## Synthesized themes`n" + ($lines -join "`n")
}

# Return the comma-joined list of top-level property names on $Obj, for
# error reporting when no shape matches. Quick visual diagnostic in the
# alert email - "ah, Cowork started emitting 'interactions' instead of
# 'communications', I need a converter".
function Get-JsonTopLevelKeys {
    param($Obj)
    if ($null -eq $Obj -or -not $Obj.PSObject) { return '' }
    $names = @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
    # Empty parsed object - Cowork upload-in-flight scaffolding (literal '{}').
    # Return a printable sentinel so log lines read "keys: (empty)" instead of
    # the un-readable "keys: ." See Test-IsCoworkUploadStub for the matching
    # quiet-skip rule (added 2026-05-28 after Cowork dropped a literal '{}'
    # file as DailySummary_2026-05-28.md, SHA-256 prefix 44136fa3...).
    if ($names.Count -eq 0) { return '(empty)' }
    return ($names -join ', ')
}

# Pull the display name out of a heading like "Your VP - Microsoft (Senior SDE)"
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

    # Bold-key bullet form, e.g.
    #   **PRs completed today:** PR 15637723 ...
    #   **Teams (group chat, 15:14-15:15 UTC):** Briefed Nir ...
    # Some keys are noise (Role, Email to Nir = just a meeting invite line);
    # rank by signal density: prefer keys that mention concrete work, then
    # fall back to the first non-Role bold-key line.
    $boldKeyMatches = [regex]::Matches($body, '(?im)^\s*\*\*([^*:]+?):\*\*\s*(.+?)\s*$')
    if ($boldKeyMatches.Count -gt 0) {
        $preferred = @('PRs completed', 'PR ', 'Active PR', 'Teams', 'Email to', 'Bug', 'Incident')
        $picked = $null
        foreach ($p in $preferred) {
            foreach ($m in $boldKeyMatches) {
                $key = $m.Groups[1].Value.Trim()
                if ($key -ieq 'Role') { continue }
                if ($key -like "$p*") { $picked = $m; break }
            }
            if ($picked) { break }
        }
        if (-not $picked) {
            foreach ($m in $boldKeyMatches) {
                if (($m.Groups[1].Value.Trim()) -ine 'Role') { $picked = $m; break }
            }
        }
        if ($picked) {
            $line = ('**' + $picked.Groups[1].Value.Trim() + ':** ' + $picked.Groups[2].Value.Trim())
            if ($line.Length -gt 220) { $line = $line.Substring(0, 217) + '...' }
            return $line
        }
    }

    # Fallback: first real bullet (skip markdown horizontal-rule separators
    # like '---' that the upstream summarizer puts between person sections).
    $bulletMatches = [regex]::Matches($body, '(?m)^\s*-\s*(.+?)\s*$')
    foreach ($m in $bulletMatches) {
        $line = $m.Groups[1].Value.Trim()
        if (-not $line) { continue }
        if ($line -match '^-+$') { continue }
        if ($line.Length -gt 220) { $line = $line.Substring(0, 217) + '...' }
        return $line
    }

    # Last resort: first non-empty, non-rule line.
    foreach ($l in $BodyLines) {
        $t = $l.Trim()
        if (-not $t) { continue }
        if ($t -match '^-{3,}$') { continue }
        if ($t -match '^Channel:') { continue }
        if ($t.Length -gt 220) { $t = $t.Substring(0, 217) + '...' }
        return $t
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

# === Helpers for theme-mode (shape #3) ===
#
# Theme-mode is the looser fallback used when Cowork drops a daily summary that
# is markdown-shaped but has no '## By Person' section AND no structured
# 'people: []' array. Instead of giving up (and re-emailing every 10 min), we
# scan the body for mentions of personas and contacts already on disk and
# synthesize { Heading; BodyLines; Alias } entries the same shape the legacy
# paths produce, so the rest of the pipeline (Append-ToSection / contact
# update) works without modification.
#
# Conservative on purpose:
#   - Only matches names already in people/ or contacts/. We do NOT auto-create
#     new contacts from theme bullets - capitalized phrases like "Mise V2",
#     "Kazzle MCP", or customer org names could be mistaken for people.
#   - Skips Build-BehavioralSignals - theme bodies are third-person synthesized
#     prose, not raw evidence; the persona skill's "evidence-anchored" philosophy
#     should not be diluted by heuristic guesses on synthesized text.

# Convert "Teammate1-Teammate1" -> "Teammate1". Used as a display-name candidate when
# parsing a persona file's first heading is ambiguous.
function ConvertFrom-Alias {
    param([string]$Alias)
    if (-not $Alias) { return $null }
    $parts = $Alias -split '-'
    $titled = foreach ($p in $parts) {
        if ($p) {
            $p.Substring(0,1).ToUpperInvariant() + $p.Substring(1).ToLowerInvariant()
        }
    }
    return ($titled -join ' ')
}

# Extract candidate display names from a persona/contact file, robustly across
# the heading variants currently in use:
#   '# Working-Style Persona: Teammate1'
#   '# Teammate4 - Working-Style Persona'
#   '# Teammate2 - Persona'
#   '# Teammate11 - Working Persona'
#   '# Teammate23 (arnaud-flutre)'
# Plus: '**Subject:** <Name> (<email>), <role>' line in body.
function Get-DisplayNamesFromPersonaFile {
    param([string]$Alias, [string]$FilePath)
    $names = New-Object System.Collections.ArrayList

    # Title-cased alias as a baseline (handles your-vp style hyphenation).
    $titled = ConvertFrom-Alias $Alias
    if ($titled) { [void]$names.Add($titled) }

    if (-not (Test-Path $FilePath)) { return @($names | Select-Object -Unique) }
    $content = Get-Content $FilePath -Raw -Encoding UTF8
    if (-not $content) { return @($names | Select-Object -Unique) }
    # Normalize common cp1252 -> UTF-8 mojibake sequences. Some persona files were
    # edited through tools that double-encoded em-dash / curly quotes; without this
    # the heading suffix-strip and Subject-line parsers fail and we end up with
    # corrupted names like 'Teammate2 â€" Persona' in the index.
    $content = $content `
        -replace ([char]0x00E2 + [char]0x20AC + [char]0x201D), [char]0x2014 `
        -replace ([char]0x00E2 + [char]0x20AC + [char]0x009D), [char]0x2014 `
        -replace ([char]0x00E2 + [char]0x20AC + [char]0x0093), [char]0x2013 `
        -replace ([char]0x00E2 + [char]0x20AC + [char]0x2122), [char]0x2019

    # Strategy: parse first '# ' heading.
    $hMatch = [regex]::Match($content, '(?m)^#\s+(.+?)\s*$')
    if ($hMatch.Success) {
        $h = $hMatch.Groups[1].Value
        $h = [regex]::Replace($h, '\s*\([^)]*\)\s*$', '')
        $h = [regex]::Replace($h, '^\s*(?:Working[- ]Style\s+Persona|Working\s+Persona|Persona)\s*:\s*', '', 'IgnoreCase')
        # Suffix separator may be em-dash, en-dash, hyphen, or mojibake-corrupted
        # bytes (e.g. UTF-8 em-dash re-encoded through cp1252 then back yields the
        # 3-char sequence "â€"). Match any run of non-ASCII-word, non-space chars
        # as the separator. Note: \w in .NET regex matches Unicode letters by
        # default, so we use the explicit ASCII class.
        $h = [regex]::Replace($h, '\s+[^A-Za-z0-9_\s]+\s*(?:Working[- ]Style\s+Persona|Working\s+Persona|Persona|Software\s+Engineer(?:\s+\w+)?|Senior\s+Software\s+Engineer)\s*$', '', 'IgnoreCase')
        $h = $h.Trim()
        if ($h) { [void]$names.Add($h) }
    }

    # Strategy: '**Subject:** <Name> (<email>)' line. The capture truncates at the
    # first '(' to drop the email; any role tail after a comma OR em/en-dash is
    # also dropped (some files use 'Name - Role' format in the Subject line).
    $sMatch = [regex]::Match($content, '(?m)^\*\*Subject:\*\*\s+([^(\r\n]+?)\s*(?:\([^)]+\))?\s*$')
    if ($sMatch.Success) {
        $subj = $sMatch.Groups[1].Value.Trim()
        $subj = [regex]::Replace($subj, '\s*[\u2014\u2013\-]\s+.*$', '').Trim()
        $subj = [regex]::Replace($subj, ',.*$', '').Trim()
        if ($subj) { [void]$names.Add($subj) }
    }

    return @($names | Select-Object -Unique)
}

# Build display-name -> { Alias; IsDirect } index from team-personas/people/ + /contacts/.
# people/ is loaded first so directs win on display-name collisions.
function Get-PersonNameIndex {
    param([string]$PeopleDir, [string]$ContactsDir)
    $idx = @{}
    foreach ($entry in @(
        @{ Dir = $PeopleDir;   IsDirect = $true  },
        @{ Dir = $ContactsDir; IsDirect = $false }
    )) {
        if (-not (Test-Path $entry.Dir)) { continue }
        Get-ChildItem $entry.Dir -Filter *.md -ErrorAction SilentlyContinue | ForEach-Object {
            $alias = $_.BaseName
            $names = Get-DisplayNamesFromPersonaFile -Alias $alias -FilePath $_.FullName
            foreach ($n in $names) {
                if (-not $n) { continue }
                if (-not $idx.ContainsKey($n)) {
                    $idx[$n] = [pscustomobject]@{ Alias = $alias; IsDirect = $entry.IsDirect }
                }
            }
        }
    }
    return $idx
}

# Find name mentions of indexed display names in a markdown body. For each match,
# extract a context snippet (table cell, bullet line, or sentence) and dedupe.
# Returns hashtable: alias -> { Alias; DisplayName; IsDirect; Snippets[] }.
function Get-NameMentions {
    param([string]$Markdown, [hashtable]$NameIndex)
    $results = @{}
    if (-not $Markdown -or $NameIndex.Count -eq 0) { return $results }

    $lines = $Markdown -split "`r?`n"

    foreach ($displayName in $NameIndex.Keys) {
        $meta = $NameIndex[$displayName]
        # Custom Unicode-aware boundary so the boundary is honest about non-ASCII
        # letters and avoids matching inside a longer token.
        $pattern = '(?i)(?<![\p{L}\p{N}])' + [regex]::Escape($displayName) + '(?![\p{L}\p{N}])'

        $snippets = New-Object System.Collections.ArrayList
        foreach ($line in $lines) {
            if (-not $line) { continue }
            if ($line -notmatch $pattern) { continue }

            $snippet = $null
            if ($line -match '^\s*\|') {
                # Table row: extract the cell containing the match.
                $cells = $line -split '\|'
                foreach ($c in $cells) {
                    $ct = $c.Trim()
                    if ($ct -and $ct -match $pattern) {
                        $snippet = $ct
                        break
                    }
                }
                # Skip table separator rows of dashes/colons.
                if ($snippet -and $snippet -match '^[\s\-:]+$') { $snippet = $null }
            }
            else {
                # Bullet, numbered list, paragraph: trim leading list markers.
                $snippet = $line.Trim()
                $snippet = [regex]::Replace($snippet, '^\s*(?:[-\*]|\d+\.)\s*', '')
                $snippet = $snippet.Trim()
            }

            if (-not $snippet) { continue }
            if ($snippet.Length -lt 10) { continue }
            if ($snippet.Length -gt 280) { $snippet = $snippet.Substring(0, 277) + '...' }
            if (-not $snippets.Contains($snippet)) { [void]$snippets.Add($snippet) }
        }

        if ($snippets.Count -gt 0) {
            $results[$meta.Alias] = [pscustomobject]@{
                Alias       = $meta.Alias
                DisplayName = $displayName
                IsDirect    = $meta.IsDirect
                Snippets    = $snippets.ToArray()
            }
        }
    }
    return $results
}

# Synthesize { Heading; BodyLines; Alias } entries from theme-mode mentions.
# Multiple snippets per person are folded into a single 'Discussion topic:' line
# so Build-DailyObservation persists them all - it returns only the first
# Discussion topic line, so subsequent bullets would otherwise be dropped.
function ConvertFrom-ThemeMarkdown {
    param([string]$Markdown, [hashtable]$NameIndex)
    $entries = New-Object System.Collections.ArrayList
    $mentions = Get-NameMentions -Markdown $Markdown -NameIndex $NameIndex
    foreach ($alias in ($mentions.Keys | Sort-Object)) {
        $m = $mentions[$alias]
        $primary = $m.Snippets | Sort-Object Length -Descending | Select-Object -First 1
        $extras  = @($m.Snippets | Where-Object { $_ -ne $primary })
        $combined = "Discussion topic: " + $primary
        if ($extras.Count -gt 0) {
            $extraText = ($extras -join '; ')
            if ($extraText.Length -gt 80) { $extraText = $extraText.Substring(0, 77) + '...' }
            $combined += " (also: $extraText)"
        }
        if ($combined.Length -gt 400) { $combined = $combined.Substring(0, 397) + '...' }
        [void]$entries.Add([pscustomobject]@{
            Heading   = $m.DisplayName
            BodyLines = @($combined)
            Alias     = $m.Alias
        })
    }
    return $entries.ToArray()
}

# SHA256 hex digest of a file's bytes - used for empty-hash suppression so a
# repeating zero-match drop for the same date doesn't re-email every 10 minutes.
function Get-FileContentHash {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

# Detect Cowork's various "no real summary attached yet" upload stubs so we can
# quiet-skip them instead of emailing an ERROR every run. Known shapes:
#   { "__file_upload__": true, "local_path": "..." }    - Cowork's own placeholder
#   { "@microsoft.graph.conflictBehavior": "replace" }   - Graph upload policy only
#   { "@odata.type": "#microsoft.graph.driveItem",
#     "content": "placeholder" }                         - Graph driveItem envelope
#   { "@odata.type": "#microsoft.graph.driveItem",
#     "content": "# test" }                              - Graph driveItem envelope
#                                                          carrying upload-test
#                                                          scaffolding instead
#                                                          of a real summary
#                                                          (added 2026-05-26)
#   {}                                                   - literal empty JSON object,
#                                                          Cowork upload-in-flight
#                                                          scaffolding. SHA-256
#                                                          prefix 44136fa3..., seen
#                                                          in the wild on
#                                                          2026-05-28 when Cowork
#                                                          briefly landed a 2-byte
#                                                          '{}' file as
#                                                          DailySummary_2026-05-28.md
#                                                          before replacing it 10
#                                                          min later with the real
#                                                          summary (added 2026-05-28)
# Returns $true when the parsed JSON object looks like upload-tool scaffolding
# rather than a real summary. The empty-state dedup at the bottom of the no-
# schema branch covers any future stub shape we miss here on the first sighting,
# but explicit detection means we don't even log it as ERROR. The function is
# conservative: a 'content' string is treated as real signal whenever it
# carries any '## ' or '### ' heading (the markers every real summary shape
# uses to anchor per-person sections) OR is longer than the scaffolding-grade
# threshold below. Anything that fails BOTH checks (no heading AND short) is
# upload-test scaffolding -- the actual real-world DailySummary files seen in
# May 2026 range from ~3KB to ~12KB and always contain at least one '## '
# heading, so the 256-char threshold has a wide safety margin.
function Test-IsCoworkUploadStub {
    param($Obj)
    if (-not $Obj) { return $false }
    if ($Obj -is [System.Array]) { return $false }
    if (-not ($Obj.PSObject -and $Obj.PSObject.Properties)) { return $false }

    if ($Obj.PSObject.Properties['__file_upload__'] -and $Obj.__file_upload__) { return $true }

    $names = @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
    # Empty parsed object ('{}') -- Cowork upload-in-flight scaffolding.
    # Carries zero signal by construction; treat as a quiet-skip stub so the
    # 10-min retry can pick up the real content on the next tick instead of
    # emailing an ERROR. See the function header comment for the 2026-05-28
    # incident this fix originated from.
    if ($names.Count -eq 0) { return $true }

    $hasGraphKey = $false
    foreach ($n in $names) { if ($n -like '@*') { $hasGraphKey = $true; break } }
    if (-not $hasGraphKey) { return $false }

    $allGraph = $true
    foreach ($n in $names) { if ($n -notlike '@*') { $allGraph = $false; break } }
    if ($allGraph) { return $true }

    # Graph metadata + a small set of driveItem-shaped sibling fields that
    # carry no per-person signal. 'content' is allowed when it's empty,
    # whitespace, the literal 'placeholder' (case-insensitive), or short
    # scaffolding-grade content with no '## ' / '### ' heading (test
    # markers like '# test', '# placeholder', 'hello world', etc. -- see
    # the function header for the heuristic rationale).
    $allowList = @('name','size','id','webUrl','eTag','cTag','localPath','local_path','filename','path')
    foreach ($n in $names) {
        if ($n -like '@*') { continue }
        if ($n -in $allowList) { continue }
        if ($n -ieq 'content') {
            $v = $Obj.$n
            if ($null -eq $v) { continue }
            if ($v -isnot [string]) { return $false }
            $t = $v.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t -ieq 'placeholder') { continue }
            if ($t.Length -lt 256 -and $t -notmatch '(?m)^##\s' -and $t -notmatch '(?m)^###\s') { continue }
            return $false
        }
        return $false
    }
    return $true
}

# Quiet-skip companion: detects Cowork sentinel / pointer documents that
# explicitly say "the real content is in the companion email" or carry only
# upload-control fields. These ship under DailySummary_<date>.{json,md} names
# but carry zero per-person signal, so we must not raise the "unknown JSON
# shape" error -- otherwise every 10-min tick emails Nir about a file Cowork
# never intended to be ingested.
#
# Returns $true (quiet-skip) when any of these signals matches AND no
# substantive content field carries real data:
#
#   1. ANY top-level property name starts with '_' (Cowork's sentinel-doc
#      convention -- _doc_type, _date, _owner, _note, _schema, etc.).
#   2. A known "look in the email" / "look in the sandbox" pointer key is
#      present:
#      see_email, markdown_url_in_email, markdown_url, markdown_location,
#      content_in_email, content_url, payload_url, attachment_email,
#      markdown_content_truncated_indicator, markdown_in_email, see_attachment,
#      file_path, source_path, local_file, sandbox_path, output_path
#      (the *_path family covers the 2026-05-27 Cowork sandbox-pointer shape
#      `{"file_path": "/mnt/workspace/output/DailySummary_<date>.md"}` and
#      its expected siblings -- pointers to an internal sandbox location
#      that's meaningless to downstream consumers).
#   3. The top-level key set is a non-empty subset of upload-control fields:
#      sourcePath, uploadAsRaw, contentType, encoding, mediaType, mimeType,
#      targetPath, destinationPath, charset.
#
# Substantive content (a non-empty 'people' / 'communications' array, or a
# real 'content' / 'markdown' string carrying actual data) overrides every
# pointer signal -- if the doc IS the real summary, never quiet-skip it.
function Test-IsCoworkPointerStub {
    param($Obj)
    if (-not $Obj) { return $false }
    if ($Obj -is [System.Array]) { return $false }
    if (-not ($Obj.PSObject -and $Obj.PSObject.Properties)) { return $false }
    $names = @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { return $false }

    # Substantive-content override: any real per-person field with real data
    # disqualifies the stub classification.
    foreach ($prop in $Obj.PSObject.Properties) {
        $n = $prop.Name
        $v = $prop.Value
        if ($null -eq $v) { continue }
        switch -regex ($n) {
            '^(people|communications|top_themes|urgent_action_items|devops_prs)$' {
                if ($v -is [System.Array] -and (@($v).Count -gt 0)) { return $false }
                continue
            }
            '^(content|markdown)$' {
                if ($v -is [string]) {
                    $t = $v.Trim()
                    if ($t.Length -gt 0 -and $t -ine 'placeholder') { return $false }
                }
                continue
            }
            '^teams_activity$' {
                if ($v -is [pscustomobject] -or $v -is [hashtable]) { return $false }
                continue
            }
        }
    }

    # Signal 1: any underscore-prefixed property name.
    foreach ($n in $names) { if ($n.StartsWith('_')) { return $true } }

    # Signal 2: explicit "look in the email" / "look in the sandbox" pointer key.
    $pointerKeys = @(
        'see_email','markdown_url_in_email','markdown_url','markdown_location',
        'content_in_email','content_url','payload_url','attachment_email',
        'markdown_content_truncated_indicator','markdown_in_email','see_attachment',
        # Sandbox/path pointers - Cowork's upstream agent emits these when its
        # upload finished writing the path manifest but the real file hadn't
        # landed yet. The retry on the next 10-min tick replaces the stub with
        # the real content; we just need to not raise an error on the first sighting.
        # First seen 2026-05-27 as {"file_path": "/mnt/workspace/output/DailySummary_2026-05-27.md"}.
        'file_path','source_path','local_file','sandbox_path','output_path'
    )
    foreach ($n in $names) {
        foreach ($pk in $pointerKeys) { if ($n -ieq $pk) { return $true } }
    }

    # Signal 2b: generic suffix-match for path/url/file/location/uri pointer keys.
    # Forward-compat for the next stub shape upstream invents (e.g.
    # `output_uri`, `payload_path`, `result_file`, `manifest_location`). Only
    # fires when EVERY non-graph, non-allow-list key matches one of these
    # suffixes AND its value is a non-empty string. Substantive-content
    # override above already prevents this from eating real summaries that
    # happen to carry an attribution `*_url` alongside real data. Originated
    # 2026-05-27 after the eighth distinct stub shape in 19 days; the explicit
    # list above catches today's `file_path` shape, this heuristic catches the
    # *next* one without a code change.
    $suffixSafeAllow = @('name','size','id','etag','ctag','filename','date','owner')
    $allPointerSuffix = $true
    foreach ($prop in $Obj.PSObject.Properties) {
        $n = $prop.Name
        if ($n -like '@*') { continue }
        if ($n.StartsWith('_')) { continue }
        $low = $n.ToLowerInvariant()
        if ($suffixSafeAllow -contains $low) { continue }
        if ($low -match '_(path|url|file|location|uri)$') {
            $v = $prop.Value
            if ($v -is [string] -and $v.Trim().Length -gt 0) { continue }
        }
        $allPointerSuffix = $false
        break
    }
    if ($allPointerSuffix) {
        # Require at least one suffix-matched key so we don't quiet-skip an
        # all-allow-list-only object (which the existing Signal-3 path covers).
        foreach ($n in $names) {
            $low = $n.ToLowerInvariant()
            if ($low -match '_(path|url|file|location|uri)$') { return $true }
        }
    }

    # Signal 3: upload-control subset (sourcePath/uploadAsRaw/contentType etc.).
    $uploadControl = @(
        'sourcePath','uploadAsRaw','contentType','encoding','mediaType',
        'mimeType','targetPath','destinationPath','charset'
    )
    $allCtrl = $true
    foreach ($n in $names) {
        $match = $false
        foreach ($u in $uploadControl) { if ($n -ieq $u) { $match = $true; break } }
        if (-not $match) { $allCtrl = $false; break }
    }
    if ($allCtrl) { return $true }

    return $false
}

# Quiet-skip companion for RAW MARKDOWN (.md) files that never parse as JSON,
# so Test-IsCoworkUploadStub / Test-IsCoworkPointerStub (which only run on a
# parsed $obj) never see them. Cowork occasionally lands a DailySummary_<date>.md
# that is a placeholder/pointer rather than the real summary:
#   - an empty / whitespace-only file (upload still in flight), or
#   - a title-only stub ("# Daily Summary 2026-05-28" and nothing else), or
#   - a "the real content is in the companion email" pointer.
# These carry zero per-person signal, so they must NOT raise the "unknown
# schema" ERROR -- otherwise every 10-min tick emails Nir about a file Cowork
# never meant to be ingested. The retry on the next tick replaces the stub with
# the real summary.
#
# Deliberately CONSERVATIVE so it can never swallow a real summary:
#   - Real DailySummary files are 3-12 KB and always carry at least one '## '
#     per-person heading, so the no-heading + <256-char rule has a wide margin.
#   - Returns $true only on (empty) OR (explicit pointer phrase) OR
#     (no '## '/'### ' heading AND short body once a leading H1 title is stripped).
# Originated 2026-05-28 when DailySummary_2026-05-28.md (a non-JSON markdown
# stub) hit the no-schema ERROR path and emailed Nir on every tick.
function Test-IsMarkdownStub {
    param($Text)
    if ($null -eq $Text) { return $false }
    if ($Text -isnot [string]) { $Text = [string]$Text }
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return $true }

    # Strip a single leading H1 title line so a "# Daily Summary <date>" header
    # plus a pointer body is judged on the body, not the boilerplate title.
    $body = ([regex]::Replace($t, '(?m)\A#\s+.*?$', '')).Trim()

    # Explicit "the real content lives elsewhere" pointer phrasing.
    $pointerPhrases = @(
        'companion email', 'in the email', 'see email', 'see the email',
        'see attachment', 'real content is', 'content is in the', 'content truncated',
        'truncated indicator', 'available in the companion', 'look in the email',
        'refer to the email', 'full summary in', 'see companion'
    )
    foreach ($p in $pointerPhrases) {
        if ($body -match [regex]::Escape($p)) { return $true }
    }

    # Near-empty scaffolding: no per-person heading and a short body.
    $hasHeading = ($body -match '(?m)^##\s') -or ($body -match '(?m)^###\s')
    if (-not $hasHeading -and $body.Length -lt 256) { return $true }

    return $false
}

# --- Main -----------------------------------------------------------------

# Test seam: tests dot-source this file to exercise helpers in isolation.
# When NIRVANA_TEST_DOTSOURCE=1 is set, return without running the main loop.
if ($env:NIRVANA_TEST_DOTSOURCE -eq '1') { return }

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
    # date -> mode (only for non-standard modes worth surfacing in the email).
    NonStandardMode  = [ordered]@{}
    # date -> top-level JSON keys snapshot (only when shape detection failed).
    ErroredKeys      = [ordered]@{}
    # Legacy alias still consumed by the email template - kept for back-compat
    # so old fixtures don't break. Populated alongside NonStandardMode below.
    ThemeModeDates   = New-Object System.Collections.ArrayList
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

    $obj = $null
    $rawText = $null
    $parseError = $null
    try {
        $rawText = Get-Content $f.FullName -Raw -Encoding UTF8
        $obj = $rawText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $parseError = $_.Exception.Message
        # Tolerate parse failure for .md files - they may be plain markdown without
        # a JSON envelope, in which case theme-mode below can still extract signal.
        if ($f.Extension -ne '.md') {
            Write-Log "  ERROR parsing JSON: $parseError"
            [void]$runAgg.DatesErrored.Add($date)
            continue
        }
        Write-Log "  Note: file is .md without JSON envelope; will try theme-mode on raw markdown."
    }

    # Stub-skip: Cowork occasionally lands an upload placeholder
    # ({"__file_upload__": true, "local_path": "..."},
    #  {"@microsoft.graph.conflictBehavior": "replace"},
    #  {"@odata.type": "#microsoft.graph.driveItem", "content": "placeholder"}, ...)
    # which carries no per-person signal. Treat as quiet skip - no error,
    # no email, no state mutation. The empty-state dedup at the bottom of
    # the no-schema branch covers any future stub shape we miss here on the
    # first sighting, but explicit detection means we don't even log it as
    # ERROR. See Test-IsCoworkUploadStub above for the full ruleset.
    if (Test-IsCoworkUploadStub -Obj $obj) {
        $stubKeys = Get-JsonTopLevelKeys -Obj $obj
        Write-Log "  Skip: upload stub (keys: $stubKeys). Not marking processed."
        continue
    }

    # Sentinel / pointer docs (Cowork Graph-API workaround that says "real
    # content is in the companion email"). Quiet-skip with no error email,
    # mirroring the upload-stub path. See Test-IsCoworkPointerStub for the
    # signal set: underscore-prefixed sentinel fields (_doc_type/_date/...),
    # explicit pointer keys (see_email, markdown_url_in_email, ...), or an
    # upload-control-only key set (sourcePath/uploadAsRaw/contentType).
    # Originated 2026-05-24 when three new shapes started landing in one day.
    if (Test-IsCoworkPointerStub -Obj $obj) {
        $stubKeys = Get-JsonTopLevelKeys -Obj $obj
        Write-Log "  Skip: pointer stub (keys: $stubKeys). Not marking processed."
        continue
    }

    $entries = $null
    $mode = $null

    # Shape #1: markdown-wrapper { content: '<md with ## By Person>' }.
    if ($obj -and $obj.PSObject.Properties['content'] -and $obj.content -is [string] -and $obj.content.Length -gt 0) {
        $byPerson = Get-ByPersonBlock -Markdown $obj.content
        if ($byPerson) {
            $entries = @(Split-PersonEntries -ByPersonBlock $byPerson)
            $mode = 'markdown'
            Write-Log ("  Found " + $entries.Count + " person entries (markdown shape).")
        }
    }

    # Shape #2: structured { people: [...] }.
    if ($null -eq $entries -and $obj -and $obj.PSObject.Properties['people'] -and (@($obj.people).Count -gt 0)) {
        $entries = @(ConvertFrom-StructuredJsonPeople -Obj $obj)
        $mode = 'structured'
        Write-Log ("  Found " + $entries.Count + " person entries (structured shape).")
    }

    # Shape #4: communications [...] (2026-05-19+ Cowork schema).
    if ($null -eq $entries -and $obj -and $obj.PSObject.Properties['communications']) {
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        if ($entries.Count -gt 0) {
            $mode = 'communications'
            Write-Log ("  Found " + $entries.Count + " person entries (communications shape).")
        } else {
            $entries = $null
        }
    }

    # Shape #5: generic person-shaped array (any top-level array of objects with
    # name+body fields, scored). Forward-compat catch for the next drift.
    if ($null -eq $entries -and $obj) {
        $entries = @(ConvertFrom-GenericPersonArrayJson -Obj $obj)
        if ($entries.Count -gt 0) {
            $mode = 'generic'
            Write-Log ("  Found " + $entries.Count + " person entries (generic-array fallback).")
        } else {
            $entries = $null
        }
    }

    # Shape #3: theme-mode (loose name-matching against existing personas + contacts)
    # on markdown-shaped text. Fires when neither legacy schema produced entries
    # AND we have markdown-shaped text to scan (either obj.content or a plain .md
    # file with headings).
    if ($null -eq $entries) {
        $themeBody = $null
        if ($obj -and $obj.PSObject.Properties['content'] -and $obj.content -is [string] -and $obj.content.Length -gt 0) {
            $themeBody = $obj.content
        }
        elseif ($rawText -and ($rawText -match '(?m)^##\s')) {
            $themeBody = $rawText
        }
        if ($themeBody) {
            $nameIdx = Get-PersonNameIndex -PeopleDir $peopleDir -ContactsDir $contactsDir
            $entries = @(ConvertFrom-ThemeMarkdown -Markdown $themeBody -NameIndex $nameIdx)
            if ($entries.Count -gt 0) {
                $mode = 'theme'
                Write-Log ("  Found " + $entries.Count + " person entries (theme-mode, " + $nameIdx.Count + " names indexed).")
            } else {
                $entries = $null
            }
        }
    }

    # Shape #6: flattened-JSON theme-mode. Absolute last resort - if the file
    # is JSON-shaped (so $obj exists) but none of the per-person shapes matched,
    # we collapse every string value in the object graph into a synthetic
    # markdown blob and run name-matching against the persona+contacts index.
    # Tagged 'flattened-theme' so the email surfaces this for review - the
    # source is even more synthesized than regular theme-mode.
    if ($null -eq $entries -and $obj) {
        $flat = ConvertTo-FlattenedThemeMarkdown -Obj $obj
        if ($flat) {
            $nameIdx2 = Get-PersonNameIndex -PeopleDir $peopleDir -ContactsDir $contactsDir
            $entries = @(ConvertFrom-ThemeMarkdown -Markdown $flat -NameIndex $nameIdx2)
            if ($entries.Count -gt 0) {
                $mode = 'flattened-theme'
                Write-Log ("  Found " + $entries.Count + " person entries (flattened-theme fallback, " + $nameIdx2.Count + " names indexed).")
            } else {
                $entries = $null
            }
        }
    }

    # Raw-markdown stub guard: a .md file that never parsed as JSON ($obj is
    # null) and looks like a placeholder/pointer (empty, title-only, or
    # "see companion email") is a quiet-skip, not an unknown-schema ERROR.
    # Tightly gated to non-JSON .md files so it can never suppress a genuinely
    # new JSON shape (those we still WANT to be alerted about).
    if ($null -eq $entries -and $null -eq $obj -and $f.Extension -ieq '.md' `
            -and $rawText -and (Test-IsMarkdownStub -Text $rawText)) {
        Write-Log "  Skip: markdown stub / pointer (.md with no per-person content). Not marking processed."
        continue
    }

    if ($null -eq $entries) {
        # No schema matched at all. Suppress repeat alerts for the same content via
        # daily-summary-empty-state.txt so the 10-min retry doesn't spam Nir.
        # Always log the top-level JSON keys so future drift is debuggable straight
        # from the error email - "ah, Cowork started emitting 'interactions' now,
        # add a converter for that".
        $hash = Get-FileContentHash -Path $f.FullName
        $shortHash = if ($hash.Length -ge 8) { $hash.Substring(0,8) } else { $hash }
        $emptyKey = "${date}::${hash}"
        $alreadyAlerted = $false
        if (Test-Path $emptyStateFile) {
            $alreadyAlerted = (Get-Content $emptyStateFile -Encoding UTF8 | Where-Object { $_ -eq $emptyKey } | Measure-Object).Count -gt 0
        }
        $topKeys = Get-JsonTopLevelKeys -Obj $obj
        $keysStr = if ($topKeys) { " top-level keys: $topKeys." } else { '' }
        if (-not $alreadyAlerted) {
            Add-Content -Path $emptyStateFile -Value $emptyKey -Encoding UTF8
            Write-Log "  ERROR: file matches no known schema (no 'content', no 'people', no 'communications', no generic person-array, no theme matches).${keysStr} hash=$shortHash. Not marking processed."
            [void]$runAgg.DatesErrored.Add($date)
            $runAgg.ErroredKeys[$date] = $topKeys
        } else {
            Write-Log "  Skip: same content as previous attempt for $date (hash=$shortHash) - alert suppressed.${keysStr}"
        }
        continue
    }

    # Tag observations by mode for honest provenance.
    #   markdown / structured / communications -> 'daily' (direct evidence)
    #   theme / flattened-theme / generic       -> 'daily, <mode>' (indirect / heuristic)
    # Behavioral signals only fire on the two evidence-anchored shapes, since
    # they're regex heuristics over raw upstream text.
    $obsTag = switch ($mode) {
        'theme'           { 'daily, theme' }
        'flattened-theme' { 'daily, flattened-theme' }
        'communications'  { 'daily' }
        'generic'         { 'daily, generic' }
        default           { 'daily' }
    }
    $isThemeLike  = ($mode -eq 'theme' -or $mode -eq 'flattened-theme')
    $runBehavioral = ($mode -eq 'markdown' -or $mode -eq 'structured')

    $stats = [pscustomobject]@{
        Directs = 0; Contacts = 0; ContactsCreated = 0; Bots = 0; Skipped = 0; Behavioral = 0
    }

    foreach ($e in $entries) {
        if (Test-IsBot $e.Heading) { $stats.Bots++; continue }

        $parsed = Parse-PersonHeading $e.Heading
        # Theme-mode entries carry an authoritative Alias from the index; legacy
        # paths derive it from the heading via ConvertTo-Alias.
        $alias = $null
        if ($e.PSObject.Properties['Alias'] -and $e.Alias) {
            $alias = $e.Alias
        } else {
            $alias = ConvertTo-Alias $parsed.Name
        }
        if (-not $alias) { $stats.Skipped++; Write-Log "  Skip (no alias): $($e.Heading)"; continue }

        $obs = Build-DailyObservation -BodyLines $e.BodyLines -Role $parsed.Role
        if (-not $obs) { $stats.Skipped++; Write-Log "  Skip (no observation): $alias"; continue }

        $obsLine = "- $date ($obsTag): $obs [src: DailySummary_$date.json]"

        $directPath  = Join-Path $peopleDir   ($alias + '.md')
        $contactPath = Join-Path $contactsDir ($alias + '.md')

        if (Test-Path $directPath) {
            $appended = Append-ToSection -FilePath $directPath -Heading 'Daily observations' -Line $obsLine
            if ($appended) { $stats.Directs++; Write-Log "  direct ${alias}: appended" }
            else            { Write-Log "  direct ${alias}: duplicate, skipped" }
            [void]$runAgg.DirectsTouched.Add($parsed.Name)

            # Behavioral signals are evidence-anchored heuristics on raw text;
            # only the markdown/structured shapes carry raw enough text. Theme,
            # flattened-theme, communications, and generic shapes are too
            # distilled - skip them to keep the persona skill's "evidence-
            # anchored" philosophy intact.
            if ($runBehavioral) {
                $signals = Build-BehavioralSignals -BodyLines $e.BodyLines
                foreach ($sig in $signals) {
                    $sigLine = "- $date (behavioral, daily): $sig [src: DailySummary_$date.json]"
                    if (Append-ToSection -FilePath $directPath -Heading 'Daily observations' -Line $sigLine) {
                        $stats.Behavioral++
                        Write-Log "  direct ${alias}: behavioral signal appended"
                    }
                }
            }
        }
        else {
            $createdNew = $false
            if (-not (Test-Path $contactPath)) {
                # Theme-mode and flattened-theme aliases come from the on-disk
                # index, so a missing contact file here means the index is stale
                # - skip rather than auto-create from noisy heuristic text.
                if ($isThemeLike) {
                    Write-Log "  WARN: $mode-mode alias '$alias' has no contact file (index out of sync?); skipping."
                    continue
                }
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
    if ($mode -and $mode -ne 'markdown' -and $mode -ne 'structured') {
        $runAgg.NonStandardMode[$date] = $mode
    }
    if ($mode -eq 'theme' -or $mode -eq 'flattened-theme') { [void]$runAgg.ThemeModeDates.Add($date) }

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

$datesDone  = @($runAgg.DatesProcessed)
$datesSkip  = @($runAgg.DatesSkipped)
$datesErr   = @($runAgg.DatesErrored)
$datesTheme = @($runAgg.ThemeModeDates)

# Quiet-run guard: when the runner did nothing observable -- no ingest, no
# errors, no already-processed skips -- suppress the end-of-run email entirely.
# This prevents the every-10-min schedule from spamming Nir with "no work today"
# heartbeats. Errors that have already been alerted (same date+hash) flow through
# this branch too, since the per-hash dedup at line ~744 skips DatesErrored.Add
# on repeat content -- so this guard is what makes the alert dedup useful.
if ($datesDone.Count -eq 0 -and $datesErr.Count -eq 0 -and $datesSkip.Count -eq 0) {
    Write-Log "Quiet run (no ingests, no errors, no skips) - suppressing end-of-run email."
    return
}

$subjectSuffix = if ($datesDone.Count -gt 0) {
    $core = "$($datesDone -join ', ') - directs=$($runAgg.Directs), contacts=$($runAgg.Contacts) ($($runAgg.ContactsCreated) new), behavioral=$($runAgg.Behavioral)"
    if ($runAgg.NonStandardMode.Count -gt 0) {
        $tags = @()
        foreach ($k in $runAgg.NonStandardMode.Keys) { $tags += ($k + '=' + $runAgg.NonStandardMode[$k]) }
        $core += ' (modes: ' + ($tags -join ', ') + ')'
    }
    $core
}
elseif ($datesErr.Count -gt 0)  {
    $first = $datesErr[0]
    $k = if ($runAgg.ErroredKeys.Contains($first)) { $runAgg.ErroredKeys[$first] } else { '' }
    if ($k) { "ERRORS on $($datesErr -join ', ') (unknown JSON shape; keys: $k)" }
    else    { "ERRORS on $($datesErr -join ', ')" }
}
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
    if ($runAgg.NonStandardMode.Count -gt 0) {
        $rows = @()
        foreach ($k in $runAgg.NonStandardMode.Keys) {
            $m = $runAgg.NonStandardMode[$k]
            $note = switch ($m) {
                'theme'           { "lacked a '## By Person' section &mdash; observations extracted by name-matching against existing personas+contacts" }
                'flattened-theme' { 'unknown JSON shape &mdash; observations extracted by flattening every string value and name-matching' }
                'communications'  { "communications[] shape &mdash; one observation per Cowork-summarized interaction; behavioral signals skipped" }
                'generic'         { 'generic person-array fallback &mdash; an unrecognized top-level array of name+body objects; behavioral signals skipped' }
                default           { 'non-standard mode' }
            }
            $rows += "<li><b>$k</b> &rarr; <code>$m</code>: $note</li>"
        }
        [void]$bodyParts.Add("<p style='color:#888'><i>Non-standard ingest modes for forward-compat:</i></p><ul style='color:#888'>" + ($rows -join '') + "</ul>")
    }
}
if ($datesErr.Count -gt 0) {
    [void]$bodyParts.Add("<p style='color:#b00'><b>Errors on:</b> $($datesErr -join ', ') &mdash; check the log; nothing was marked processed for these.</p>")
    $rows = @()
    foreach ($d in $datesErr) {
        $keys = if ($runAgg.ErroredKeys.Contains($d)) { $runAgg.ErroredKeys[$d] } else { '' }
        if ($keys) { $rows += "<li><b>$d</b> top-level JSON keys: <code>$keys</code></li>" }
        else       { $rows += "<li><b>$d</b> (no parsed JSON object)</li>" }
    }
    if ($rows.Count -gt 0) {
        [void]$bodyParts.Add("<p style='color:#b00'><i>Schema-drift diagnostic &mdash; add a converter shape that handles these keys:</i></p><ul style='color:#b00'>" + ($rows -join '') + "</ul>")
    }
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
    "Filed under 'Teammate12 abandoned a PR': the most Teammate12 thing on the timeline."
)

$bodyHtml = ($bodyParts -join "`n")

[void](Send-RunnerSummaryEmail `
    -RunnerName 'DM-DailySummaryImport' `
    -SubjectSuffix $subjectSuffix `
    -BodyHtml $bodyHtml `
    -JokePool $jokes)

