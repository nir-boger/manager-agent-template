# Pure helpers for pr-review-assistant. Dot-sourced by run-pr-review-assistant.ps1
# AND by tests/pr-review-assistant.tests.ps1. NO COM, NO REST, NO copilot
# invocation, NO logging. Anything that touches the world stays in the runner.

# Shared "Nirvana acted on this PR" marker helpers (format / regex / detection)
# live in _shared\pr-marker.ps1. pr-review-assistant uses the marker as a
# defensive in-PR idempotency signal (see SKILL.md section 7a + section
# Idempotency) and as a discoverable "Nirvana reviewed this iteration" trail.
. (Join-Path $PSScriptRoot '..\_shared\pr-marker.ps1')

function Read-SeenState {
    <#
    .SYNOPSIS
    Loads the seen.json idempotency state.

    .OUTPUTS
    Array of pscustomobject records ({pr,iteration,reviewed_at}). Empty array
    if the file is missing, empty, or malformed (defensive -- never throw).
    #>
    param([string] $Path)
    if (-not (Test-Path $Path)) { return @() }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } catch {
        return @()
    }
}

function Test-PrIterationSeen {
    <#
    .SYNOPSIS
    Returns $true if the given (PrId, IterationId) is present in $Records.
    #>
    param(
        [Parameter(Mandatory)] $Records,
        [Parameter(Mandatory)] [int] $PrId,
        [Parameter(Mandatory)] [int] $IterationId
    )
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $rp = [int]$r.pr
        $ri = [int]$r.iteration
        if ($rp -eq $PrId -and $ri -eq $IterationId) { return $true }
    }
    return $false
}

function Add-SeenRecord {
    <#
    .SYNOPSIS
    Atomically appends/updates a record for (PrId, IterationId) in seen.json.

    .DESCRIPTION
    Replaces any existing record for the same (pr,iteration) pair so re-runs
    refresh the timestamp. Uses temp-write + rename for atomicity. Returns the
    new record count.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int]    $PrId,
        [Parameter(Mandatory)] [int]    $IterationId,
        [Parameter(Mandatory)] [string] $ReviewedAtIso
    )
    $records = @(Read-SeenState -Path $Path)
    $records = @($records | Where-Object {
        -not ($null -ne $_ -and [int]$_.pr -eq $PrId -and [int]$_.iteration -eq $IterationId)
    })
    $records += [pscustomobject]@{
        pr          = $PrId
        iteration   = $IterationId
        reviewed_at = $ReviewedAtIso
    }
    $tmp = "$Path.tmp"
    ($records | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
    return $records.Count
}

function Get-LatestReviewerAddedTimeFromThreads {
    <#
    .SYNOPSIS
    Scans an array of ADO PR thread objects for the most recent system-message
    comment of the form "<adder> added <SelfDisplayName> as a reviewer" and
    returns its publishedDate as a UTC [DateTime]. Returns $null when no such
    comment is found or no parseable timestamps exist.

    .DESCRIPTION
    Pure (no REST). Used by the scheduled-scan cutoff to "rescue" PRs that were
    created before the cutoff but to which Nir was added as a reviewer on/after
    the cutoff -- otherwise late assignments to older PRs get silently dropped.

    Match is case-insensitive substring. The needle is exactly
    "added <SelfDisplayName> as a reviewer" -- ADO's system messages use the
    display name (e.g. "Your Name"), not the unique-name / email.

    Defensive: never throws.
    #>
    param(
        $Threads,
        [string] $SelfDisplayName
    )
    if (-not $Threads) { return $null }
    if ([string]::IsNullOrWhiteSpace($SelfDisplayName)) { return $null }
    $needle = "added $SelfDisplayName as a reviewer"
    $latest = $null
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    foreach ($t in @($Threads)) {
        if ($null -eq $t) { continue }
        $comments = $t.comments
        if (-not $comments) { continue }
        foreach ($c in @($comments)) {
            if ($null -eq $c) { continue }
            $content = [string]$c.content
            if ([string]::IsNullOrWhiteSpace($content)) { continue }
            if ($content.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $pub = $c.publishedDate
            if (-not $pub) { continue }
            try {
                $dt = [DateTime]::Parse([string]$pub, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
                if ($null -eq $latest -or $dt -gt $latest) { $latest = $dt }
            } catch { }
        }
    }
    return $latest
}

function Get-PrAutoCutoff {
    <#
    .SYNOPSIS
    Loads the auto-review cutoff timestamp from state/cutoff.txt.

    .DESCRIPTION
    Returns a UTC [DateTime] (Kind=Utc) parsed from the first non-comment,
    non-blank line of the file. Lines starting with '#' are comments. The
    sentinel value "none" (case-insensitive) disables the filter.

    Returns $null when:
      - the file is missing
      - the file contains only comments / blank lines
      - the first active line is "none"
      - the first active line is not a parseable ISO timestamp

    Defensive: never throws. The runner uses $null to mean "no cutoff".
    #>
    param([string] $Path)
    if (-not (Test-Path $Path)) { return $null }
    $lines = Get-Content -Path $Path -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $lines) { return $null }
    foreach ($line in @($lines)) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed.ToLowerInvariant() -eq 'none') { return $null }
        try {
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            return [DateTime]::Parse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        } catch {
            return $null
        }
    }
    return $null
}

