# Tests for the inbox-watch skill.
#
# Validates:
#   - skill folder + impl + SKILL.md exist
#   - impl enforces SKILL.md §"Never (hard prohibitions)" rule: do NOT auto-reply
#     to threads that already contain `[Nirvana]` in the subject — those belong
#     to a Nirvana-initiated thread (1:1 prep, 1:1 summary, etc.) and the
#     corresponding reply-watcher owns them.
#   - the `nirvana-initiated-thread` skip reason is in the quiet-skip allow-list
#     (no log spam every tick).

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$repoRoot = Split-Path $PSScriptRoot -Parent
$skillDir = Join-Path $repoRoot '.copilot\skills\inbox-watch'
$impl     = Join-Path $skillDir 'inbox-watch-impl.ps1'
$skillMd  = Join-Path $skillDir 'SKILL.md'

if (-not (Test-Path $skillDir)) { throw "skill folder missing: $skillDir" }
if (-not (Test-Path $impl))     { throw "impl missing: $impl" }
if (-not (Test-Path $skillMd))  { throw "SKILL.md missing: $skillMd" }

$implText   = Get-Content $impl   -Raw -Encoding UTF8
$skillText  = Get-Content $skillMd -Raw -Encoding UTF8

Describe 'inbox-watch impl - nirvana-initiated-thread skip rule' {

    It 'defines the nirvana-initiated-thread skip reason' {
        Assert-Match "nirvana-initiated-thread" $implText
    }

    It 'guards on a regex matching Re:/Fwd: [Nirvana ...] subjects' {
        Assert-Match '\(\?i\)\^\(\?:re\|fwd\?\)\\s\*:\\s\*\\\[nirvana' $implText
    }

    It 'includes the skip reason in the quiet-skip allow-list (no log spam)' {
        # The list of "skip reasons that warrant NO log entry" must include the
        # new reason — otherwise every 5-min tick prints "SKIPPED" for every
        # Nirvana-initiated thread the user has open.
        Assert-Match '(?s)\$skipReason\s+-notin\s+@\([^)]*''nirvana-initiated-thread''' $implText
    }
}

Describe 'inbox-watch impl - skip-rule regex behavior (live evaluation)' {
    # Replicate the exact regex from the impl and prove it matches the cases
    # the rule was built for, and ONLY those cases.
    $pattern = '(?i)^(?:re|fwd?)\s*:\s*\[nirvana(?:\s[^\]]*)?\]'

    It 'matches "Re: [Nirvana 1:1 prep] Teammate3"' {
        Assert-True ('Re: [Nirvana 1:1 prep] Teammate3' -match $pattern) "should match prep reply"
    }

    It 'matches "RE: [Nirvana 1:1 summary] Teammate14"' {
        Assert-True ('RE: [Nirvana 1:1 summary] Teammate14' -match $pattern) "should match summary reply"
    }

    It 'matches "Fwd: [Nirvana] arbitrary subject"' {
        Assert-True ('Fwd: [Nirvana] arbitrary subject' -match $pattern) "should match Fwd of Nirvana thread"
    }

    It 'matches "Fw: [Nirvana 1:1 prep] X" (Outlook abbreviated Fw:)' {
        Assert-True ('Fw: [Nirvana 1:1 prep] X' -match $pattern) "should match Fw:"
    }

    It 'matches case-insensitively ("re: [NIRVANA ...]")' {
        Assert-True ('re: [NIRVANA 1:1 prep] X' -match $pattern) "should be case-insensitive"
    }

    It 'tolerates extra whitespace between Re and colon' {
        Assert-True ('Re : [Nirvana 1:1 prep] X' -match $pattern) "should tolerate space before colon"
    }

    It 'does NOT match a plain "[Nirvana 1:1 prep] X" (an outgoing, no Re:)' {
        # Plain outgoing wouldn't appear in inbox anyway, but the regex should
        # be precise.
        Assert-False ('[Nirvana 1:1 prep] X' -match $pattern) "should not match without Re:/Fwd:"
    }

    It 'does NOT match a normal "Hi Nirvana, please..." mail' {
        Assert-False ('Hi Nirvana, please help' -match $pattern) "should not match casual greetings"
    }

    It 'does NOT match a normal "Re: foo" mail' {
        Assert-False ('Re: foo' -match $pattern) "should not match unrelated Re:"
    }

    It 'does NOT match "Re: nirvana update" (no brackets)' {
        Assert-False ('Re: nirvana update' -match $pattern) "should require literal [Nirvana"
    }
}

Describe 'inbox-watch SKILL.md - documents the skip rule' {

    It 'mentions [Nirvana] subject suppression in hard prohibitions or steps' {
        # SKILL.md §"Never (hard prohibitions)" line — exact wording can drift,
        # but the literal phrase "[Nirvana]" must appear in the rule.
        Assert-Match '\[Nirvana\]' $skillText
    }
}

Exit-WithTestResults

