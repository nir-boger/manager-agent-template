# Shared parsing + matching helpers for the one-on-one-agenda skill.
#
# Dot-sourced by:
#   - .copilot/skills/run-one-on-one-agenda.ps1 (the pre-1:1 polling runner)
#   - tests/one-on-one-agenda.tests.ps1 (unit tests)
#
# Lives in this folder (not in _shared/) because the parser is specific to
# this skill's file shape (ON-NNN headings, # 1:1 agenda - <Person> header).
#
# ASCII-only on purpose (PS 5.1 parses .ps1 via CP1252).

# ---- agenda file parser ---------------------------------------------------
# Mirrors the team-agenda parser. Same field shape: Status / Kind / Opened by /
# Opened on / Owner / Summary / Why it matters / Next step / Notes / Closed on.
function Get-OneOnOneItems {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }

    $lines = Get-Content -Path $Path -Encoding UTF8
    $items = New-Object System.Collections.Generic.List[object]
    $current = $null
    $section = 'preamble'
    $lastKey = $null
    $multilineKeys = @('summary', 'next step', 'notes')
    $headingRe = '^###\s+(ON-\d{3})\s+(?:[\u2014\-]+)\s+(.+?)\s*$'
    $fieldRe   = '^\s*-\s*\*\*(?<key>[^:*]+):\*\*\s*(?<value>.+?)\s*$'

    foreach ($raw in $lines) {
        if ($raw -match '^##\s+Open\b')   { if ($current) { $items.Add($current); $current = $null }; $section = 'open';   $lastKey = $null; continue }
        if ($raw -match '^##\s+Closed\b') { if ($current) { $items.Add($current); $current = $null }; $section = 'closed'; $lastKey = $null; continue }
        if ($raw -match $headingRe) {
            if ($current) { $items.Add($current) }
            $current = [pscustomobject]@{
                Id       = $matches[1]
                Title    = $matches[2]
                Section  = $section
                Status   = ''
                Kind     = ''
                OpenedBy = ''
                OpenedOn = ''
                Owner    = ''
                Summary  = ''
                NextStep = ''
                Notes    = ''
                ClosedOn = ''
            }
            $lastKey = $null
            continue
        }
        if ($current -and $raw -match $fieldRe) {
            $k = $matches['key'].Trim().ToLower()
            $v = $matches['value'].Trim()
            switch ($k) {
                'status'         { $current.Status   = $v }
                'kind'           { $current.Kind     = $v }
                'opened by'      { $current.OpenedBy = $v }
                'opened on'      { $current.OpenedOn = $v }
                'owner'          { $current.Owner    = $v }
                'summary'        { $current.Summary  = $v }
                'next step'      { $current.NextStep = $v }
                'notes'          { $current.Notes    = $v }
                'closed on'      { $current.ClosedOn = $v }
                default          { }
            }
            $lastKey = $k
            continue
        }
        # Continuation line of a multi-line field (raw wrapped line, no bullet).
        if ($current -and $lastKey -and ($multilineKeys -contains $lastKey)) {
            $t = $raw.Trim()
            if ($t -eq '' -or $t -match '^#' -or $t -match '^---') {
                $lastKey = $null
            } else {
                switch ($lastKey) {
                    'summary'   { $current.Summary  = if ($current.Summary)  { $current.Summary  + "`n" + $t } else { $t } }
                    'next step' { $current.NextStep = if ($current.NextStep) { $current.NextStep + "`n" + $t } else { $t } }
                    'notes'     { $current.Notes    = if ($current.Notes)    { $current.Notes    + "`n" + $t } else { $t } }
                }
            }
        }
    }
    if ($current) { $items.Add($current) }
    return ,@($items.ToArray())
}

# Pull the display name out of the `# 1:1 agenda - <Person>` header line.
# Falls back to the file stem if the header doesn't match.
function Get-PersonLabel {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return ((Split-Path -Leaf $Path) -replace '\.md$','')
    }
    $first = Get-Content -Path $Path -Encoding UTF8 -TotalCount 1
    if ($first -match '^#\s+1:1\s+agenda\s+-\s+(.+?)\s*$') { return $matches[1].Trim() }
    return ((Split-Path -Leaf $Path) -replace '\.md$','')
}

# True iff $Subject contains $PersonToken (case-insensitive) AND any 1:1
# indicator. Word-boundary-anchored on the 1:1 patterns to keep false positives
# like "1x10 retro" out. Returns $false for empty inputs.
function Test-Is1on1MeetingForPerson {
    param([string]$Subject, [string]$PersonToken)
    if (-not $Subject -or -not $PersonToken) { return $false }
    $needle = [regex]::Escape($PersonToken)
    if ($Subject -inotmatch $needle) { return $false }
    $oneOnOnePatterns = @(
        '(?i)\b1x1\b',
        '(?i)\b1:1\b',
        '(?i)\b1-on-1\b',
        '(?i)\b1on1\b',
        '(?i)\bone[- ]on[- ]one\b',
        '(?i)\b1\s+on\s+1\b'
    )
    foreach ($p in $oneOnOnePatterns) {
        if ($Subject -match $p) { return $true }
    }
    return $false
}