function Resolve-PrReviewReportPath {
    <#
    .SYNOPSIS
    Returns the per-iteration report file path. If iter-N.md already exists
    (manual -Force re-review), returns iter-N-r2.md / -r3.md / ... (first free).
    #>
    param(
        [Parameter(Mandatory)] [string] $ReviewsRoot,
        [Parameter(Mandatory)] [int]    $PrId,
        [Parameter(Mandatory)] [int]    $IterationId
    )
    $dir = Join-Path $ReviewsRoot $PrId.ToString()
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $base = Join-Path $dir "iter-$IterationId.md"
    if (-not (Test-Path $base)) { return $base }
    $i = 2
    while (Test-Path (Join-Path $dir "iter-$IterationId-r$i.md")) { $i++ }
    return (Join-Path $dir "iter-$IterationId-r$i.md")
}

function Build-PrReviewAgentPrompt {
    <#
    .SYNOPSIS
    Constructs the prompt string passed to `copilot -p` for one PR review.

    .DESCRIPTION
    Pure string assembly. Inputs are pre-validated by the caller. The prompt
    points the agent at SKILL.md and pins the (PR, iteration, repo, report)
    facts so the agent does not re-resolve them.
    #>
    param(
        [Parameter(Mandatory)] [int]    $PrId,
        [Parameter(Mandatory)] [int]    $IterationId,
        [Parameter(Mandatory)] [string] $RepoName,
        [Parameter(Mandatory)] [string] $ReportPath,
        [Parameter(Mandatory)] [bool]   $IsOnDemand,
        [Parameter(Mandatory)] [bool]   $MigrationMode,
        [Parameter(Mandatory)] [string] $SkillMdPath,
        [Parameter(Mandatory)] [string] $AdoOrg,
        [Parameter(Mandatory)] [string] $AdoProject,
        [Parameter(Mandatory)] [string] $ManagerEmail,
        [Parameter(Mandatory)] [string] $SubjectPrefix,
        [string[]] $DmRulesPaths = @()
    )
    $onDemandStr  = if ($IsOnDemand) { 'true' } else { 'false' }
    $migrationStr = if ($MigrationMode) { 'true' } else { 'false' }
    $modeLine     = if ($MigrationMode) {
        'MIGRATION MODE IS ACTIVE. Write the report file ONLY. Do NOT post any ADO comments. Do NOT send the email. Log what you would have posted at the bottom of the report under a "Migration-mode would-post" section.'
    } else {
        'Normal mode. Post comments to ADO and send the summary email per the SKILL.'
    }
    $rulesBlock = ''
    $validRulesPaths = @()
    foreach ($rp in @($DmRulesPaths)) {
        if ([string]::IsNullOrWhiteSpace($rp)) { continue }
        $validRulesPaths += $rp
    }
    if ($validRulesPaths.Count -gt 0) {
        $bullets = ($validRulesPaths | ForEach-Object { "  - $_" }) -join "`n"
        $rulesBlock = @"

DM review rules (MANDATORY -- read these before composing findings):
$bullets

These files encode Nir's team-specific code-review rules (SOLID, COGS/perf, PSL
storage abstraction, test naming, FluentAssertions, no Thread.Sleep/Task.Delay,
no fire-and-forget async, ConcurrentExclusiveSchedulerPair-bound parallelism,
etc.). Apply EVERY rule in scope. Prefix the title of each finding grounded in
these rules with the rule ID (e.g. '[Concern] R3: ...'). Honor the scope
exemption noted at the top of each rules file (e.g. Kusto.Cloud.Platform is
exempt from the DM-only rules).
"@
    }
    return @"
