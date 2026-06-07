# Source-inspection + logic tests for run-logs-cleanup.ps1 and its manifest wiring.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$skillsRoot = Join-Path $PSScriptRoot '..\.copilot\skills'
$runner     = Join-Path $skillsRoot 'run-logs-cleanup.ps1'
$content    = Get-Content -Raw -Encoding UTF8 $runner

Describe 'run-logs-cleanup.ps1 - bootstrap and safety guards' {

    It 'dot-sources _shared/runner-prelude.ps1' {
        Assert-Match '_shared\\runner-prelude\.ps1' $content
    }

    It 'parses without errors' {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$errs)
        Assert-True (($null -eq $errs) -or ($errs.Count -eq 0)) -Because 'runner must parse cleanly'
    }

    It 'guards that $LogDir resolves exactly to <agent-root>\reports\logs' {
        Assert-Match "reports\\logs" $content
        Assert-Match 'Unsafe LogDir' $content
    }

    It 'has a grace-period guard against actively-appending logs' {
        Assert-Match 'AddHours\(-\$GraceHours\)' $content
    }

    It 'never deletes its own log file' {
        Assert-Match '\$selfLogFull' $content
    }

    It 'reads retention/keep/grace from config logs.* with defaults' {
        Assert-Match "logs\.retention_days" $content
        Assert-Match "logs\.keep_min_per_prefix" $content
        Assert-Match "logs\.grace_hours" $content
    }

    It 'supports -DryRun' {
        Assert-Match '\[switch\]\s*\$DryRun' $content
    }

    It 'enumerates non-recursively (flat folder)' {
        Assert-NotMatch 'Get-ChildItem[^\r\n]*-Recurse' $content
    }

    It 'uses an anchored date-suffix prefix regex (not a greedy \d boundary)' {
        Assert-Match "\^\(\?<prefix>\.\+\?\)-\\d\{4\}-\\d\{2\}-\\d\{2\}" $content
        Assert-NotMatch "\[_\-\]\?\\d\.\*\$" $content
    }
}

Describe 'run-logs-cleanup.ps1 - prefix grouping logic' {

    # Mirror the runner's regex to assert grouping behavior on representative names.
    $dateSuffixRe = '^(?<prefix>.+?)-\d{4}-\d{2}-\d{2}(?:[_-]\d{2,6})*$'
    function Get-Prefix([string]$b) { if ($b -match $dateSuffixRe) { return $Matches['prefix'] } return $b }

    It 'groups pr-review-assistant tick logs to the flow prefix' {
        Assert-Equal 'pr-review-assistant' (Get-Prefix 'pr-review-assistant-2026-05-01_1200')
    }

    It 'groups ooo-mode tick logs to the flow prefix' {
        Assert-Equal 'ooo-mode' (Get-Prefix 'ooo-mode-2026-05-19_1005')
    }

    It 'groups daily-date logs to the flow prefix' {
        Assert-Equal 'inbox-watch' (Get-Prefix 'inbox-watch-2026-05-23')
    }

    It 'leaves a dateless basename as its own group' {
        Assert-Equal 'ensure-outlook' (Get-Prefix 'ensure-outlook')
    }

    It 'does not over-trim a hyphenated name that has no date suffix' {
        Assert-Equal 'temp-generate-one-pagers' (Get-Prefix 'temp-generate-one-pagers')
    }
}

Describe 'logs-cleanup - manifest + skill doc' {

    $skillsJson = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\config\skills.json') | ConvertFrom-Json
    $entry = $skillsJson.skills | Where-Object { $_.name -eq 'logs-cleanup' }

    It 'has a skills.json entry' {
        Assert-True ($null -ne $entry) -Because 'logs-cleanup must be registered'
    }

    It 'entrypoint_path points at the runner that exists' {
        Assert-Equal '.copilot/skills/run-logs-cleanup.ps1' $entry.entrypoint_path
        Assert-True (Test-Path (Join-Path $PSScriptRoot (Join-Path '..' $entry.entrypoint_path))) -Because 'entrypoint must exist'
    }

    It 'SKILL.md exists' {
        Assert-True (Test-Path (Join-Path $skillsRoot 'logs-cleanup\SKILL.md')) -Because 'skill doc must exist'
    }
}

Exit-WithTestResults
