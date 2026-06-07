# Persona hot/cold cache mining helpers.
#
# Source of truth for the auto-maintained sections of people/<alias>.md:
#   ## Areas of ownership       -- sticky themes (WITs, PRs, repos) with counters
#   ## Project ledger           -- append-only "what was new this month" log
#   ## Frequent collaborators   -- @mentions + email From/To/Cc counters
#
# State is persisted as JSON sidecars at
#   .copilot/skills/team-personas/people-state/<alias>.json
# (gitignored; derived data -- can always be rebuilt from the cold cache).
#
# Cold cache lives at
#   reports/personas-archive/<YYYY-MM-DD>/<File>.json
# i.e. the raw Cowork JSON drops, moved here instead of deleted after import.
#
# Consumers:
#   - run-personas-import.ps1   (daily delta -- mines one drop at a time)
#   - run-personas-rebuild.ps1  (full rebuild -- walks the entire archive)
#
# Both runners dot-source this file. The file carries a UTF-8 BOM so any
# Hebrew literals in patches parse correctly.

$ErrorActionPreference = 'Stop'

# Names that should never count as collaborators. Nir himself + bots + the
# automation surface. Match is case-insensitive substring.
$script:PersonaSenderDenylist = @(
    'Your Name', 'Nirvana',
    'Microsoft Outlook', 'Microsoft Teams', 'Microsoft Security',
    'Cowork', 'Copilot', 'noreply', 'no-reply', 'do-not-reply',
    'kopsMI', 'GitOps', 'Azure User Access Review', 'Incident Automation',
    'Workflows', 'Auto-restart', 'automation', 'service account', '(bot)'
)

