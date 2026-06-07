# Tests for the pr-review-assistant skill.
#
# Validates:
#   - manifest entry shape (config/skills.json)
#   - runner is ASCII-only (PS 5.1 source constraint)
#   - SKILL.md mentions the right ADO MCP tools and signoff voice
#   - runner uses runner-prelude, single-instance lock, az access-token, Invoke-CopilotAgent
#   - helpers.ps1 pure functions: Read-SeenState / Test-PrIterationSeen / Add-SeenRecord /
#     Resolve-PrReviewReportPath / Build-PrReviewAgentPrompt

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot   = Split-Path $PSScriptRoot -Parent
$skillDir   = Join-Path $repoRoot '.copilot\skills\pr-review-assistant'
$runner     = Join-Path $repoRoot '.copilot\skills\run-pr-review-assistant.ps1'
$helpers    = Join-Path $skillDir 'helpers.ps1'
$skillMd    = Join-Path $skillDir 'SKILL.md'
$manifest   = Join-Path $repoRoot 'config\skills.json'

if (-not (Test-Path $skillDir)) { throw "skill folder missing: $skillDir" }
if (-not (Test-Path $runner))   { throw "runner missing: $runner" }
if (-not (Test-Path $helpers))  { throw "helpers missing: $helpers" }
if (-not (Test-Path $skillMd))  { throw "SKILL.md missing: $skillMd" }
if (-not (Test-Path $manifest)) { throw "manifest missing: $manifest" }

$manifestObj = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$entry = $manifestObj.skills | Where-Object { $_.name -eq 'pr-review-assistant' } | Select-Object -First 1
$runnerText = Get-Content $runner  -Raw -Encoding UTF8
$skillText  = Get-Content $skillMd -Raw -Encoding UTF8

# Load pure helpers for direct call-tests.
. $helpers

Describe 'pr-review-assistant manifest entry' {

    It 'exists in config/skills.json' {
        Assert-True ($null -ne $entry) "expected an entry named 'pr-review-assistant'"
    }

    It 'has surface=engine and category=reviews-dri' {
        Assert-Equal 'engine'        $entry.surface
        Assert-Equal 'reviews-dri'   $entry.category
    }

    It 'points at the skill folder and runner' {
        Assert-Equal '.copilot/skills/pr-review-assistant'          $entry.path
        Assert-Equal '.copilot/skills/run-pr-review-assistant.ps1'  $entry.entrypoint_path
    }

    It 'is visible in AGENTS.md and ships in snapshot' {
        Assert-True $entry.show_in_agents
        Assert-True $entry.ship_in_snapshot
    }

    It 'includes the primary trigger phrases' {
        $triggers = ($entry.triggers -join '|').ToLower()
        Assert-Match 'review pr'                $triggers
        Assert-Match 'draft review for pr'      $triggers
        Assert-Match 'review my queue'          $triggers
        Assert-Match 'pr-review-assistant'      $triggers
    }
}

