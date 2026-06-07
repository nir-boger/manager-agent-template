# Source-inspection tests for the 9 run-*.ps1 runners and inbox-watch-impl.ps1.
# Phase 5b added these tests after every runner was templatized to dot-source
# _shared/runner-prelude.ps1 instead of hard-coding <repo>
# paths, recipient emails, and the [Nirvana] subject prefix.
#
# These are PURPOSEFULLY assertion-style ("uses X") rather than negative-grep
# style ("doesn't contain Y") because some legitimate doc-comment examples may
# carry the agent's own paths (e.g. a header showing how to invoke the runner).

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$skillsRoot = Join-Path $PSScriptRoot '..\.copilot\skills'

# Runners that go through the runner-prelude pattern
$preludeRunners = @(
    'run-inbox-watch.ps1'
    'run-team-milestones-daily.ps1'
    'run-sprint-create.ps1'
    'run-sprint-report-daily.ps1'
    'run-pbi-assign-tasks.ps1'
    'run-agent-todos.ps1'
    'run-personas-import.ps1'
    'run-daily-summary-import.ps1'
    'run-connect-import.ps1'
)

Describe 'run-*.ps1 - runner-prelude usage' {

    foreach ($runner in $preludeRunners) {
        $path = Join-Path $skillsRoot $runner
        if (-not (Test-Path $path)) { continue }
        $content = Get-Content -Raw -Encoding UTF8 $path

        It "$runner dot-sources _shared/runner-prelude.ps1" {
            Assert-Match "_shared\\runner-prelude\.ps1" $content
        }

        It "$runner does NOT hard-code Set-Location 'c:\\dev\\agents\\...'" {
            $hasLiteralCwd = $content -match "(?im)^\s*Set-Location\s+['""]c:\\dev\\agents"
            Assert-True (-not $hasLiteralCwd) -Because "$runner should rely on prelude's Set-Location, not a literal cwd"
        }

        It "$runner does NOT redefine logDir literally as c:\\dev\\agents\\..." {
            $hasLiteralLogDir = $content -match "(?im)\s\`$logDir\s*=\s*['""]c:\\dev\\agents"
            Assert-True (-not $hasLiteralLogDir) -Because "$runner should use \`$LogDir from the prelude"
        }
    }
}

Describe 'run-*.ps1 - configurable email composition' {

    $milestones = Join-Path $skillsRoot 'run-team-milestones-daily.ps1'
    $milestonesContent = Get-Content -Raw -Encoding UTF8 $milestones

    It 'run-team-milestones-daily.ps1 resolves recipient via manager.email' {
        Assert-Match "manager\.email" $milestonesContent
    }

    It 'run-team-milestones-daily.ps1 resolves subject prefix via agent.mail_subject_prefix' {
        Assert-Match "agent\.mail_subject_prefix" $milestonesContent
    }

    It 'run-team-milestones-daily.ps1 does NOT hard-code someone@example.com as a literal recipient' {
        $hasLiteralEmail = $milestonesContent -match "(?im)\\\$mail\.To\s*=\s*['""]youralias@"
        Assert-True (-not $hasLiteralEmail) -Because 'recipient must be from manager.email'
    }

    It 'run-team-milestones-daily.ps1 gates Outlook Send() with Test-MigrationMode' {
        # Send() must be inside a Test-MigrationMode branch
        Assert-Match '(?ims)Test-MigrationMode.*?\$mail\.Send' $milestonesContent
    }
}

Describe 'inbox-watch-impl.ps1 - configurable trigger surface' {

    $impl = Join-Path $skillsRoot 'inbox-watch\inbox-watch-impl.ps1'
    $content = Get-Content -Raw -Encoding UTF8 $impl

    It 'resolves manager email from config' {
        Assert-Match 'manager\.email' $content
    }

    It 'resolves idempotency tag from config' {
        Assert-Match 'agent\.idempotency_tag' $content
    }

    It 'resolves subject prefix from config' {
        Assert-Match 'agent\.mail_subject_prefix' $content
    }

    It 'resolves trigger aliases from config' {
        Assert-Match 'agent\.trigger_aliases' $content
    }

    It 'gates auto-reply Send() with Test-MigrationMode' {
        # Both Send() calls (auto-reply + summary) must be migration-gated.
        $sendCount = ([regex]::Matches($content, 'Test-MigrationMode')).Count
        Assert-True ($sendCount -ge 2) -Because 'both .Send() paths must be gated'
    }
}

