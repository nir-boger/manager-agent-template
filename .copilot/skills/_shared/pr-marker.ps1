# Pure helpers for the cross-skill "Nirvana acted on this PR" marker.
#
# Single source of truth for:
#   - the marker format string emitted by pr-review-assistant
#   - the regex used by pr-review-assistant (and tests) to detect it on
#     subsequent runs as a defensive in-PR idempotency signal
#
# The marker is a hidden HTML comment line that pr-review-assistant attaches to
# a top-level thread on the PR it just processed. HTML comments do not render in
# the ADO UI, so the marker is invisible to human readers but trivially greppable
# in the raw comment content returned by the ADO REST API / MCP.
#
# Format (one line, exactly):
#
#   <!-- nirvana:pr-marker kind=<kind> pr=<id> iteration=<n> at=<ISO> findings=<count> -->
#
# Fields:
#   kind       reviewed | size-skipped
#   pr         integer PR id
#   iteration  integer iteration id the marker was emitted for
#   at         ISO-8601 timestamp (with timezone) of when the marker was emitted
#   findings   integer count of comments posted in this run (0 on size-skipped)
#
# NO side effects, NO REST, NO COM. Dot-source from runners and tests.

function Format-NirvanaPrMarkerBody {
    <#
    .SYNOPSIS
    Compose the canonical body string for a Nirvana PR-marker thread.

    .DESCRIPTION
    Returns the exact text that pr-review-assistant must POST as the body of
    its final marker thread (one per (PR, iteration) it processes). The body
    starts with the hidden HTML-comment marker line, then a short visible
    one-liner so the thread is not entirely blank in the ADO UI, then the
    name-only `-- Nirvana` signoff per the PR comment voice rule.

    The marker line is the machine-readable signal consumed by
    Test-PrHasNirvanaMarker (used by pr-review-assistant on subsequent runs
    as a defensive in-PR idempotency check that complements seen.json).

    .OUTPUTS
    String (multi-line).
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('reviewed','size-skipped')] [string] $Kind,
        [Parameter(Mandatory)] [int]    $PrId,
        [Parameter(Mandatory)] [int]    $IterationId,
        [Parameter(Mandatory)] [string] $At,
        [int] $Findings = 0
    )

    $marker = "<!-- nirvana:pr-marker kind=$Kind pr=$PrId iteration=$IterationId at=$At findings=$Findings -->"

    $visible = switch ($Kind) {
        'reviewed'      { "Nirvana auto-review marker (iteration $IterationId): $Findings finding(s) posted." }
        'size-skipped'  { "Nirvana auto-review marker (iteration $IterationId): size-skipped, no findings posted." }
    }

    return "$marker`n$visible`n`n-- Nirvana"
}

function Get-NirvanaPrMarkerRegex {
    <#
    .SYNOPSIS
    Return the regex used to detect a Nirvana PR-marker in raw comment content.

    .DESCRIPTION
    Builds an anchored-fragment regex (no leading/trailing anchors so it can be
    used with the PowerShell -match operator on a multi-line comment body).

    When -IterationId is not provided (or 0), matches a marker for any iteration.
    When -Kind is not provided, matches any kind.

    The regex is case-sensitive on the key names (kind/pr/iteration/at/findings)
    to mirror the format produced by Format-NirvanaPrMarkerBody.

    .OUTPUTS
    String containing a .NET regex pattern.
    #>
    param(
        [Parameter(Mandatory)] [int]    $PrId,
        [int]    $IterationId = 0,
        [string] $Kind
    )

    $kindFrag = if ([string]::IsNullOrWhiteSpace($Kind)) { '\S+' } else { [regex]::Escape($Kind) }
    $iterFrag = if ($IterationId -gt 0) { "iteration=$IterationId" } else { 'iteration=\d+' }

    return "<!--\s*nirvana:pr-marker\s+kind=$kindFrag\s+pr=$PrId\s+$iterFrag\b[^>]*-->"
}

function Test-PrHasNirvanaMarker {
    <#
    .SYNOPSIS
    Return $true if any thread on the PR contains a Nirvana PR-marker.

    .DESCRIPTION
    Scans the threads array (shape returned by ado-repo_list_pull_request_threads
    or the equivalent ADO REST endpoint) for a comment whose content matches the
    regex from Get-NirvanaPrMarkerRegex. Defensive: tolerates $null threads,
    threads without comments, comments without content.

    When -IterationId is provided (>0), constrains the match to that iteration.
    When -Kind is provided, constrains the match to that kind.

    .OUTPUTS
    [bool]
    #>
    param(
        [object] $Threads,
        [Parameter(Mandatory)] [int]    $PrId,
        [int]    $IterationId = 0,
        [string] $Kind
    )

    if (-not $Threads) { return $false }
    $regex = Get-NirvanaPrMarkerRegex -PrId $PrId -IterationId $IterationId -Kind $Kind

    foreach ($t in @($Threads)) {
        if (-not $t) { continue }
        $comments = $t.comments
        if (-not $comments) { continue }
        foreach ($c in @($comments)) {
            if (-not $c) { continue }
            $content = [string]$c.content
            if ([string]::IsNullOrEmpty($content)) { continue }
            if ($content -match $regex) { return $true }
        }
    }
    return $false
}