Describe 'pr-review-assistant runner script' {

    It 'is ASCII-only (PS 5.1 source-file constraint)' {
        $bytes = [System.IO.File]::ReadAllBytes($runner)
        $offenders = @()
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $offenders += $i }
            if ($offenders.Count -ge 5) { break }
        }
        Assert-Empty $offenders ("non-ASCII bytes at offsets: " + ($offenders -join ', '))
    }

    It 'dot-sources the shared runner-prelude' {
        Assert-Match '_shared\\runner-prelude\.ps1' $runnerText
    }

    It 'dot-sources the shared migration-mode helper' {
        Assert-Match '_shared\\migration-mode\.ps1' $runnerText
        Assert-Match 'Test-MigrationMode'           $runnerText
    }

    It 'dot-sources the per-skill helpers.ps1' {
        Assert-Match "pr-review-assistant.*helpers\.ps1|helpers\.ps1" $runnerText
    }

    It 'acquires a single-instance lock' {
        Assert-Match 'pr-review-assistant\.lock' $runnerText
        Assert-Match '\$PID'                      $runnerText
    }

    It 'acquires an ADO bearer token via az CLI' {
        Assert-Match 'az account get-access-token'                 $runnerText
        Assert-Match '499b84ac-1321-427f-aa17-267ca6975798'        $runnerText
        Assert-Match 'Authorization'                               $runnerText
        Assert-Match 'Bearer'                                      $runnerText
    }

    It 'resolves self-id via ADO connectionData and lists PRs by reviewerId' {
        Assert-Match '/_apis/connectionData'                       $runnerText
        Assert-Match 'searchCriteria\.reviewerId'                  $runnerText
        Assert-Match 'searchCriteria\.status=active'               $runnerText
    }

    It 'invokes the agent through the centralized Invoke-CopilotAgent helper' {
        # P1 refactor: copilot invocation (incl. --allow-all-tools / --no-ask-user)
        # is centralized in _shared/invoke-agent.ps1; the runner no longer spells
        # out `copilot -p ...` itself. Those flags are pinned by invoke-agent.tests.ps1.
        Assert-Match '\bInvoke-CopilotAgent\b' $runnerText
        Assert-NotMatch '\bcopilot\b\s+-p\b'   $runnerText
    }

    It 'pins the model on the copilot invocation (opus-4.8 for code review)' {
        Assert-Match "-Model\s+'claude-opus-4\.8'" $runnerText
    }

    It 'resolves recipient via manager.email and prefix via agent.mail_subject_prefix' {
        Assert-Match 'manager\.email'             $runnerText
        Assert-Match 'agent\.mail_subject_prefix' $runnerText
    }

    It 'supports -PRId, -DryRun, -Force, -MaxPerRun flags' {
        Assert-Match '\[int\]\s*\$PRId'         $runnerText
        Assert-Match '\[switch\]\s*\$DryRun'    $runnerText
        Assert-Match '\[switch\]\s*\$Force'     $runnerText
        Assert-Match '\[int\]\s*\$MaxPerRun'    $runnerText
    }

    It 'filters out drafts and self-authored PRs' {
        Assert-Match '\.isDraft'              $runnerText
        Assert-Match 'createdBy\.id\s*-eq\s*\$selfId' $runnerText
    }

    It 'applies the auto-review cutoff filter on the scheduled scan path' {
        Assert-Match 'Get-PrAutoCutoff'                  $runnerText
        Assert-Match 'cutoff\.txt'                       $runnerText
        Assert-Match 'auto-review cutoff filter'         $runnerText
    }

    It 'rescues old PRs where I was added as reviewer after the cutoff' {
        Assert-Match 'Get-AdoSelfDisplayName'                       $runnerText
        Assert-Match 'Get-PullRequestThreads'                       $runnerText
        Assert-Match 'Get-LatestReviewerAddedTimeFromThreads'       $runnerText
        Assert-Match 'rescued \$rescued via late reviewer-add'      $runnerText
    }

    It 'honors migration-mode by skipping seen.json updates' {
        Assert-Match 'migration-mode.*Skipping seen' $runnerText
    }
}