Describe 'whatsapp/send-preview-email.ps1 - configurable surface' {

    $path = Join-Path $skillsRoot 'whatsapp\send-preview-email.ps1'
    $content = Get-Content -Raw -Encoding UTF8 $path

    It 'resolves subject prefix via agent.mail_subject_prefix' {
        Assert-Match 'agent\.mail_subject_prefix' $content
    }

    It 'gates Send() with Test-MigrationMode' {
        Assert-Match '(?ims)Test-MigrationMode' $content
    }

    It 'dot-sources signature/config relatively (no c:\\dev\\agents\\... literals in dot-sources)' {
        $hasLiteralDotSource = $content -match "(?im)^\s*\.\s+['""]c:\\dev\\agents"
        Assert-True (-not $hasLiteralDotSource) -Because 'helpers must dot-source via $PSScriptRoot relative paths'
    }
}

Describe 'examples/personal/pilates - configurable surface' {

    $sendEmail = Join-Path $PSScriptRoot '..\examples\personal\pilates\send-email.ps1'
    $sendContent = Get-Content -Raw -Encoding UTF8 $sendEmail

    It 'pilates send-email.ps1 resolves $To from manager.email when not provided' {
        Assert-Match 'manager\.email' $sendContent
    }

    It 'pilates send-email.ps1 gates Send() with Test-MigrationMode' {
        Assert-Match 'Test-MigrationMode' $sendContent
    }

    $registerTasks = Join-Path $PSScriptRoot '..\examples\personal\pilates\register-tasks.ps1'
    $regContent = Get-Content -Raw -Encoding UTF8 $registerTasks

    It 'pilates register-tasks.ps1 resolves task prefix via tasks.prefix' {
        Assert-Match 'tasks\.prefix' $regContent
    }

    It 'pilates register-tasks.ps1 does NOT hard-code "DM-PilatesAuto-" in $taskName assignment' {
        # The literal default is acceptable; the in-loop $taskName must use $taskPrefix
        $hasLiteralTask = $regContent -match '(?im)\$taskName\s*=\s*"DM-PilatesAuto-'
        Assert-True (-not $hasLiteralTask) -Because '$taskName must be derived from $taskPrefix'
    }
}

Describe 'run-*.ps1 - centralized copilot invocation (P1)' {

    # Every runner/impl that spawns the agent must go through the shared
    # Invoke-CopilotAgent helper, never a hand-rolled `& copilot -p $prompt`
    # (which mis-quotes large prompts under wscript -> run-hidden.vbs).
    $agentInvokers = @(
        'run-inbox-watch.ps1'
        'run-agent-todos.ps1'
        'run-pbi-assign-tasks.ps1'
        'run-sprint-create.ps1'
        'run-sprint-report-daily.ps1'
        'run-pr-review-assistant.ps1'
    )

    foreach ($runner in $agentInvokers) {
        $path = Join-Path $skillsRoot $runner
        if (-not (Test-Path $path)) { continue }
        $content = Get-Content -Raw -Encoding UTF8 $path

        It "$runner calls Invoke-CopilotAgent" {
            Assert-Match 'Invoke-CopilotAgent' $content
        }

        It "$runner does NOT hand-roll '& copilot -p `$prompt'" {
            $hasRawInvoke = $content -match '&\s*copilot\s+-p\s+\$'
            Assert-True (-not $hasRawInvoke) -Because "$runner must use Invoke-CopilotAgent"
        }
    }

    It 'runner-prelude.ps1 dot-sources invoke-agent.ps1' {
        $prelude = Get-Content -Raw -Encoding UTF8 (Join-Path $skillsRoot '_shared\runner-prelude.ps1')
        Assert-Match 'invoke-agent\.ps1' $prelude
    }

    It 'runner-prelude.ps1 dot-sources comms.ps1 (P3 channel-adapter)' {
        $prelude = Get-Content -Raw -Encoding UTF8 (Join-Path $skillsRoot '_shared\runner-prelude.ps1')
        Assert-Match 'comms\.ps1' $prelude
    }
}

Exit-WithTestResults