function Get-PersonaStateDir {
    param([Parameter(Mandatory=$true)][string]$PersonasSkillRoot)
    $d = Join-Path $PersonasSkillRoot 'people-state'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Get-PersonaArchiveDir {
    param([Parameter(Mandatory=$true)][string]$AgentRoot, [string]$DateStamp)
    $d = Join-Path $AgentRoot 'reports\personas-archive'
    if ($DateStamp) { $d = Join-Path $d $DateStamp }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Get-PersonaRepoVocab {
    param([Parameter(Mandatory=$true)][string]$PersonasSkillRoot)
    $f = Join-Path $PersonasSkillRoot 'ado-repos.txt'
    if (-not (Test-Path $f)) { return @() }
    return @(Get-Content $f -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Test-IsDenylistedName {
    param([string]$Name)
    if (-not $Name) { return $true }
    $n = $Name.Trim()
    if ($n.Length -lt 2) { return $true }
    foreach ($deny in $script:PersonaSenderDenylist) {
        if ($n -ieq $deny) { return $true }
        if ($n -ilike "*$deny*") { return $true }
    }
    if ($n -match '(?i)^(re|fw|fwd|subject|automated|bot)$') { return $true }
    return $false
}

function New-EmptyPersonaState {
    param([Parameter(Mandatory=$true)][string]$Alias)
    return [ordered]@{
        alias          = $Alias
        last_drop_date = $null
        areas          = @{}
        collaborators  = @{}
        ledger         = @()
    }
}

function Load-PersonaState {
    param([Parameter(Mandatory=$true)][string]$StateDir,
          [Parameter(Mandatory=$true)][string]$Alias)
    $path = Join-Path $StateDir "$Alias.json"
    if (-not (Test-Path $path)) { return (New-EmptyPersonaState -Alias $Alias) }
    try {
        $raw = Get-Content $path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json -AsHashtable
        if (-not $obj.ContainsKey('alias'))          { $obj['alias'] = $Alias }
        if (-not $obj.ContainsKey('last_drop_date')) { $obj['last_drop_date'] = $null }
        if (-not $obj.ContainsKey('areas'))          { $obj['areas'] = @{} }
        if (-not $obj.ContainsKey('collaborators'))  { $obj['collaborators'] = @{} }
        if (-not $obj.ContainsKey('ledger'))         { $obj['ledger'] = @() }
        return $obj
    } catch {
        Write-Warning "Could not parse persona state for $Alias ($($_.Exception.Message)); starting fresh."
        return (New-EmptyPersonaState -Alias $Alias)
    }
}

function Save-PersonaState {
    param([Parameter(Mandatory=$true)][string]$StateDir,
          [Parameter(Mandatory=$true)]$State)
    $alias = $State.alias
    if (-not $alias) { throw 'Save-PersonaState: state.alias is empty' }
    $path = Join-Path $StateDir "$alias.json"
    $json = $State | ConvertTo-Json -Depth 8
    $tmp = "$path.tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8 -NoNewline:$false
    Move-Item -Path $tmp -Destination $path -Force
}

# Extract area + collaborator signal from a Cowork JSON drop's `content` blob.
# Returns @{ areas = [@{key;label;kind;ref}, ...]; collaborators = [<Name>, ...] }
# Both arrays may contain duplicates -- caller folds them into counters via
# Update-PersonaState.
function Get-PersonaDropSignal {
    param([Parameter(Mandatory=$true)][string]$ContentMd,
          [string[]]$RepoVocab = @())

    $areas  = New-Object System.Collections.ArrayList
    $collab = New-Object System.Collections.ArrayList

    # 1) ADO work item IDs -- only with #-prefix OR explicit kind word.
    $witRegex = [regex]'(?:#|\b(?:WIT|PBI|Bug|Task|Feature|Epic)\s+#?)(\d{7,9})\b'
    foreach ($m in $witRegex.Matches($ContentMd)) {
        $id = $m.Groups[1].Value
        [void]$areas.Add(@{ key = "wit:$id"; label = "WIT $id"; kind = 'wit'; ref = $id })
    }

    # 2) PRs -- "PR <id>" or "Pull Request <id>"
    $prRegex = [regex]'\b(?:PR|Pull\s+Request)\s+(\d{6,9})\b'
    foreach ($m in $prRegex.Matches($ContentMd)) {
        $id = $m.Groups[1].Value
        [void]$areas.Add(@{ key = "pr:$id"; label = "PR $id"; kind = 'pr'; ref = $id })
    }

    # 3) Repo mentions from vocab list (case-insensitive substring -- once per drop).
    foreach ($repo in $RepoVocab) {
        if (-not $repo) { continue }
        if ($ContentMd -imatch ([regex]::Escape($repo))) {
            [void]$areas.Add(@{ key = "repo:$repo"; label = "$repo repo"; kind = 'repo'; ref = $repo })
        }
    }

    # 4) @mentions in blockquoted Teams lines. Walk line-by-line so a single
    #    line with multiple @mentions ("Hey @Your Name and @Your Manager")
    #    yields every name, not just the first.
    #    Per name-word: "Uppercase + lowercase" -- stops at lowercase words
    #    ("hi"), all-caps abbreviations ("FYI", "ASAP"), and digits.
    #    Internal hyphens / dots are kept (e.g. "Your VP").
    $perNameRegex = [regex]"@([A-Z][a-z][A-Za-z0-9\-\.]*(?:\s+[A-Z][a-z][A-Za-z0-9\-\.]*){0,2})"
    foreach ($line in ($ContentMd -split "(?:\r\n|\n)")) {
        if ($line -notmatch '^>\s') { continue }
        foreach ($m in $perNameRegex.Matches($line)) {
            $name = ($m.Groups[1].Value -replace '[\s\.,:;!?]+$','').Trim()
            if (-not (Test-IsDenylistedName $name)) { [void]$collab.Add($name) }
        }
    }

    # 5) Email headers -- "- From: <Name> <addr>", "- To: ...", "- Cc: ..."
    $hdrRegex = [regex]'(?m)^\s*-?\s*(?:From|To|Cc):\s*([^<\r\n]+?)\s*<'
    foreach ($m in $hdrRegex.Matches($ContentMd)) {
        $name = $m.Groups[1].Value.Trim().TrimEnd(',').Trim('"')
        if (-not (Test-IsDenylistedName $name)) { [void]$collab.Add($name) }
    }

    return @{ areas = @($areas.ToArray()); collaborators = @($collab.ToArray()) }
}

function Update-PersonaState {
    param([Parameter(Mandatory=$true)]$State,
          [Parameter(Mandatory=$true)]$Signal,
          [Parameter(Mandatory=$true)][string]$DropDate,
          [string]$SelfName = $null)

    if ($DropDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
        throw "Update-PersonaState: DropDate must be YYYY-MM-DD, got '$DropDate'"
    }
    $month = $DropDate.Substring(0, 7)

    foreach ($a in @($Signal.areas)) {
        $key = $a.key
        if (-not $State.areas.ContainsKey($key)) {
            $State.areas[$key] = [ordered]@{
                label = $a.label; kind = $a.kind; ref = $a.ref
                first = $DropDate; last = $DropDate; count = 0
            }
            $monthEntry = @($State.ledger | Where-Object { $_.month -eq $month }) | Select-Object -First 1
            if (-not $monthEntry) {
                $State.ledger += ,([ordered]@{ month = $month; new_areas = @($key) })
            } elseif (@($monthEntry.new_areas) -notcontains $key) {
                $monthEntry.new_areas = @(@($monthEntry.new_areas) + $key)
            }
        }
        $entry = $State.areas[$key]
        $entry.count = [int]$entry.count + 1
        if ($DropDate -lt [string]$entry.first) { $entry.first = $DropDate }
        if ($DropDate -gt [string]$entry.last)  { $entry.last  = $DropDate }
    }

    foreach ($name in @($Signal.collaborators)) {
        if ($SelfName -and ($name -ieq $SelfName)) { continue }
        if (-not $State.collaborators.ContainsKey($name)) {
            $State.collaborators[$name] = [ordered]@{ first = $DropDate; last = $DropDate; count = 0 }
        }
        $entry = $State.collaborators[$name]
        $entry.count = [int]$entry.count + 1
        if ($DropDate -lt [string]$entry.first) { $entry.first = $DropDate }
        if ($DropDate -gt [string]$entry.last)  { $entry.last  = $DropDate }
    }

    if ((-not $State.last_drop_date) -or ($DropDate -gt $State.last_drop_date)) {
        $State.last_drop_date = $DropDate
    }
    return $State
}

# Reverse the kebab-case alias back to a display-name candidate so the persona
# subject can be filtered out of their own collaborator graph.
# "Teammate1-Teammate1"          -> "Teammate1"
# "ran-ben-Teammate9"       -> "Teammate9"
# "your-vp" -> "Your VP"
function Convert-AliasToDisplayName {
    param([Parameter(Mandatory=$true)][string]$Alias)
    $parts = $Alias -split '-' | Where-Object { $_ }
    $cap = foreach ($p in $parts) {
        if ($p.Length -eq 0) { '' }
        elseif ($p.Length -eq 1) { $p.ToUpperInvariant() }
        else { $p.Substring(0,1).ToUpperInvariant() + $p.Substring(1).ToLowerInvariant() }
    }
    return ($cap -join ' ')
}

# Convert Cowork's PascalCase_Underscore filename to our kebab-case alias.
# "Teammate1.json"     -> "Teammate1-Teammate1"
# "Teammate9.json"   -> "ran-ben-Teammate9"   (splits CamelCase too)
# "Teammate3.md"   -> "maya-Teammate3"
function Convert-FilenameToAlias {
    param([string]$FileName)
    $base = $FileName -replace '\.(md|json)$',''
    $parts = $base -split '_' | Where-Object { $_.Trim() -ne '' }
    $expanded = foreach ($p in $parts) {
        ($p -creplace '(?<=[a-z])(?=[A-Z])', '-')
    }
    return ((($expanded -join '-') -replace '-+', '-').Trim('-')).ToLowerInvariant()
}

# --- Renderers ----------------------------------------------------------------

function Render-AreasSection {
    param([Parameter(Mandatory=$true)]$State, [int]$TopN = 25)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('## Areas of ownership')
    [void]$lines.Add('<!-- auto-maintained by run-personas-import.ps1 -- do not hand-edit. Curated context goes in ## Notes. -->')
    $count = 0
    if ($State.areas -and $State.areas.Count -gt 0) { $count = $State.areas.Count }
    if ($count -eq 0) {
        [void]$lines.Add('_(No areas tracked yet -- next Cowork drop will populate.)_')
    } else {
        $sorted = $State.areas.GetEnumerator() |
            Sort-Object @{Expression={[string]$_.Value.last};Descending=$true},
                        @{Expression={[int]$_.Value.count};Descending=$true}
        $sorted | Select-Object -First $TopN | ForEach-Object {
            $v = $_.Value
            $unit = if ([int]$v.count -eq 1) { 'mention' } else { 'mentions' }
            [void]$lines.Add(("- {0} -- first {1} -- last {2} -- {3} {4}" -f $v.label, $v.first, $v.last, [int]$v.count, $unit))
        }
    }
    return ($lines -join "`r`n")
}

function Render-LedgerSection {
    param([Parameter(Mandatory=$true)]$State)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('## Project ledger')
    [void]$lines.Add('<!-- auto-maintained: first month each area was observed. Append-only by design. -->')
    $ledger = @($State.ledger)
    if ($ledger.Count -eq 0) {
        [void]$lines.Add('_(No ledger entries yet.)_')
    } else {
        $sorted = $ledger | Sort-Object @{Expression={[string]$_.month};Descending=$true}
        foreach ($e in $sorted) {
            $labels = foreach ($k in @($e.new_areas)) {
                if ($State.areas.ContainsKey($k)) { $State.areas[$k].label } else { $k }
            }
            [void]$lines.Add(("- {0}: {1}" -f $e.month, ($labels -join ', ')))
        }
    }
    return ($lines -join "`r`n")
}

function Render-CollaboratorsSection {
    param([Parameter(Mandatory=$true)]$State, [int]$TopN = 15)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('## Frequent collaborators')
    [void]$lines.Add('<!-- auto-maintained: @mentions in chat + email From/To/Cc. Bots and Nir himself are filtered. -->')
    $count = 0
    if ($State.collaborators -and $State.collaborators.Count -gt 0) { $count = $State.collaborators.Count }
    if ($count -eq 0) {
        [void]$lines.Add('_(No collaborator signal yet.)_')
    } else {
        $sorted = $State.collaborators.GetEnumerator() |
            Sort-Object @{Expression={[int]$_.Value.count};Descending=$true},
                        @{Expression={[string]$_.Value.last};Descending=$true}
        $sorted | Select-Object -First $TopN | ForEach-Object {
            $v = $_.Value
            $unit = if ([int]$v.count -eq 1) { 'interaction' } else { 'interactions' }
            [void]$lines.Add(("- {0} -- first {1} -- last {2} -- {3} {4}" -f $_.Key, $v.first, $v.last, [int]$v.count, $unit))
        }
    }
    return ($lines -join "`r`n")
}

# Rewrite (or insert) the first H1 of a persona file to the canonical form
# documented in team-personas/SKILL.md:106 -- "# <Display Name> (<alias>)".
# Cowork raw drops use 4+ different wordings ("Working-Style Persona: X",
# "X -- Persona", etc.) and the site's clean_persona_name regex falls over
# when the em-dash is mojibaked. Calling this on every import write keeps
# the H1 aligned across all 15 personas no matter what wording the upstream
# drop happens to carry. Pure string op; works on plain-text content the
# caller has already decoded as UTF-8 (no I/O).
function Set-CanonicalPersonaH1 {
    param([Parameter(Mandatory=$true)][string]$Content,
          [Parameter(Mandatory=$true)][string]$Alias)
    $display   = Convert-AliasToDisplayName -Alias $Alias
    $canonical = "# $display ($Alias)"
    $h1Pattern = '(?m)^#[ \t]+(?!#).*$'
    if ([regex]::IsMatch($Content, $h1Pattern)) {
        return [regex]::Replace($Content, $h1Pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $canonical }, 1)
    }
    # No H1 in the file -- prepend one with a blank line, preserving the body.
    return "$canonical`r`n`r`n" + $Content
}

# Replace (or insert) the three auto-maintained sections in the persona file.
# Order: Areas -> Ledger -> Collaborators. Position: just before
# `## Daily observations` if present, else appended at end. All other content
# (Snapshot / Recent Topics / Notes / Daily observations / etc.) is preserved
# byte-for-byte. Also re-canonicalizes the first H1 so drift in upstream
# Cowork drops can't leak into the site sidebar.
function Write-PersonaSections {
    param([Parameter(Mandatory=$true)][string]$PersonPath,
          [Parameter(Mandatory=$true)]$State)
    if (-not (Test-Path $PersonPath)) { return }
    $content = Get-Content $PersonPath -Raw -Encoding UTF8
    $alias = [System.IO.Path]::GetFileNameWithoutExtension($PersonPath)
    $content = Set-CanonicalPersonaH1 -Content $content -Alias $alias

    $areasBlock  = Render-AreasSection       $State
    $ledgerBlock = Render-LedgerSection      $State
    $collabBlock = Render-CollaboratorsSection $State
    $combined = $areasBlock + "`r`n`r`n" + $ledgerBlock + "`r`n`r`n" + $collabBlock

    foreach ($t in @('Areas of ownership','Project ledger','Frequent collaborators')) {
        $pattern = "(?ms)^##\s+$([regex]::Escape($t))\s*\r?\n.*?(?=^##\s|\Z)"
        $content = [regex]::Replace($content, $pattern, '')
    }

    # Normalize trailing whitespace.
    $content = $content -replace '(?s)[\r\n\s]+$', "`r`n"

    # Insert the trio just before "## Daily observations" if it exists,
    # otherwise append at the end. Use a MatchEvaluator to avoid having to
    # escape backslashes inside the replacement payload (regex escape would
    # mangle file paths or backslashes that appear in labels).
    $dailyPattern = '(?m)^##\s+Daily observations\s*$'
    if ([regex]::IsMatch($content, $dailyPattern)) {
        $evaluator = { param($m) $combined + "`r`n`r`n" + $m.Value }
        $content = [regex]::Replace($content, $dailyPattern, $evaluator, 1)
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n" + $combined + "`r`n"
    }

    Set-Content -Path $PersonPath -Value $content -Encoding UTF8 -NoNewline:$false
}

# Convenience: do mine + update + save + render in one shot. Used by the import
# runner per-file and by the rebuild runner per-alias (after accumulating all
# archive drops).
function Invoke-PersonaMineForDrop {
    param([Parameter(Mandatory=$true)][string]$JsonPath,
          [Parameter(Mandatory=$true)][string]$Alias,
          [Parameter(Mandatory=$true)][string]$DropDate,
          [Parameter(Mandatory=$true)][string]$StateDir,
          [Parameter(Mandatory=$true)][string]$PersonPath,
          [string[]]$RepoVocab = @(),
          [string]$SelfName = $null)
    $j = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $SelfName) { $SelfName = Convert-AliasToDisplayName -Alias $Alias }
    $signal = Get-PersonaDropSignal -ContentMd $j.content -RepoVocab $RepoVocab
    $state  = Load-PersonaState -StateDir $StateDir -Alias $Alias
    $state  = Update-PersonaState -State $state -Signal $signal -DropDate $DropDate -SelfName $SelfName
    Save-PersonaState -StateDir $StateDir -State $state
    Write-PersonaSections -PersonPath $PersonPath -State $state
    return @{
        Areas         = @($signal.areas).Count
        Collaborators = @($signal.collaborators).Count
        UniqueAreas   = ($signal.areas | ForEach-Object { $_.key } | Sort-Object -Unique).Count
    }
}

