#Requires -Version 5.1
# ---------------------------------------------------------------------------
# pr-review-request -- shared Azure DevOps REST helpers.
#
# Pure-ish helpers (network I/O only; no other side effects) dot-sourced by BOTH
# run-pr-review-request.ps1 (the 5-min Teams bot) and seed-baseline.ps1 (the
# on-demand 6-month p50 seeder). Extracted to one place so auth, api-version,
# identity resolution and paging can't drift between the two callers.
#
# These functions reference $adoOrg / $adoProject from the DOT-SOURCING scope
# (PS dot-sourcing shares scope), exactly as the runner did when they lived
# inline. Every caller sets $adoOrg / $adoProject before dot-sourcing this file.
# ---------------------------------------------------------------------------

function Get-AdoAccessToken {
    $token = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv) 2>$null
    if (-not $token) { throw 'Failed to acquire ADO token via az CLI. Run "az login" first.' }
    return $token
}

function Invoke-AdoRest {
    param([Parameter(Mandatory)] [hashtable] $Headers, [Parameter(Mandatory)] [string] $Url)
    return Invoke-RestMethod -Method GET -Uri $Url -Headers $Headers
}

function ConvertTo-UtcDate {
    param([string] $S)
    return [DateTime]::Parse(
        $S,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Get-AdoSelf {
    param([Parameter(Mandatory)] [hashtable] $Headers)
    $url = "https://dev.azure.com/$adoOrg/_apis/connectionData"
    $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    if (-not $resp.authenticatedUser) { throw 'connectionData did not return authenticatedUser.' }
    return [PSCustomObject]@{
        id          = [string]$resp.authenticatedUser.id
        displayName = [string]$resp.authenticatedUser.providerDisplayName
        uniqueName  = [string]$resp.authenticatedUser.uniqueName
    }
}

function Get-AdoIdentity {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $Smtp,
        [Parameter(Mandatory)] [string] $DisplayName
    )
    $url = "https://vssps.dev.azure.com/$adoOrg/_apis/identities?searchFilter=MailAddress&filterValue=$([uri]::EscapeDataString($Smtp))&api-version=7.1"
    try { $resp = Invoke-AdoRest -Headers $Headers -Url $url } catch { $resp = $null }
    if ($resp -and $resp.value -and $resp.value.Count -gt 0) {
        $hit = $resp.value[0]
        return [PSCustomObject]@{ id = [string]$hit.id; displayName = [string]$hit.providerDisplayName }
    }
    $url2 = "https://vssps.dev.azure.com/$adoOrg/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($DisplayName))&api-version=7.1"
    try { $resp2 = Invoke-AdoRest -Headers $Headers -Url $url2 } catch { return $null }
    if (-not $resp2.value -or $resp2.value.Count -eq 0) { return $null }
    $needle = $DisplayName.Trim().ToLowerInvariant()
    $candidates = @($resp2.value | Where-Object {
        ($_.providerDisplayName -and $_.providerDisplayName.Trim().ToLowerInvariant() -eq $needle) -or
        ($_.customDisplayName -and $_.customDisplayName.Trim().ToLowerInvariant() -eq $needle)
    })
    if ($candidates.Count -eq 0) { $candidates = @($resp2.value) }
    $picked = $null
    foreach ($c in $candidates) {
        $mail = if ($c.mailAddress) { [string]$c.mailAddress } else { '' }
        if ($mail -match '@microsoft\.com$') { $picked = $c; break }
    }
    if (-not $picked) { $picked = $candidates[0] }
    return [PSCustomObject]@{ id = [string]$picked.id; displayName = [string]$picked.providerDisplayName }
}

# ---------------------------------------------------------------------------
# Historical query used by seed-baseline.ps1 only (the runner uses its own
# active-only Get-ActivePrsByCreator). Returns ALL PRs (any status) created by
# $IdentityId at/after $SinceUtc, paging past the 100-row $top cap with $skip and
# client-filtering on creationDate (belt-and-suspenders over the server-side
# created-time filter, whose semantics vary by API version).
# ---------------------------------------------------------------------------
function Get-PrsByCreatorSince {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $IdentityId,
        [Parameter(Mandatory)] [datetime] $SinceUtc,
        [int] $PageSize = 100,
        [int] $MaxPages = 50
    )
    $minIso = $SinceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $items  = New-Object System.Collections.Generic.List[object]
    $skip   = 0
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $url = "https://dev.azure.com/$adoOrg/$adoProject/_apis/git/pullrequests?" +
               "searchCriteria.creatorId=$IdentityId&searchCriteria.status=all" +
               "&searchCriteria.queryTimeRangeType=created&searchCriteria.minTime=$([uri]::EscapeDataString($minIso))" +
               "&`$top=$PageSize&`$skip=$skip&api-version=7.1"
        try { $resp = Invoke-AdoRest -Headers $Headers -Url $url } catch { break }
        $batch = @($resp.value)
        if ($batch.Count -eq 0) { break }
        foreach ($pr in $batch) {
            try {
                $created = ConvertTo-UtcDate ([string]$pr.creationDate)
            } catch { continue }
            if ($created -lt $SinceUtc) { continue }   # client-side guard
            $closed = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$pr.closedDate)) {
                try { $closed = ConvertTo-UtcDate ([string]$pr.closedDate) } catch { $closed = $null }
            }
            $items.Add([PSCustomObject]@{
                id         = [int]$pr.pullRequestId
                repoName   = [string]$pr.repository.name
                repoId     = [string]$pr.repository.id
                title      = [string]$pr.title
                status     = [string]$pr.status
                isDraft    = [bool]$pr.isDraft
                createdAt  = $created
                closedAt   = $closed
                authorId   = [string]$pr.createdBy.id
                authorName = [string]$pr.createdBy.displayName
            })
        }
        if ($batch.Count -lt $PageSize) { break }
        $skip += $PageSize
    }
    return $items.ToArray()
}

# Threads for a PR (used to recover the first reviewer COMMENT timestamp -- the
# only review timestamp ADO exposes historically; votes carry none).
function Get-PrThreadsForPr {
    param([Parameter(Mandatory)] [hashtable] $Headers, [Parameter(Mandatory)] [string] $RepoId, [Parameter(Mandatory)] [int] $Id)
    $url = "https://dev.azure.com/$adoOrg/$adoProject/_apis/git/repositories/$RepoId/pullRequests/$Id/threads?api-version=7.1"
    try { $resp = Invoke-AdoRest -Headers $Headers -Url $url } catch { return @() }
    if (-not $resp.value) { return @() }
    return @($resp.value)
}

# First non-author, non-system comment time (UTC) across a PR's threads, or $null.
# This is our historical TTFR signal: time from PR creation to first human comment.
function Get-FirstReviewCommentUtc {
    param([object[]] $Threads = @(), [string] $AuthorId)
    $best = $null
    foreach ($t in @($Threads)) {
        foreach ($c in @($t.comments)) {
            $ct = [string]$c.commentType
            if ($ct -and $ct -ne 'text' -and $ct -ne 'codeChange') { continue }   # skip 'system'
            $aid = [string]$c.author.id
            if ($aid -and $AuthorId -and $aid -eq $AuthorId) { continue }          # skip author's own
            if ([string]::IsNullOrWhiteSpace([string]$c.publishedDate)) { continue }
            try { $pub = ConvertTo-UtcDate ([string]$c.publishedDate) } catch { continue }
            if ($null -eq $best -or $pub -lt $best) { $best = $pub }
        }
    }
    return $best
}