Describe 'pr-review-assistant SKILL.md content' {

    It 'mentions the four severity tiers' {
        Assert-Match 'Blocker'    $skillText
        Assert-Match 'Concern'    $skillText
        Assert-Match 'Suggestion' $skillText
        Assert-Match 'Nit'        $skillText
    }

    It 'documents the four-model review panel (Opus 4.8, GPT-5.5, Codex, Sonnet 4.6)' {
        Assert-Match 'multi-model review panel'  $skillText
        Assert-Match 'claude-opus-4\.8'          $skillText
        Assert-Match 'gpt-5\.5'                  $skillText
        Assert-Match 'gpt-5\.3-codex'            $skillText
        Assert-Match 'claude-sonnet-4\.6'        $skillText
        Assert-Match 'FOUR times IN PARALLEL'    $skillText
    }

    It 'notes Gemini is unavailable as a subagent model' {
        Assert-Match 'Gemini is not available'   $skillText
    }

    It 'documents the scoring rubric and highest-scored selection' {
        Assert-Match '0.?100'                              $skillText
        Assert-Match 'Correctness / grounding'             $skillText
        Assert-Match 'Keep the single highest-scored review' $skillText
        Assert-Match 'Do NOT merge or union the panelists' $skillText
    }

    It 'pins the deterministic tie-break order' {
        Assert-Match 'claude-opus-4\.8` > `gpt-5\.5` > `gpt-5\.3-codex` > `claude-sonnet-4\.6' $skillText
    }

    It 'mentions the ADO MCP tools it expects to call' {
        Assert-Match 'ado-repo_get_pull_request_by_id'           $skillText
        Assert-Match 'ado-repo_get_pull_request_iterations'      $skillText
        Assert-Match 'ado-repo_get_pull_request_iteration_changes' $skillText
        Assert-Match 'ado-repo_list_pull_request_threads'        $skillText
        Assert-Match 'ado-repo_create_pull_request_thread'       $skillText
    }

    It 'forbids auto-vote / auto-approve' {
        Assert-Match 'never vote' $skillText
        Assert-Match 'auto-approve|auto-vote' $skillText
    }

    It 'mandates the name-only signoff and forbids signature/joke in PR comments' {
        Assert-Match 'name-only signoff'    $skillText
        Assert-Match 'No joke'              $skillText
        Assert-Match 'No `Get-NirvanaSignature` HTML signature' $skillText
    }

    It 'documents the size guard thresholds (30 files / 1500 lines)' {
        Assert-Match '30 changed files'  $skillText
        Assert-Match '1500 changed lines' $skillText
    }

    It 'documents the per-iteration report path schema' {
        Assert-Match 'reports\\pr-reviews\\<pr-id>\\iter-<n>\.md' $skillText
    }

    It 'documents migration-mode gating' {
        Assert-Match 'Test-MigrationMode'      $skillText
        Assert-Match 'Migration-mode gating'   $skillText
    }

    It 'documents the cross-skill marker thread step (section 7a)' {
        Assert-Match '7a\.'                         $skillText
        Assert-Match 'nirvana:pr-marker'            $skillText
        Assert-Match 'kind=<reviewed\|size-skipped>' $skillText
        Assert-Match "status=``Closed``"             $skillText
        Assert-Match 'Format-NirvanaPrMarkerBody'   $skillText
    }
}