Read the skill definition at $SkillMdPath and execute it for a single PR.

Pre-validated inputs (do not re-validate beyond the in-skill defensive checks):
  pr-id        : $PrId
  iteration-id : $IterationId
  repository   : $RepoName
  report-path  : $ReportPath
  is-on-demand : $onDemandStr
  migration    : $migrationStr

$modeLine
$rulesBlock
Constraints:
- Use ADO MCP tools (org='$AdoOrg', project='$AdoProject') for all ADO reads and writes.
- For each changed file, prefer codebase queries for ownership/conventions.
- Run a MULTI-MODEL REVIEW PANEL per SKILL section 5: build ONE shared review-context bundle, then spawn the built-in code-review sub-agent FOUR times IN PARALLEL (all four task calls in a single response) -- one per model: claude-opus-4.8, gpt-5.5, gpt-5.3-codex, claude-sonnet-4.6. Each panelist gets the identical bundle. (Gemini is not an available subagent model here; skip it.)
- SCORE each panelist's review 0-100 with one scoring pass on claude-opus-4.8 per SKILL section 5a, then KEEP ONLY the single highest-scored review per section 5b (tie-break claude-opus-4.8 > gpt-5.5 > gpt-5.3-codex > claude-sonnet-4.6). Do NOT merge panelists. Everything downstream operates on the winning review only. Record all panelist scores + the winner in the report (section 8) and the email scoreline (section 9).
- Post all four severity tiers (Blocker / Concern / Suggestion / Nit) per the SKILL section 7.
- Cap total posted comments at 25 per the SKILL.
- After posting findings (or the size-skipped notice), post ONE final marker thread per SKILL section 7a with status='Closed'. The body MUST be exactly:
      <!-- nirvana:pr-marker kind=<reviewed|size-skipped> pr=$PrId iteration=$IterationId at=<ISO-with-tz> findings=<count> -->
      Nirvana auto-review marker (iteration $IterationId): <count> finding(s) posted.

      -- Nirvana
  (Use kind='size-skipped' on the size-guard path, kind='reviewed' otherwise. The marker line is hidden in the rendered ADO UI but greppable in the raw thread content; pr-review-assistant scans it on subsequent runs as a defensive in-PR idempotency signal that complements state/seen.json.)
- Skip the marker post entirely on the validation-fail abort (step 1) -- we never touched the PR in that case.
- Write the per-iteration report at EXACTLY $ReportPath (the runner expects this path).
- Email Nir at $ManagerEmail with subject prefix '$SubjectPrefix', joke + Get-NirvanaSignature signature.
- PR comments use the name-only signoff '-- Nirvana' (no joke, no HTML signature).

Print ONE final summary line to stdout:
  pr-review-assistant: PR $PrId iter $IterationId status=<reviewed|skipped-size|skipped-validation|skipped-duplicate> blockers=<B> concerns=<C> suggestions=<S> nits=<N>

Do NOT ask any questions. Do NOT print extra commentary outside the summary line and the report file.
"@
}

function Get-DmReviewRulesPaths {
    <#
    .SYNOPSIS
    Returns the absolute paths of every *.md file under the rules folder.

    .DESCRIPTION
    Single source of truth for "which rules files does the runner inject into
    the agent prompt". Sorted alphabetically for deterministic ordering across
    runs. Returns @() when the folder is missing or empty.
    #>
    param([Parameter(Mandatory)] [string] $RulesDir)
    if (-not (Test-Path $RulesDir)) { return @() }
    $files = Get-ChildItem -Path $RulesDir -Filter '*.md' -File -ErrorAction SilentlyContinue
    if (-not $files) { return @() }
    return @($files | Sort-Object Name | ForEach-Object { $_.FullName })
}