Describe 'pr-review-assistant helpers - Read-SeenState' {

    It 'returns empty array when file is missing' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "no-such-$(Get-Random).json"
        $r = Read-SeenState -Path $tmp
        Assert-Equal 0 (@($r).Count)
    }

    It 'returns empty array when file is empty' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "empty-$(Get-Random).json"
        Set-Content -Path $tmp -Value '' -Encoding UTF8
        try {
            $r = Read-SeenState -Path $tmp
            Assert-Equal 0 (@($r).Count)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'returns empty array when file is malformed JSON' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "malformed-$(Get-Random).json"
        Set-Content -Path $tmp -Value '{ not json' -Encoding UTF8
        try {
            $r = Read-SeenState -Path $tmp
            Assert-Equal 0 (@($r).Count)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'parses a valid array of records' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "ok-$(Get-Random).json"
        @(
            @{ pr = 12345; iteration = 1; reviewed_at = '2026-05-15T10:00:00+03:00' }
            @{ pr = 67890; iteration = 3; reviewed_at = '2026-05-15T11:00:00+03:00' }
        ) | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
        try {
            $r = @(Read-SeenState -Path $tmp)
            Assert-Equal 2 $r.Count
            Assert-Equal 12345 ([int]$r[0].pr)
            Assert-Equal 3     ([int]$r[1].iteration)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'pr-review-assistant helpers - Test-PrIterationSeen' {

    It 'returns false on empty records' {
        Assert-Equal $false (Test-PrIterationSeen -Records @() -PrId 1 -IterationId 1)
    }

    It 'returns true when (pr,iter) present' {
        $r = @(
            [pscustomobject]@{ pr = 12345; iteration = 1; reviewed_at = 'x' }
            [pscustomobject]@{ pr = 12345; iteration = 2; reviewed_at = 'x' }
        )
        Assert-Equal $true  (Test-PrIterationSeen -Records $r -PrId 12345 -IterationId 1)
        Assert-Equal $true  (Test-PrIterationSeen -Records $r -PrId 12345 -IterationId 2)
        Assert-Equal $false (Test-PrIterationSeen -Records $r -PrId 12345 -IterationId 3)
        Assert-Equal $false (Test-PrIterationSeen -Records $r -PrId 99999 -IterationId 1)
    }
}

Describe 'pr-review-assistant helpers - Add-SeenRecord' {

    It 'creates a new file and appends a record' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "add-$(Get-Random).json"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        try {
            $count = Add-SeenRecord -Path $tmp -PrId 12345 -IterationId 1 -ReviewedAtIso '2026-05-15T10:00:00+03:00'
            Assert-Equal 1 $count
            $r = @(Read-SeenState -Path $tmp)
            Assert-Equal 1 $r.Count
            Assert-Equal 12345 ([int]$r[0].pr)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'replaces an existing record for the same (pr,iter) pair' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "dup-$(Get-Random).json"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        try {
            Add-SeenRecord -Path $tmp -PrId 12345 -IterationId 1 -ReviewedAtIso 'first'  | Out-Null
            Add-SeenRecord -Path $tmp -PrId 12345 -IterationId 1 -ReviewedAtIso 'second' | Out-Null
            $r = @(Read-SeenState -Path $tmp)
            Assert-Equal 1 $r.Count
            Assert-Equal 'second' ([string]$r[0].reviewed_at)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps unrelated records intact' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "multi-$(Get-Random).json"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        try {
            Add-SeenRecord -Path $tmp -PrId 12345 -IterationId 1 -ReviewedAtIso 'a' | Out-Null
            Add-SeenRecord -Path $tmp -PrId 67890 -IterationId 3 -ReviewedAtIso 'b' | Out-Null
            $r = @(Read-SeenState -Path $tmp)
            Assert-Equal 2 $r.Count
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'writes atomically via tmp + rename' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "atomic-$(Get-Random).json"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        try {
            Add-SeenRecord -Path $tmp -PrId 1 -IterationId 1 -ReviewedAtIso 'x' | Out-Null
            Assert-True (Test-Path $tmp)
            Assert-True (-not (Test-Path "$tmp.tmp"))
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'pr-review-assistant helpers - Get-LatestReviewerAddedTimeFromThreads' {

    It 'returns $null when Threads is empty' {
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads @() -SelfDisplayName 'Your Name'
        Assert-True ($null -eq $r)
    }

    It 'returns $null when Threads is $null' {
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $null -SelfDisplayName 'Your Name'
        Assert-True ($null -eq $r)
    }

    It 'returns $null when SelfDisplayName is blank' {
        $threads = @([pscustomobject]@{
            comments = @([pscustomobject]@{
                content       = 'Teammate8 added Your Name as a reviewer'
                publishedDate = '2026-05-17T10:29:19Z'
            })
        })
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName ''
        Assert-True ($null -eq $r)
    }

    It 'returns $null when no thread mentions the self display name' {
        $threads = @(
            [pscustomobject]@{
                comments = @([pscustomobject]@{
                    content       = 'Teammate12 added Teammate99 as a reviewer'
                    publishedDate = '2026-05-17T10:29:19Z'
                })
            },
            [pscustomobject]@{
                comments = @([pscustomobject]@{
                    content       = 'Policy status has been updated'
                    publishedDate = '2026-05-13T07:43:01Z'
                })
            }
        )
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName 'Your Name'
        Assert-True ($null -eq $r)
    }

    It 'returns the latest matching publishedDate as a UTC DateTime' {
        $threads = @(
            [pscustomobject]@{
                comments = @([pscustomobject]@{
                    content       = 'Teammate8 added Your Name as a reviewer'
                    publishedDate = '2026-05-13T10:29:19Z'
                })
            },
            [pscustomobject]@{
                comments = @([pscustomobject]@{
                    content       = 'Teammate12 added Your Name as a reviewer'
                    publishedDate = '2026-05-17T10:29:19Z'
                })
            }
        )
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName 'Your Name'
        Assert-True ($null -ne $r)
        Assert-Equal 'Utc' ([string]$r.Kind)
        Assert-Equal '2026-05-17T10:29:19Z' $r.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    It 'matches case-insensitively' {
        $threads = @([pscustomobject]@{
            comments = @([pscustomobject]@{
                content       = 'someone Added Your Name AS A REVIEWER right now'
                publishedDate = '2026-05-17T10:29:19Z'
            })
        })
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName 'Your Name'
        Assert-True ($null -ne $r)
        Assert-Equal '2026-05-17T10:29:19Z' $r.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    It 'normalizes timezone-offset timestamps to UTC' {
        $threads = @([pscustomobject]@{
            comments = @([pscustomobject]@{
                content       = 'Teammate8 added Your Name as a reviewer'
                publishedDate = '2026-05-17T13:29:19+03:00'
            })
        })
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName 'Your Name'
        Assert-True ($null -ne $r)
        Assert-Equal 'Utc' ([string]$r.Kind)
        Assert-Equal '2026-05-17T10:29:19Z' $r.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    It 'is defensive: ignores comments with missing/blank fields' {
        $threads = @(
            [pscustomobject]@{
                comments = @(
                    [pscustomobject]@{ content = $null; publishedDate = '2026-05-17T10:29:19Z' },
                    [pscustomobject]@{ content = ''   ; publishedDate = '2026-05-17T10:29:19Z' },
                    [pscustomobject]@{ content = 'Teammate12 added Your Name as a reviewer'; publishedDate = $null },
                    [pscustomobject]@{ content = 'Teammate8 added Your Name as a reviewer'  ; publishedDate = 'not-a-date' }
                )
            },
            [pscustomobject]@{ comments = $null },
            $null
        )
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName 'Your Name'
        Assert-True ($null -eq $r)
    }

    It 'requires the display name to be the immediate object of "added"' {
        # Defends against incidental mentions of the name in other contexts.
        $threads = @([pscustomobject]@{
            comments = @([pscustomobject]@{
                content       = 'Your Name commented: please review'
                publishedDate = '2026-05-17T10:29:19Z'
            })
        })
        $r = Get-LatestReviewerAddedTimeFromThreads -Threads $threads -SelfDisplayName 'Your Name'
        Assert-True ($null -eq $r)
    }
}

Describe 'pr-review-assistant helpers - Get-PrAutoCutoff' {

    It 'returns $null when the file is missing' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "no-cutoff-$(Get-Random).txt"
        $r = Get-PrAutoCutoff -Path $tmp
        Assert-True ($null -eq $r)
    }

    It 'returns $null when the file contains only comments and blanks' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "comment-cutoff-$(Get-Random).txt"
        Set-Content -Path $tmp -Value @('# header','','# another comment','') -Encoding UTF8
        try {
            $r = Get-PrAutoCutoff -Path $tmp
            Assert-True ($null -eq $r)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'returns $null on the sentinel "none"' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "none-cutoff-$(Get-Random).txt"
        Set-Content -Path $tmp -Value @('# disabled','none') -Encoding UTF8
        try {
            $r = Get-PrAutoCutoff -Path $tmp
            Assert-True ($null -eq $r)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'returns $null when the active line is unparseable' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "bad-cutoff-$(Get-Random).txt"
        Set-Content -Path $tmp -Value @('# bad','not-a-date') -Encoding UTF8
        try {
            $r = Get-PrAutoCutoff -Path $tmp
            Assert-True ($null -eq $r)
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'parses an ISO 8601 timestamp and normalizes to UTC' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "ok-cutoff-$(Get-Random).txt"
        Set-Content -Path $tmp -Value @('# active','2026-05-15T00:00:00+03:00') -Encoding UTF8
        try {
            $r = Get-PrAutoCutoff -Path $tmp
            Assert-True ($null -ne $r)
            Assert-Equal 'Utc' ([string]$r.Kind)
            # 2026-05-15T00:00 IST == 2026-05-14T21:00 UTC
            Assert-Equal '2026-05-14T21:00:00Z' $r.ToString('yyyy-MM-ddTHH:mm:ssZ')
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'skips comments and uses the first active line' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "first-cutoff-$(Get-Random).txt"
        Set-Content -Path $tmp -Value @('# c1','','2026-01-01T00:00:00Z','2027-01-01T00:00:00Z') -Encoding UTF8
        try {
            $r = Get-PrAutoCutoff -Path $tmp
            Assert-True ($null -ne $r)
            Assert-Equal '2026-01-01T00:00:00Z' $r.ToString('yyyy-MM-ddTHH:mm:ssZ')
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'pr-review-assistant helpers - Resolve-PrReviewReportPath' {

    It 'returns iter-N.md when no file exists yet' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "reports-$(Get-Random)"
        try {
            $p = Resolve-PrReviewReportPath -ReviewsRoot $root -PrId 12345 -IterationId 7
            Assert-Match 'iter-7\.md$' $p
            Assert-Match '12345' $p
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns iter-N-r2.md when iter-N.md already exists' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "reports-$(Get-Random)"
        try {
            $first = Resolve-PrReviewReportPath -ReviewsRoot $root -PrId 12345 -IterationId 7
            Set-Content -Path $first -Value 'placeholder' -Encoding UTF8
            $second = Resolve-PrReviewReportPath -ReviewsRoot $root -PrId 12345 -IterationId 7
            Assert-Match 'iter-7-r2\.md$' $second
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns iter-N-r3.md when iter-N.md and iter-N-r2.md both exist' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "reports-$(Get-Random)"
        try {
            $p1 = Resolve-PrReviewReportPath -ReviewsRoot $root -PrId 12345 -IterationId 7
            Set-Content -Path $p1 -Value 'x' -Encoding UTF8
            $p2 = Resolve-PrReviewReportPath -ReviewsRoot $root -PrId 12345 -IterationId 7
            Set-Content -Path $p2 -Value 'x' -Encoding UTF8
            $p3 = Resolve-PrReviewReportPath -ReviewsRoot $root -PrId 12345 -IterationId 7
            Assert-Match 'iter-7-r3\.md$' $p3
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'creates the per-PR subdirectory' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "reports-$(Get-Random)"
        try {
            $p = Resolve-PrReviewReportPath -ReviewsRoot $root -PrId 9999 -IterationId 1
            Assert-True (Test-Path (Join-Path $root '9999'))
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'pr-review-assistant helpers - Build-PrReviewAgentPrompt' {

    It 'pins all pre-validated inputs into the prompt' {
        $p = Build-PrReviewAgentPrompt `
            -PrId 12345 `
            -IterationId 7 `
            -RepoName 'Azure-Kusto-Service' `
            -ReportPath 'C:\tmp\rpt.md' `
            -IsOnDemand $false `
            -MigrationMode $false `
            -SkillMdPath 'C:\skill.md' `
            -AdoOrg 'your-ado-org' `
            -AdoProject 'One' `
            -ManagerEmail 'you@example.com' `
            -SubjectPrefix '[Nirvana]'
        Assert-Match 'pr-id\s+:\s+12345'             $p
        Assert-Match 'iteration-id\s+:\s+7'          $p
        Assert-Match 'Azure-Kusto-Service'           $p
        Assert-Match 'C:\\tmp\\rpt\.md'              $p
        Assert-Match 'is-on-demand\s+:\s+false'      $p
        Assert-Match 'migration\s+:\s+false'         $p
        Assert-Match "org='your-ado-org'"                 $p
        Assert-Match "project='One'"                 $p
        Assert-Match 'Nir\someone@example.com'     $p
        Assert-Match "subject prefix '\[Nirvana\]'"  $p
    }

    It 'tells the agent to use ALL FOUR severity tiers' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]'
        Assert-Match 'Blocker.*Concern.*Suggestion.*Nit' $p
    }

    It 'switches to migration-mode language when MigrationMode=$true' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $true -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]'
        Assert-Match 'MIGRATION MODE IS ACTIVE'                   $p
        Assert-Match 'Do NOT post any ADO comments'               $p
        Assert-Match 'Do NOT send the email'                      $p
    }

    It 'uses normal-mode language when MigrationMode=$false' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]'
        Assert-Match 'Normal mode\. Post comments to ADO' $p
    }

    It 'reminds the agent that PR comments use the name-only signoff (no joke, no signature)' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]'
        Assert-Match "name-only signoff '-- Nirvana'.*no joke, no HTML signature" $p
    }

    It 'omits the rules block when no DmRulesPaths are provided' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]'
        Assert-NotMatch 'DM review rules' $p
    }

    It 'injects every rules path under a MANDATORY heading when DmRulesPaths is provided' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]' `
            -DmRulesPaths @('C:\rules\dm-review-rules.md', 'C:\rules\extra.md')
        Assert-Match 'DM review rules \(MANDATORY'           $p
        Assert-Match 'C:\\rules\\dm-review-rules\.md'        $p
        Assert-Match 'C:\\rules\\extra\.md'                  $p
        Assert-Match 'Prefix the title of each finding'      $p
        Assert-Match 'Kusto\.Cloud\.Platform is\s+exempt'    $p
    }

    It 'skips null or whitespace entries in DmRulesPaths' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]' `
            -DmRulesPaths @('', '   ', $null)
        Assert-NotMatch 'DM review rules' $p
    }

    It 'instructs the agent to run the four-model panel and keep the highest-scored review' {
        $p = Build-PrReviewAgentPrompt -PrId 1 -IterationId 1 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]'
        Assert-Match 'MULTI-MODEL REVIEW PANEL'   $p
        Assert-Match 'FOUR times IN PARALLEL'     $p
        Assert-Match 'claude-opus-4\.8'           $p
        Assert-Match 'gpt-5\.5'                   $p
        Assert-Match 'gpt-5\.3-codex'             $p
        Assert-Match 'claude-sonnet-4\.6'         $p
        Assert-Match 'KEEP ONLY the single highest-scored review' $p
        Assert-Match 'Do NOT merge panelists'     $p
        Assert-NotMatch 'sub-agent ONCE'          $p
    }

    It 'instructs the agent to post the cross-skill marker thread (kind, status=Closed, pr+iter, suppression rationale)' {
        $p = Build-PrReviewAgentPrompt -PrId 12345 -IterationId 7 -RepoName 'r' -ReportPath 'x' `
            -IsOnDemand $false -MigrationMode $false -SkillMdPath 's' -AdoOrg 'o' -AdoProject 'p' -ManagerEmail 'm' -SubjectPrefix '[Nirvana]'
        Assert-Match "post ONE final marker thread per SKILL section 7a with status='Closed'" $p
        Assert-Match 'nirvana:pr-marker kind=<reviewed\|size-skipped> pr=12345 iteration=7' $p
        Assert-Match "kind='size-skipped' on the size-guard path, kind='reviewed' otherwise" $p
        Assert-Match 'defensive in-PR idempotency signal that complements state/seen\.json' $p
        Assert-Match 'Skip the marker post entirely on the validation-fail abort' $p
    }
}

Describe 'pr-review-assistant helpers - Get-DmReviewRulesPaths' {

    It 'returns @() when the folder is missing' {
        $missing = Join-Path ([IO.Path]::GetTempPath()) "no-such-rules-$(Get-Random)"
        $r = Get-DmReviewRulesPaths -RulesDir $missing
        Assert-Equal 0 ($r | Measure-Object).Count
    }

    It 'returns @() when the folder is empty' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "rules-empty-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        try {
            $r = Get-DmReviewRulesPaths -RulesDir $root
            Assert-Equal 0 ($r | Measure-Object).Count
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns every *.md file, sorted alphabetically, ignoring non-md files' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "rules-pop-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        try {
            New-Item -ItemType File -Path (Join-Path $root 'zeta.md')   -Value '# z'  | Out-Null
            New-Item -ItemType File -Path (Join-Path $root 'alpha.md')  -Value '# a'  | Out-Null
            New-Item -ItemType File -Path (Join-Path $root 'middle.md') -Value '# m'  | Out-Null
            New-Item -ItemType File -Path (Join-Path $root 'skip.txt')  -Value 'skip' | Out-Null
            $r = @(Get-DmReviewRulesPaths -RulesDir $root)
            Assert-Equal 3 $r.Count
            Assert-Match 'alpha\.md$'  $r[0]
            Assert-Match 'middle\.md$' $r[1]
            Assert-Match 'zeta\.md$'   $r[2]
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns the real DM review rules file shipped with the skill' {
        $real = Join-Path $skillDir 'rules'
        $r = @(Get-DmReviewRulesPaths -RulesDir $real)
        Assert-True ($r.Count -ge 1) "expected at least one rules file shipped with the skill"
        Assert-True (($r | Where-Object { $_ -match 'dm-review-rules\.md$' }).Count -ge 1) "expected dm-review-rules.md among shipped rules"
    }
}

Describe 'pr-review-assistant helpers - Format-NirvanaPrMarkerBody (shared)' {

    It 'embeds the canonical HTML-comment marker on the first line for kind=reviewed' {
        $body = Format-NirvanaPrMarkerBody -Kind 'reviewed' -PrId 15725321 -IterationId 3 `
            -At '2026-05-17T19:16:00+03:00' -Findings 4
        $first = ($body -split "`n")[0]
        Assert-Equal '<!-- nirvana:pr-marker kind=reviewed pr=15725321 iteration=3 at=2026-05-17T19:16:00+03:00 findings=4 -->' $first
    }

    It 'embeds the canonical HTML-comment marker on the first line for kind=size-skipped' {
        $body = Format-NirvanaPrMarkerBody -Kind 'size-skipped' -PrId 15725321 -IterationId 3 `
            -At '2026-05-17T19:16:00+03:00' -Findings 0
        $first = ($body -split "`n")[0]
        Assert-Equal '<!-- nirvana:pr-marker kind=size-skipped pr=15725321 iteration=3 at=2026-05-17T19:16:00+03:00 findings=0 -->' $first
    }

    It 'ends with the name-only PR signoff' {
        $body = Format-NirvanaPrMarkerBody -Kind 'reviewed' -PrId 1 -IterationId 1 `
            -At '2026-05-17T19:16:00+03:00' -Findings 0
        Assert-Match '-- Nirvana\s*$' $body
    }

    It 'visible body line differs between kinds' {
        $reviewed = Format-NirvanaPrMarkerBody -Kind 'reviewed' -PrId 1 -IterationId 1 `
            -At '2026-05-17T19:16:00+03:00' -Findings 4
        $skipped  = Format-NirvanaPrMarkerBody -Kind 'size-skipped' -PrId 1 -IterationId 1 `
            -At '2026-05-17T19:16:00+03:00' -Findings 0
        Assert-Match 'auto-review marker .* 4 finding\(s\) posted'     $reviewed
        Assert-Match 'auto-review marker .* size-skipped, no findings' $skipped
    }

    It 'rejects invalid kinds (PowerShell ValidateSet)' {
        $threw = $false
        try {
            Format-NirvanaPrMarkerBody -Kind 'completed' -PrId 1 -IterationId 1 `
                -At '2026-05-17T19:16:00+03:00' -Findings 0 | Out-Null
        } catch {
            $threw = $true
        }
        Assert-Equal $true $threw "expected ValidateSet to reject 'completed'"
    }

    It 'body produced by Format-NirvanaPrMarkerBody matches the regex from Get-NirvanaPrMarkerRegex' {
        $body  = Format-NirvanaPrMarkerBody -Kind 'reviewed' -PrId 15725321 -IterationId 3 `
            -At '2026-05-17T19:16:00+03:00' -Findings 4
        $regex = Get-NirvanaPrMarkerRegex -PrId 15725321 -IterationId 3 -Kind 'reviewed'
        Assert-Match $regex $body
    }

    It 'helpers are also reachable via the shared _shared\pr-marker.ps1 dot-source' {
        $sharedPath = Join-Path $repoRoot '.copilot\skills\_shared\pr-marker.ps1'
        Assert-True (Test-Path $sharedPath) "shared pr-marker.ps1 should exist"
        $sharedText = Get-Content $sharedPath -Raw -Encoding UTF8
        Assert-Match 'function Format-NirvanaPrMarkerBody'  $sharedText
        Assert-Match 'function Get-NirvanaPrMarkerRegex'    $sharedText
        Assert-Match 'function Test-PrHasNirvanaMarker'     $sharedText
    }
}

Exit-WithTestResults

