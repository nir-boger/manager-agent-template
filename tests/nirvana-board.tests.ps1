# Tests for the nirvana-board skill.
#
# Covers:
#   * Source hygiene  - serve.py / markdown_io.py / runner / SKILL.md / static
#     files exist and have sane shapes.
#   * Manifest        - config/skills.json carries the nirvana-board entry.
#   * Add helpers     - team-agenda/add-item.py builds a TA-NNN section in
#     the canonical shape (round-tripped through a temp fixture).
#   * Parser+mutator  - markdown_io.py round-trips a close+reopen on PT, TA,
#     and ON shapes without losing fields or breaking section boundaries.
#   * API smoke       - Boot the server on a random high port against a temp
#     repo-root, hit /api/health and /api/board, verify counts.
#
# Strategy: invoke Python helpers via `& python` against ephemeral temp
# fixtures so the real reports/ markdown is never touched.

. (Join-Path $PSScriptRoot '_test-runner.ps1')

# Suppress Invoke-WebRequest progress bars - they can deadlock under some
# redirected-output parent processes (and they're useless in tests anyway).
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path $PSScriptRoot -Parent
$boardDir = Join-Path $repoRoot '.copilot\skills\nirvana-board'
$serveScript = Join-Path $boardDir 'serve.py'
$markdownIo  = Join-Path $boardDir 'markdown_io.py'
$skillDoc    = Join-Path $boardDir 'SKILL.md'
$runner      = Join-Path $repoRoot '.copilot\skills\run-nirvana-board.ps1'
$indexHtml   = Join-Path $boardDir 'static\index.html'
$appJs       = Join-Path $boardDir 'static\app.js'
$styleCss    = Join-Path $boardDir 'static\style.css'
$teamAgendaAdd = Join-Path $repoRoot '.copilot\skills\team-agenda\add-item.py'
$oneOnOneAdd   = Join-Path $repoRoot '.copilot\skills\one-on-one-agenda\add-item.py'
$manifestPath  = Join-Path $repoRoot 'config\skills.json'
$templateHtml  = Join-Path $repoRoot '.copilot\skills\nirvana-site\template.html'

# --- Fixtures hoisted to script scope so It-block scriptblocks can see them.
# (PowerShell scriptblocks passed to It run in a new child of script scope, not
# the Describe-body scope, so any variable used by the It body must live up here.)

$todosFixture = @'
# Personal Todos

---

## Open

### PT-001 — First item

- **Status:** Open
- **Category:** work
- **Priority:** M
- **Created:** 2026-05-20
- **Due:** 2026-05-21
- **Recur:** none
- **Snoozed until:** -
- **Notes:** Some notes.

### PT-002 — Second item

- **Status:** Open
- **Category:** personal
- **Priority:** H
- **Created:** 2026-05-22
- **Due:** -
- **Recur:** none
- **Snoozed until:** -
- **Notes:** -

---

## Done

_(Empty)_
'@

$agendaFixture = @'
# Team Open Discussions

---

## Open

### TA-001 — Test discussion

- **Status:** Open
- **Kind:** Discussion
- **Opened by:** Nir
- **Opened on:** 2026-05-20
- **Owner:** TBD
- **Summary:** -
- **Why it matters:** -
- **Next step:** -

---

## Closed

_(Empty)_
'@

$runnerBody = Get-Content -Path $runner -Raw -Encoding UTF8

Describe 'nirvana-board source hygiene' {
    It 'serve.py exists' { Assert-True (Test-Path $serveScript) }
    It 'markdown_io.py exists' { Assert-True (Test-Path $markdownIo) }
    It 'SKILL.md exists' { Assert-True (Test-Path $skillDoc) }
    It 'runner exists' { Assert-True (Test-Path $runner) }
    It 'static/index.html exists' { Assert-True (Test-Path $indexHtml) }
    It 'static/app.js exists' { Assert-True (Test-Path $appJs) }
    It 'static/style.css exists' { Assert-True (Test-Path $styleCss) }

    It 'serve.py parses to valid Python' {
        $r = & python -c "import ast,sys; ast.parse(open(r'$serveScript', encoding='utf-8').read()); print('ok')"
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal 'ok' ($r.Trim())
    }
    It 'markdown_io.py parses to valid Python' {
        $r = & python -c "import ast,sys; ast.parse(open(r'$markdownIo', encoding='utf-8').read()); print('ok')"
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal 'ok' ($r.Trim())
    }
}

Describe 'team-agenda/add-item.py' {
    It 'exists (new in nirvana-board PR)' { Assert-True (Test-Path $teamAgendaAdd) }

    It 'builds a TA-NNN section in the canonical shape' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-ta-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".md")
        @'
# Team Open Discussions Agenda

---

## Open

_(Empty - new items will land here.)_

---

## Closed

_(Empty)_
'@ | Out-File -FilePath $tmp -Encoding utf8

        try {
            $out = & python $teamAgendaAdd `
                --agenda-file $tmp `
                --title 'Test agenda item' `
                --kind 'discussion' `
                --opened-by 'Nir' `
                --owner 'TBD' `
                --summary 'A test summary.' `
                --why-matters 'Why it matters.' `
                --next-step 'Pick an owner.' `
                --opened-on '2026-05-24'
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match '^TA-\d{3}\tTest agenda item\tdiscussion' ($out.Trim())

            $body = Get-Content $tmp -Raw -Encoding UTF8
            Assert-Match '### TA-001 \u2014 Test agenda item' $body
            Assert-Match '- \*\*Status:\*\* Open' $body
            Assert-Match '- \*\*Kind:\*\* Discussion' $body
            Assert-Match '- \*\*Opened by:\*\* Nir' $body
            Assert-Match '- \*\*Owner:\*\* TBD' $body
            Assert-Match '- \*\*Summary:\*\* A test summary\.' $body
            Assert-Match '- \*\*Why it matters:\*\* Why it matters\.' $body
            Assert-Match '- \*\*Next step:\*\* Pick an owner\.' $body
            Assert-NotMatch '_\(Empty - new items will land here\.\)_' $body
        } finally {
            Remove-Item -Path $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'rejects empty title' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-ta-err-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".md")
        "## Open`n`n## Closed`n" | Out-File -FilePath $tmp -Encoding utf8
        try {
            & python $teamAgendaAdd --agenda-file $tmp --title '   ' 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -ne 0)
        } finally {
            Remove-Item -Path $tmp -ErrorAction SilentlyContinue
        }
    }
}

Describe 'markdown_io parse + mutate' {
    It 'parses 2 open todos, detects overdue, then closes + reopens cleanly' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

text = '''$todosFixture'''
items = mio.parse_todos(text)
print('count', len(items))
for i in items:
    print(i['id'], i['status'], 'overdue=' + str(i['is_overdue']))

closed = mio.mutate_todo(text, 'PT-001', 'close', today='2026-05-24')
items2 = mio.parse_todos(closed)
print('after close')
for i in items2:
    print(i['id'], i['status'])

reopened = mio.mutate_todo(closed, 'PT-001', 'reopen')
items3 = mio.parse_todos(reopened)
print('after reopen')
for i in items3:
    print(i['id'], i['status'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'count 2' $out
            Assert-Match 'PT-001 open overdue=True' $out
            Assert-Match 'PT-002 open overdue=False' $out
            Assert-Match 'after close[\s\S]*PT-001 done' $out
            Assert-Match 'after reopen[\s\S]*PT-001 open' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'snoozes a todo without changing status' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

text = '''$todosFixture'''
snoozed = mio.mutate_todo(text, 'PT-001', 'snooze', snoozed_until='2026-06-01')
items = mio.parse_todos(snoozed)
for i in items:
    if i['id'] == 'PT-001':
        print(i['status'], i['snoozed_until'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'snoozed 2026-06-01' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'closes a TA item and moves it to ## Closed' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

text = '''$agendaFixture'''
closed = mio.mutate_agenda(text, 'TA-001', 'close', today='2026-05-24')
items = mio.parse_agenda(closed)
for i in items:
    print(i['id'], i['status'], i['closed_on'])
open_block = closed.split('## Closed')[0]
closed_block = closed.split('## Closed')[1]
print('in_open =', '### TA-001' in open_block)
print('in_closed =', '### TA-001' in closed_block)
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'TA-001 closed 2026-05-24' $out
            Assert-Match 'in_open = False' $out
            Assert-Match 'in_closed = True' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'markdown_io field-level edit (mutate_*_edit)' {
    It 'mutate_one_on_one_edit rewrites title + fields and preserves section spacing' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

text = '''# Your Manager

## Open

### ON-001 \u2014 First
- **Kind:** discussion
- **Opened by:** Nir
- **Opened on:** 2026-05-20
- **Owner:** Your Manager
- **Status:** Open
- **Summary:** old summary

### ON-002 \u2014 Second
- **Status:** Open
- **Owner:** TBD
'''
out = mio.mutate_one_on_one_edit(text, 'ON-001', {
    'title': 'Renamed topic',
    'owner': 'Nir',
    'summary': 'new summary',
    'why_matters': 'because reasons',
})
print('TITLE:', 'ON-001 \u2014 Renamed topic' in out)
print('OWNER:', '- **Owner:** Nir' in out)
print('SUMMARY:', '- **Summary:** new summary' in out)
print('WHY:', '- **Why it matters:** because reasons' in out)
print('SEP:', '\n\n### ON-002' in out)

# round-trip
items = mio.parse_one_on_one(out)
on1 = [i for i in items if i['id'] == 'ON-001'][0]
print('PARSE_TITLE:', on1['title'])
print('PARSE_OWNER:', on1['owner'])
print('PARSE_STATUS:', on1['status'])
print('OPENED_PRESERVED:', on1['opened_on'])

# clearing a field drops the line
out2 = mio.mutate_one_on_one_edit(out, 'ON-001', {'summary': ''})
items2 = mio.parse_one_on_one(out2)
on1b = [i for i in items2 if i['id'] == 'ON-001'][0]
print('CLEARED:', on1b['summary'] == '')

# unknown field raises
try:
    mio.mutate_one_on_one_edit(text, 'ON-001', {'bogus': 'x'})
    print('UNKNOWN: not raised')
except ValueError as ex:
    print('UNKNOWN:', 'unknown' in str(ex))

# empty title raises
try:
    mio.mutate_one_on_one_edit(text, 'ON-001', {'title': ''})
    print('EMPTY_TITLE: not raised')
except ValueError as ex:
    print('EMPTY_TITLE: raised')

# missing item raises KeyError
try:
    mio.mutate_one_on_one_edit(text, 'ON-099', {'owner': 'X'})
    print('MISSING: not raised')
except KeyError:
    print('MISSING: raised')
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'TITLE: True' $out
            Assert-Match 'OWNER: True' $out
            Assert-Match 'SUMMARY: True' $out
            Assert-Match 'WHY: True' $out
            Assert-Match 'SEP: True' $out
            Assert-Match 'PARSE_TITLE: Renamed topic' $out
            Assert-Match 'PARSE_OWNER: Nir' $out
            Assert-Match 'PARSE_STATUS: open' $out
            Assert-Match 'OPENED_PRESERVED: 2026-05-20' $out
            Assert-Match 'CLEARED: True' $out
            Assert-Match 'UNKNOWN: True' $out
            Assert-Match 'EMPTY_TITLE: raised' $out
            Assert-Match 'MISSING: raised' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'mutate_agenda_edit mirrors mutate_one_on_one_edit on TA shape' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio
text = '''$agendaFixture'''
out = mio.mutate_agenda_edit(text, 'TA-001', {
    'title': 'Updated discussion',
    'summary': 'A real summary now',
    'next_step': 'Decide owner',
})
items = mio.parse_agenda(out)
ta1 = [i for i in items if i['id'] == 'TA-001'][0]
print('TITLE:', ta1['title'])
print('SUM:', ta1['summary'])
print('NEXT:', ta1['next_step'])
print('STATUS_PRESERVED:', ta1['status'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'TITLE: Updated discussion' $out
            Assert-Match 'SUM: A real summary now' $out
            Assert-Match 'NEXT: Decide owner' $out
            Assert-Match 'STATUS_PRESERVED: open' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'AI Plan board (AP-NNN)' {
    It 'team-agenda/add-item.py --id-prefix AP builds an AP-NNN section' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-ap-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".md")
        "## Open`n`n_(Empty)_`n`n---`n`n## Closed`n`n_(Empty)_`n" | Out-File -FilePath $tmp -Encoding utf8
        try {
            $out = & python $teamAgendaAdd `
                --agenda-file $tmp `
                --id-prefix AP `
                --title 'Architect' `
                --kind 'discussion' `
                --opened-by 'Nir' `
                --owner 'TBD' `
                --opened-on '2026-06-01'
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match '^AP-\d{3}\tArchitect\tdiscussion' ($out.Trim())
            $body = Get-Content $tmp -Raw -Encoding UTF8
            Assert-Match '### AP-001 \u2014 Architect' $body
            Assert-Match '- \*\*Status:\*\* Open' $body
        } finally {
            Remove-Item -Path $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a non-uppercase id prefix' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-ap-err-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".md")
        "## Open`n`n## Closed`n" | Out-File -FilePath $tmp -Encoding utf8
        try {
            & python $teamAgendaAdd --agenda-file $tmp --id-prefix 'ap1' --title 'X' 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -ne 0)
        } finally {
            Remove-Item -Path $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'parse_ai_plan + mutate_ai_plan round-trip a close + reopen on the AP shape' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio
text = '''# AI Plan

## Open

### AP-001 \u2014 Architect
- **Status:** Open
- **Kind:** Discussion
- **Opened by:** Nir
- **Owner:** TBD
- **Summary:** -

## Closed

_(Empty)_
'''
items = mio.parse_ai_plan(text)
print('count', len(items))
print('FIRST', items[0]['id'], items[0]['status'])
closed = mio.mutate_ai_plan(text, 'AP-001', 'close', today='2026-06-01')
c = mio.parse_ai_plan(closed)[0]
print('CLOSED', c['status'], c['closed_on'])
print('IN_CLOSED', '### AP-001' in closed.split('## Closed')[1])
reopened = mio.mutate_ai_plan(closed, 'AP-001', 'reopen')
print('REOPENED', mio.parse_ai_plan(reopened)[0]['status'])
edited = mio.mutate_ai_plan_edit(text, 'AP-001', {'summary': 'a real summary'})
print('EDIT', mio.parse_ai_plan(edited)[0]['summary'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'count 1' $out
            Assert-Match 'FIRST AP-001 open' $out
            Assert-Match 'CLOSED closed 2026-06-01' $out
            Assert-Match 'IN_CLOSED True' $out
            Assert-Match 'REOPENED open' $out
            Assert-Match 'EDIT a real summary' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'serve.py wires the AI Plan store, ops, and routes' {
        $serveText = Get-Content $serveScript -Raw -Encoding UTF8
        Assert-Match 'ai_plan_md' $serveText
        Assert-Match 'parse_ai_plan' $serveText
        Assert-Match 'VALID_AP_OPS' $serveText
        Assert-Match '/api/ai-plan' $serveText
        Assert-Match '/api/ai-plan/\(AP-' $serveText
    }

    It 'static UI exposes the AI Plan tab and actions' {
        $indexText = Get-Content $indexHtml -Raw -Encoding UTF8
        $appText   = Get-Content $appJs -Raw -Encoding UTF8
        Assert-Match 'data-tab="ai-plan"' $indexText
        Assert-Match 'count-ai-plan' $indexText
        Assert-Match 'data-act="edit-ai-plan"' $appText
        Assert-Match 'close-ai-plan' $appText
        Assert-Match '/api/ai-plan/' $appText
    }
}

Describe 'Multi-line field values survive the save round-trip (real newlines, no <br>)' {
    It 'mutate_one_on_one_edit stores newlines as real continuation lines (never <br>) and round-trips them back' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

text = '''# Maya

## Open

### ON-001 \u2014 Retro
- **Status:** Open
- **Owner:** TBD
- **Summary:** old
- **Why it matters:** -
'''
out = mio.mutate_one_on_one_edit(text, 'ON-001', {'summary': 'line one\nline two\nline three'})
lines = out.splitlines()
i = [n for n, l in enumerate(lines) if l.startswith('- **Summary:**')][0]
print('STORED_HEAD:', lines[i] == '- **Summary:** line one')
print('STORED_CONT1:', lines[i+1] == 'line two')
print('STORED_CONT2:', lines[i+2] == 'line three')
print('NO_BR_IN_DISK:', '<br>' not in out)
print('WHY_INTACT:', lines[i+3] == '- **Why it matters:** -')
items = mio.parse_one_on_one(out)
s = [i for i in items if i['id'] == 'ON-001'][0]['summary']
print('ROUNDTRIP:', s == 'line one\nline two\nline three')
print('NO_BR_IN_JSON:', '<br>' not in s)
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'STORED_HEAD: True' $out
            Assert-Match 'STORED_CONT1: True' $out
            Assert-Match 'STORED_CONT2: True' $out
            Assert-Match 'NO_BR_IN_DISK: True' $out
            Assert-Match 'WHY_INTACT: True' $out
            Assert-Match 'ROUNDTRIP: True' $out
            Assert-Match 'NO_BR_IN_JSON: True' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'editing a single-line field leaves an existing multi-line summary (and its breaks) intact' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

text = '''# Maya

## Open

### ON-001 \u2014 Retro
- **Status:** Open
- **Owner:** TBD
- **Summary:** first
second
third
- **Why it matters:** -
'''
out = mio.mutate_one_on_one_edit(text, 'ON-001', {'owner': 'Maya'})
items = mio.parse_one_on_one(out)
it = [i for i in items if i['id'] == 'ON-001'][0]
print('OWNER:', it['owner'] == 'Maya')
print('SUMMARY:', it['summary'] == 'first\nsecond\nthird')
print('NO_BR:', '<br>' not in out)
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'OWNER: True' $out
            Assert-Match 'SUMMARY: True' $out
            Assert-Match 'NO_BR: True' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'clearing a multi-line field drops the head line AND its continuation lines' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

text = '''# Maya

## Open

### ON-001 \u2014 Retro
- **Status:** Open
- **Summary:** first
second
third
- **Owner:** TBD
'''
out = mio.mutate_one_on_one_edit(text, 'ON-001', {'summary': ''})
print('NO_SUMMARY:', '- **Summary:**' not in out)
print('NO_ORPHAN_CONT:', 'second' not in out and 'third' not in out)
print('OWNER_INTACT:', '- **Owner:** TBD' in out)
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'NO_SUMMARY: True' $out
            Assert-Match 'NO_ORPHAN_CONT: True' $out
            Assert-Match 'OWNER_INTACT: True' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'parse reads real continuation lines AND still decodes any legacy <br> to newlines' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-py-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import markdown_io as mio

# ON-001 uses the canonical real-newline form; ON-002 carries a legacy <br>.
text = '''# Maya

## Open

### ON-001 \u2014 Real newline form
- **Status:** Open
- **Summary:** first line
second line
third line
- **Owner:** TBD

### ON-002 \u2014 Legacy form
- **Status:** Open
- **Summary:** a<br>b
'''
items = mio.parse_one_on_one(text)
on1 = [i for i in items if i['id'] == 'ON-001'][0]
on2 = [i for i in items if i['id'] == 'ON-002'][0]
print('REAL_FORM:', on1['summary'] == 'first line\nsecond line\nthird line')
print('OWNER_INTACT:', on1['owner'] == 'TBD')
print('LEGACY_FORM:', on2['summary'] == 'a\nb')
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'REAL_FORM: True' $out
            Assert-Match 'OWNER_INTACT: True' $out
            Assert-Match 'LEGACY_FORM: True' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'one-on-one add-item.py writes a multi-line summary as real continuation lines (no <br>)' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-on-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".md")
        try {
            $out = & python $oneOnOneAdd --agenda-file $tmp --person 'Test' --title 'T' --summary "alpha`nbeta" --dry-run 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match '- \*\*Summary:\*\* alpha' $out
            Assert-Match '(?m)^beta\s*$' $out
            if ($out -match '<br>') { throw "add-item.py wrote a <br> token: $out" }
        } finally {
            Remove-Item -Path $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'board app.js exposes escMultiline and uses it for the summary card' {
        $appJsBody = Get-Content -Path $appJs -Raw -Encoding UTF8
        Assert-Match 'const escMultiline =' $appJsBody
        Assert-Match 'escMultiline\(item\.summary\)' $appJsBody
    }
}


Describe 'Board static carries edit-line UI (Phase A4)' {
    $appJsBody = Get-Content -Path $appJs -Raw -Encoding UTF8
    It 'cardClosedStyle emits an edit-agenda button' {
        Assert-Match 'data-act="edit-agenda"' $appJsBody
    }
    It 'cardClosedStyle emits an edit-on button' {
        Assert-Match 'data-act="edit-on"' $appJsBody
    }
    It 'onCardsClick handles edit-agenda + edit-on' {
        Assert-Match 'act === "edit-agenda"' $appJsBody
        Assert-Match 'act === "edit-on"' $appJsBody
    }
    It 'has openEditModal + submitEdit + MODAL_MODE' {
        Assert-Match 'function openEditModal' $appJsBody
        Assert-Match 'function submitEdit' $appJsBody
        Assert-Match 'MODAL_MODE' $appJsBody
    }
    It 'submitEdit PATCHes with action=edit and a fields dict' {
        Assert-Match 'action: "edit", fields:' $appJsBody
    }
    It 'logo uses normal template literal (no String.raw)' {
        Assert-Match 'const ASCII =' $appJsBody
        # String.raw is a footgun for backslash-laden ASCII; the logo block
        # must NOT use it. Only the first ~1.5KB matters.
        $head = $appJsBody.Substring(0, [Math]::Min(1500, $appJsBody.Length))
        Assert-NotMatch 'String\.raw' $head
    }
}


Describe 'manifest entry' {
    $manifest = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $skill = $manifest.skills | Where-Object { $_.name -eq 'nirvana-board' }

    It 'has a nirvana-board entry in config/skills.json' {
        Assert-True ($null -ne $skill)
    }
    It 'entry surface = engine' { Assert-Equal 'engine' $skill.surface }
    It 'entry path points at the skill folder' {
        Assert-Equal '.copilot/skills/nirvana-board' $skill.path
    }
    It 'entry entrypoint_path points at the runner' {
        Assert-Equal '.copilot/skills/run-nirvana-board.ps1' $skill.entrypoint_path
    }
    It 'entry triggers include the primary launch phrase' {
        Assert-Contains 'open my board' $skill.triggers
    }
    It 'entry triggers include the stop phrase' {
        Assert-Contains 'stop the board' $skill.triggers
    }
    It 'entry is visible in AGENTS.md' { Assert-True $skill.show_in_agents }
}

Describe 'directs resolver (Phase B1)' {
    It 'resolves 14 directs from the real scope-board + persona files with smtps' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-directs-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
from pathlib import Path
sys.path.insert(0, r'$boardDir')
from directs import resolve_directs, slugify
repo = Path(r'$repoRoot')
res = resolve_directs(repo / 'reports' / 'directs-scope' / 'scope-board.md',
                      repo / '.copilot' / 'skills' / 'team-personas' / 'people')
print('count', len(res))
with_smtp = sum(1 for d in res if d.get('smtp'))
print('with_smtp', with_smtp)
slugs = sorted(d['slug'] for d in res)
print('slugs', ','.join(slugs))
print('slugify_simple', slugify('Teammate1'))
print('slugify_three',  slugify('Teammate9'))
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'count 14' $out
            Assert-Match 'with_smtp 14' $out
            Assert-Match 'slugify_simple Teammate1-Teammate1' $out
            Assert-Match 'slugify_three ran-ben-Teammate9' $out
            Assert-Match 'Teammate1-Teammate1' $out
            Assert-Match 'Teammate14-Teammate14' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'returns empty list when the scope-board is missing' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-directs-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys, tempfile
from pathlib import Path
sys.path.insert(0, r'$boardDir')
from directs import resolve_directs
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / 'missing.md'
    res = resolve_directs(p, Path(td))
    print('count', len(res))
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'count 0' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'board snapshot bootstraps + decorates 1:1s (Phase B2+B3)' {
    It 'creates missing <slug>.md stubs and embeds scope_now/scope_next' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-bootstrap-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys, tempfile, json, shutil
from pathlib import Path
sys.path.insert(0, r'$boardDir')
import serve as srv

repo_src = Path(r'$repoRoot')
with tempfile.TemporaryDirectory() as td:
    repo = Path(td)
    # Stage scope-board + persona files; skip pre-existing 1:1 markdown so we
    # observe a fresh bootstrap.
    (repo / 'reports' / 'directs-scope').mkdir(parents=True)
    shutil.copy2(repo_src / 'reports' / 'directs-scope' / 'scope-board.md',
                 repo / 'reports' / 'directs-scope' / 'scope-board.md')
    src_personas = repo_src / '.copilot' / 'skills' / 'team-personas' / 'people'
    dst_personas = repo / '.copilot' / 'skills' / 'team-personas' / 'people'
    dst_personas.mkdir(parents=True)
    for f in src_personas.glob('*.md'):
        shutil.copy2(f, dst_personas / f.name)

    paths = srv.Paths(repo)
    snap = srv.board_snapshot(paths)
    print('directs', snap['counts'].get('directs', 0))
    print('partners', len(snap['one_on_ones']))
    # The 14 directs should now have stub files.
    stub_count = sum(1 for f in (repo / 'reports' / 'one-on-ones').glob('*.md'))
    print('stub_count', stub_count)
    # Pick one direct and assert the scope cells came through.
    Teammate1 = next(p for p in snap['one_on_ones'] if p['slug'] == 'Teammate1-Teammate1')
    print('asaf_is_direct', Teammate1['is_direct'])
    print('asaf_smtp', Teammate1['smtp'])
    print('asaf_scope_now_present', bool(Teammate1['scope_now']))
    print('asaf_scope_now_html_present', bool(Teammate1['scope_now_html']))
    # A second snapshot must NOT recreate or rewrite the stubs (idempotency).
    mtime0 = (repo / 'reports' / 'one-on-ones' / 'Teammate1-Teammate1.md').stat().st_mtime
    snap2 = srv.board_snapshot(paths)
    mtime1 = (repo / 'reports' / 'one-on-ones' / 'Teammate1-Teammate1.md').stat().st_mtime
    print('mtime_stable', mtime0 == mtime1)
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'directs 14' $out
            Assert-Match 'partners 14' $out
            Assert-Match 'stub_count 14' $out
            Assert-Match 'asaf_is_direct True' $out
            Assert-Match 'asaf_smtp someone@example.com' $out
            Assert-Match 'asaf_scope_now_present True' $out
            Assert-Match 'asaf_scope_now_html_present True' $out
            Assert-Match 'mtime_stable True' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Board static carries per-direct scope header (Phase B4)' {
    $appJsBody = Get-Content -Path $appJs -Raw -Encoding UTF8
    $styleBody = Get-Content -Path $styleCss -Raw -Encoding UTF8
    It 'app.js defines renderDirectScopeHeader' {
        Assert-Match 'function renderDirectScopeHeader' $appJsBody
    }
    It 'app.js renders the header on the one-on-ones tab' {
        Assert-Match 'const headerCard = renderDirectScopeHeader\(partner\)' $appJsBody
    }
    It 'app.js wires the "scope board >>" link to switch tabs' {
        Assert-Match 'goto-scope-board' $appJsBody
    }
    It 'app.js paints a dot per partner indicating direct vs. peer' {
        Assert-Match 'dot.direct|dot direct' $appJsBody
        Assert-Match 'dot.peer|dot peer'     $appJsBody
    }
    It 'style.css carries .card.direct-scope-header + .scope-grid + .scope-cell' {
        Assert-Match '\.card\.direct-scope-header' $styleBody
        Assert-Match '\.scope-grid'                $styleBody
        Assert-Match '\.scope-cell'                $styleBody
    }
}

Describe 'runner shape (run-nirvana-board.ps1)' {
    It 'declares -Port and -Stop flags' {
        Assert-Match '\[int\]\s*\$Port' $runnerBody
        Assert-Match '\[switch\]\s*\$Stop' $runnerBody
        Assert-Match '\[switch\]\s*\$NoBrowser' $runnerBody
    }
    It 'sources the runner-prelude' {
        Assert-Match "runner-prelude\.ps1" $runnerBody
    }
    It 'launches python with serve.py' {
        Assert-Match 'serve\.py' $runnerBody
        Assert-Match 'Start-Process' $runnerBody
    }
    It 'writes PID + port files for stop/status idempotency' {
        Assert-Match 'server\.pid' $runnerBody
        Assert-Match 'server\.port' $runnerBody
    }
}

Describe 'API smoke (live server)' {
    # Pick a high port unlikely to clash.
    $port = 5793
    $proc = $null
    try {
        $proc = Start-Process -FilePath 'python' `
            -ArgumentList @($serveScript, '--port', "$port") `
            -WorkingDirectory $repoRoot `
            -WindowStyle Hidden `
            -PassThru
        # Wait for /api/health.
        $ok = $false
        for ($i=0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 200
            if ($proc.HasExited) { break }
            try {
                $h = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 1
                if ($h.StatusCode -eq 200) { $ok = $true; break }
            } catch { }
        }
        It 'starts and answers /api/health' { Assert-True $ok }

        It '/api/health returns ok=true with version' {
            $health = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 3
            Assert-Match '"ok":\s*true' $health.Content
            Assert-Match '"version":\s*"\d+\.\d+\.\d+"' $health.Content
        }

        It '/api/board returns the three lists' {
            $board = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/board" -TimeoutSec 5
            $bj = $board.Content | ConvertFrom-Json
            Assert-True ($null -ne $bj.todos)
            Assert-True ($null -ne $bj.agenda)
            Assert-True ($null -ne $bj.one_on_ones)
            Assert-True ($null -ne $bj.counts)
        }

        It '/api/board reports a non-negative counts.todos_open' {
            $board = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/board" -TimeoutSec 5
            $bj = $board.Content | ConvertFrom-Json
            Assert-True ($bj.counts.todos_open -ge 0)
        }

        It '/ serves the index.html' {
            $idx = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/" -TimeoutSec 3
            Assert-Equal 200 $idx.StatusCode
            Assert-Match 'Nirvana Board' $idx.Content
        }

        It '/api/scheduled-tasks returns tasks + count + available' {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/scheduled-tasks" -TimeoutSec 30
            Assert-Equal 200 $resp.StatusCode
            $sj = $resp.Content | ConvertFrom-Json
            Assert-True ($sj.count -ge 0)
            Assert-True ($sj.PSObject.Properties.Name -contains 'tasks')
            Assert-True ($sj.PSObject.Properties.Name -contains 'available')
            if ($sj.count -gt 0) {
                Assert-True ($sj.tasks[0].PSObject.Properties.Name -contains 'explanation')
            }
        }

        It '/api/scheduled-tasks?refresh=1 forces a re-enumerate and returns 200' {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/scheduled-tasks?refresh=1" -TimeoutSec 30
            Assert-Equal 200 $resp.StatusCode
        }

        It '/api/todos POST rejects empty title with 400' {
            $threw = $false
            try {
                Invoke-WebRequest -UseBasicParsing -Method POST `
                    -Uri "http://127.0.0.1:$port/api/todos" `
                    -ContentType 'application/json' `
                    -Body '{"title":""}' -TimeoutSec 3 | Out-Null
            } catch {
                $threw = $true
                Assert-Match '400' $_.Exception.Message
            }
            Assert-True $threw
        }

        It 'PATCH /api/todos/<bad-id> returns an HTTP error' {
            $threw = $false
            try {
                Invoke-WebRequest -UseBasicParsing -Method PATCH `
                    -Uri "http://127.0.0.1:$port/api/todos/PT-XYZ" `
                    -ContentType 'application/json' `
                    -Body '{"action":"close"}' -TimeoutSec 3 | Out-Null
            } catch {
                $threw = $true
                Assert-Match '(400|404)' $_.Exception.Message
            }
            Assert-True $threw
        }

        # /explorer route - co-hosts the Nirvana Explorer single-file HTML
        # built by the nirvana-site skill. The artifact may or may not exist
        # at the moment the test runs; both shapes must respond cleanly.
        It '/explorer responds (200 with Explorer HTML, or 503 with rebuild hint)' {
            $explorerArtifact = Join-Path $repoRoot 'reports\site\nirvana.html'
            $expectExists = Test-Path $explorerArtifact
            $resp = $null
            $caught = $null
            try {
                $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/explorer" -TimeoutSec 15
            } catch {
                $caught = $_
            }
            if ($null -ne $resp) {
                Assert-Equal 200 $resp.StatusCode
                Assert-Match '(?i)nirvana[\s-]*explorer' $resp.Content
            } elseif ($null -ne $caught) {
                # Only acceptable error is the 503 fallback (artifact missing).
                Assert-Match '503' $caught.Exception.Message
                Assert-True (-not $expectExists) "Got 503 from /explorer but artifact exists at $explorerArtifact"
            } else {
                throw "Neither response nor exception captured from /explorer (expectExists=$expectExists)"
            }
        }

        It '/explorer/ (trailing slash) and /explorer.html alias also resolve' {
            foreach ($alias in @('/explorer/', '/explorer.html')) {
                $resp = $null
                $caught = $null
                try {
                    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port$alias" -TimeoutSec 15
                } catch {
                    $caught = $_
                }
                $is200 = ($null -ne $resp -and $resp.StatusCode -eq 200)
                $is503 = ($null -ne $caught -and $caught.Exception.Message -match '503')
                if (-not ($is200 -or $is503)) {
                    $detail = if ($resp) { "status=$($resp.StatusCode)" } elseif ($caught) { "err=$($caught.Exception.Message)" } else { 'no response/exception' }
                    throw "Alias $alias did not return 200 or 503: $detail"
                }
            }
        }
        It '/api/my-day returns meetings + needs_attention + focus + stats' {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/my-day" -TimeoutSec 60
            Assert-Equal 200 $resp.StatusCode
            $mj = $resp.Content | ConvertFrom-Json
            Assert-True ($mj.PSObject.Properties.Name -contains 'meetings')
            Assert-True ($mj.PSObject.Properties.Name -contains 'needs_attention')
            Assert-True ($mj.PSObject.Properties.Name -contains 'focus')
            Assert-True ($mj.PSObject.Properties.Name -contains 'stats')
            Assert-True ($mj.PSObject.Properties.Name -contains 'calendar_available')
            Assert-True ($mj.stats.meetings -ge 0)
            Assert-True ($mj.stats.needs_attention -ge 0)
        }

        It '/api/my-day?refresh=1 forces a re-read and returns 200' {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/my-day?refresh=1" -TimeoutSec 60
            Assert-Equal 200 $resp.StatusCode
        }

    } finally {
        if ($proc -and -not $proc.HasExited) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

Describe 'Explorer cross-link integration' {
    It 'serve.py declares EXPLORER_ARTIFACT pointing at reports/site/nirvana.html' {
        $serveText = Get-Content -Path $serveScript -Raw -Encoding UTF8
        Assert-Match 'EXPLORER_ARTIFACT' $serveText
        Assert-Match 'reports.*site.*nirvana\.html' $serveText
    }
    It 'serve.py defines _write_explorer with a 503 fallback' {
        $serveText = Get-Content -Path $serveScript -Raw -Encoding UTF8
        Assert-Match '_write_explorer' $serveText
        Assert-Match '503' $serveText
    }
    It 'serve.py routes /explorer (with bare/trailing/.html aliases)' {
        $serveText = Get-Content -Path $serveScript -Raw -Encoding UTF8
        Assert-Match '/explorer' $serveText
    }
    It 'board topbar carries an Explorer pill' {
        $indexText = Get-Content -Path $indexHtml -Raw -Encoding UTF8
        Assert-Match 'topbar-link' $indexText
        Assert-Match 'href="/explorer"' $indexText
        Assert-Match 'Explorer' $indexText
    }
    It 'board style.css defines .topbar-link' {
        $styleText = Get-Content -Path $styleCss -Raw -Encoding UTF8
        Assert-Match '\.topbar-link' $styleText
    }
    It 'Explorer template carries a Board pill anchored at localhost:5180' {
        $templateText = Get-Content -Path $templateHtml -Raw -Encoding UTF8
        Assert-Match 'topbar-link' $templateText
        Assert-Match 'id="board-link"' $templateText
        Assert-Match 'localhost:5180' $templateText
    }
    It 'Explorer template includes a live /api/health probe' {
        $templateText = Get-Content -Path $templateHtml -Raw -Encoding UTF8
        Assert-Match '/api/health' $templateText
        Assert-Match 'AbortController' $templateText
    }
}

Describe 'scope-board parser + mutator' {
    $scopeBoardIo = Join-Path $boardDir 'scope_board_io.py'

    It 'scope_board_io.py exists' { Assert-True (Test-Path $scopeBoardIo) }

    It 'scope_board_io.py parses to valid Python' {
        $r = & python -c "import ast; ast.parse(open(r'$scopeBoardIo', encoding='utf-8').read()); print('ok')"
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal 'ok' ($r.Trim())
    }

    It 'parse_scope_board returns tables/rows/cells with raw + html' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sb-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys, json
sys.path.insert(0, r'$boardDir')
import scope_board_io as sb

text = '''# Scope Board

## Open

| Direct | Now | Next scope |
|---|---|---|
| **Teammate2** | On maternity leave | **EG Dedup** |
| **Teammate8** | **AKS Intro** | _TBD_ |

## Closed

| Direct | Scope | When |
|---|---|---|
| _(empty)_ |  |  |
'''
p = sb.parse_scope_board(text)
print('tables', len(p['tables']))
print('t0_heading', p['tables'][0]['heading'])
print('t0_cols', p['tables'][0]['columns'])
print('t0_rows', len(p['tables'][0]['rows']))
print('cell00_raw', p['tables'][0]['rows'][0]['cells'][0]['raw'])
print('cell00_html', p['tables'][0]['rows'][0]['cells'][0]['html'])
print('cell12_raw', p['tables'][0]['rows'][1]['cells'][2]['raw'])
print('t1_heading', p['tables'][1]['heading'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'tables 2' $out
            Assert-Match 't0_heading Open' $out
            Assert-Match "t0_cols \['Direct', 'Now', 'Next scope'\]" $out
            Assert-Match 't0_rows 2' $out
            Assert-Match 'cell00_raw \*\*Teammate2\*\*' $out
            Assert-Match 'cell00_html <strong>Teammate2</strong>' $out
            Assert-Match 'cell12_raw _TBD_' $out
            Assert-Match 't1_heading Closed' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'mutate_scope_board_cell rewrites the targeted cell only' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sb-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import scope_board_io as sb

text = '''# Scope Board

## Open

| Direct | Now | Next scope |
|---|---|---|
| **Teammate2** | On maternity leave | **EG Dedup** |
| **Teammate8** | **AKS Intro** | _TBD_ |
'''
new = sb.mutate_scope_board_cell(text, 0, 0, 1, 'Back from leave (parent role)')
print('lines_same', len(text.splitlines()) == len(new.splitlines()))
for ln in new.splitlines():
    if 'Teammate2' in ln:
        print('LEA', ln)
    if 'Teammate8' in ln:
        print('OZ', ln)
# Round-trip parse should reflect the mutation.
p = sb.parse_scope_board(new)
print('parsed_now', p['tables'][0]['rows'][0]['cells'][1]['raw'])
print('parsed_oz_now', p['tables'][0]['rows'][1]['cells'][1]['raw'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'lines_same True' $out
            Assert-Match 'LEA \| \*\*Teammate2\*\* \| Back from leave \(parent role\) \| \*\*EG Dedup\*\* \|' $out
            Assert-Match 'OZ \| \*\*Teammate8\*\* \| \*\*AKS Intro\*\* \| _TBD_ \|' $out
            Assert-Match 'parsed_now Back from leave \(parent role\)' $out
            Assert-Match 'parsed_oz_now \*\*AKS Intro\*\*' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'mutate_scope_board_cell rejects out-of-range indices' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sb-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import scope_board_io as sb

text = '''| A | B |
|---|---|
| x | y |
'''
for case in [(5,0,0), (0,5,0), (0,0,5), (-1,0,0)]:
    try:
        sb.mutate_scope_board_cell(text, *case, 'z')
        print('no_error', case)
    except ValueError as ex:
        print('rejected', case)
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'rejected \(5, 0, 0\)' $out
            Assert-Match 'rejected \(0, 5, 0\)' $out
            Assert-Match 'rejected \(0, 0, 5\)' $out
            Assert-Match 'rejected \(-1, 0, 0\)' $out
            Assert-NotMatch 'no_error' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'mutate_scope_board_cell escapes embedded pipes' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sb-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import scope_board_io as sb

text = '''| Direct | Now |
|---|---|
| **X** | y |
'''
new = sb.mutate_scope_board_cell(text, 0, 0, 1, 'a | b | c')
for ln in new.splitlines():
    if ('X' in ln) and ('|' in ln) and (not ln.startswith('|---')):
        print('ROW=' + ln)
# Round-trip - the pipe should survive unescaped on the parse side.
p = sb.parse_scope_board(new)
print('roundtrip=' + p['tables'][0]['rows'][0]['cells'][1]['raw'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            # One backslash + pipe per embedded `|` in the new cell value.
            Assert-Match 'ROW=\| \*\*X\*\* \| a \\\| b \\\| c \|' $out
            Assert-Match 'roundtrip=a \| b \| c' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'scope-board API smoke (live server)' {
    $port = 5794
    $proc = $null
    # Stage a temp repo-root with a minimal scope-board file so we never
    # touch reports/directs-scope/scope-board.md.
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-root-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $tmpScopeDir = Join-Path $tmpRoot 'reports\directs-scope'
    New-Item -ItemType Directory -Force -Path $tmpScopeDir | Out-Null
    # Minimal todos/agenda dirs so serve.py doesn't warn-then-crash.
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'reports\personal-todos') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'reports\team-agenda') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'reports\one-on-ones') | Out-Null
    Set-Content -Path (Join-Path $tmpRoot 'reports\personal-todos\todos.md') -Value "# Todos`n`n## Open`n_(Empty)_`n`n## Done`n_(Empty)_`n" -Encoding utf8
    Set-Content -Path (Join-Path $tmpRoot 'reports\team-agenda\open-discussions.md') -Value "# Agenda`n`n## Open`n_(Empty)_`n`n## Closed`n_(Empty)_`n" -Encoding utf8

    $scopeMd = Join-Path $tmpScopeDir 'scope-board.md'
    @"
# Directs Scope Board

## Open

| Direct | Now | Next scope |
|---|---|---|
| **Alice** | Building X | **Y next** |
| **Bob** | Reviewing Z | _TBD_ |

## Closed

| Direct | Scope | Locked on | ADO |
|---|---|---|---|
| _(empty)_ |  |  |  |
"@ | Out-File -FilePath $scopeMd -Encoding utf8

    try {
        $proc = Start-Process -FilePath 'python' `
            -ArgumentList @($serveScript, '--port', "$port", '--repo-root', $tmpRoot) `
            -WorkingDirectory $repoRoot `
            -WindowStyle Hidden `
            -PassThru
        $ok = $false
        for ($i=0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 200
            if ($proc.HasExited) { break }
            try {
                $h = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 1
                if ($h.StatusCode -eq 200) { $ok = $true; break }
            } catch { }
        }
        It 'server starts against temp repo-root' { Assert-True $ok }

        It 'GET /api/scope-board returns the parsed tables' {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/scope-board" -TimeoutSec 5
            Assert-Equal 200 $resp.StatusCode
            $j = $resp.Content | ConvertFrom-Json
            Assert-True $j.exists
            Assert-Equal 2 $j.tables.Count
            Assert-Equal 'Open' $j.tables[0].heading
            Assert-Equal 'Closed' $j.tables[1].heading
            Assert-Equal 2 $j.tables[0].rows.Count
            Assert-Equal '**Alice**' $j.tables[0].rows[0].cells[0].raw
            Assert-Match '<strong>Alice</strong>' $j.tables[0].rows[0].cells[0].html
        }

        It 'PATCH /api/scope-board updates one cell and persists' {
            $body = '{"table":0,"row":1,"col":1,"value":"Now building W"}'
            $resp = Invoke-WebRequest -UseBasicParsing -Method PATCH `
                -Uri "http://127.0.0.1:$port/api/scope-board" `
                -ContentType 'application/json' `
                -Body $body -TimeoutSec 5
            Assert-Equal 200 $resp.StatusCode
            $j = $resp.Content | ConvertFrom-Json
            Assert-Equal 'Now building W' $j.raw
            Assert-Equal 'Now building W' $j.html
            # File should now carry the new value.
            $disk = Get-Content -Path $scopeMd -Raw -Encoding UTF8
            Assert-Match '\| \*\*Bob\*\* \| Now building W \| _TBD_ \|' $disk
            # Alice's row must NOT have been touched.
            Assert-Match '\| \*\*Alice\*\* \| Building X \| \*\*Y next\*\* \|' $disk
        }

        It 'PATCH /api/scope-board rejects out-of-range table index with 400' {
            $threw = $false
            try {
                Invoke-WebRequest -UseBasicParsing -Method PATCH `
                    -Uri "http://127.0.0.1:$port/api/scope-board" `
                    -ContentType 'application/json' `
                    -Body '{"table":99,"row":0,"col":0,"value":"oops"}' -TimeoutSec 3 | Out-Null
            } catch {
                $threw = $true
                Assert-Match '400' $_.Exception.Message
            }
            Assert-True $threw
        }

        It 'PATCH /api/scope-board rejects non-string value with 400' {
            $threw = $false
            try {
                Invoke-WebRequest -UseBasicParsing -Method PATCH `
                    -Uri "http://127.0.0.1:$port/api/scope-board" `
                    -ContentType 'application/json' `
                    -Body '{"table":0,"row":0,"col":0,"value":42}' -TimeoutSec 3 | Out-Null
            } catch {
                $threw = $true
                Assert-Match '400' $_.Exception.Message
            }
            Assert-True $threw
        }
    } finally {
        if ($proc -and -not $proc.HasExited) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Remove-Item -Recurse -Force -Path $tmpRoot -ErrorAction SilentlyContinue
    }
}

Describe 'Board static carries scope-board editor' {
    $indexText = Get-Content -Path $indexHtml -Raw -Encoding UTF8
    $appJsText = Get-Content -Path $appJs    -Raw -Encoding UTF8
    $styleText = Get-Content -Path $styleCss -Raw -Encoding UTF8

    It 'index.html declares a Scope board nav item with a counter' {
        Assert-Match 'data-tab="scope-board"' $indexText
        Assert-Match 'id="count-scope-board"' $indexText
    }
    It 'app.js renders scope-board tab via renderScopeBoard + wireScopeBoardEditors' {
        Assert-Match 'STATE\.tab === "scope-board"' $appJsText
        Assert-Match 'function renderScopeBoard' $appJsText
        Assert-Match 'function wireScopeBoardEditors' $appJsText
        Assert-Match 'function openSbEditor' $appJsText
    }
    It 'app.js PATCHes /api/scope-board on save and handles Ctrl+Enter / Esc' {
        Assert-Match '/api/scope-board' $appJsText
        Assert-Match 'method:\s*"PATCH"' $appJsText
        Assert-Match 'e\.ctrlKey \|\| e\.metaKey' $appJsText
        Assert-Match 'e\.key === "Escape"' $appJsText
    }
    It 'app.js hides the + Add button on the scope-board tab' {
        Assert-Match 'tab === "scope-board"' $appJsText
        Assert-Match 'addBtn\.style\.display' $appJsText
    }
    It 'style.css carries the scope-board CSS hooks' {
        Assert-Match '\.sb-table' $styleText
        Assert-Match '\.sb-cell' $styleText
        Assert-Match '\.sb-edit-btn' $styleText
        Assert-Match '\.sb-editor' $styleText
    }
}

Describe 'Explorer template no longer carries scope-board editor' {
    $templateText = Get-Content -Path $templateHtml -Raw -Encoding UTF8

    It 'still has a renderScopeBoard but renders read-only' {
        Assert-Match 'function renderScopeBoard' $templateText
        Assert-Match 'Edit in Nirvana Board' $templateText
    }
    It 'no longer defines wireScopeBoardEditors or openSbEditor in the Explorer' {
        Assert-NotMatch 'function wireScopeBoardEditors' $templateText
        Assert-NotMatch 'function openSbEditor' $templateText
    }
    It 'no longer renders editable <td class="sb-cell"> tables in the Explorer' {
        Assert-NotMatch 'data-editable=' $templateText
        Assert-NotMatch 'class="sb-edit-btn"' $templateText
    }
    It 'does not PATCH /api/scope-board from the Explorer' {
        Assert-NotMatch '/api/scope-board' $templateText
    }
}

Describe 'markdown_io.py personal-notes section round-trip' {
    $pyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nv-board-pn-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $pyDir -Force | Out-Null
    $tmpFile = Join-Path $pyDir 'maya-Teammate4.md'
    $fixture = @"
# 1:1 with Teammate4

---

## Open

## Closed

"@
    [System.IO.File]::WriteAllText($tmpFile, $fixture, [System.Text.UTF8Encoding]::new($false))

    $pyHelper = @"
import sys
sys.path.insert(0, r'$($boardDir -replace '\\','\\')')
import markdown_io as mio
path = r'$($tmpFile -replace '\\','\\')'
text = open(path, encoding='utf-8').read()
print('NOTES1=' + repr(mio.parse_personal_notes(text)))
new_text = mio.set_personal_notes(text, 'Burned out from EG. Wants new folks.')
open(path, 'w', encoding='utf-8').write(new_text)
text = open(path, encoding='utf-8').read()
print('NOTES2=' + repr(mio.parse_personal_notes(text)))
print('HEADING=' + ('## Personal notes' in text and 'Y' or 'N'))
new_text = mio.set_personal_notes(text, '')
open(path, 'w', encoding='utf-8').write(new_text)
text = open(path, encoding='utf-8').read()
print('NOTES3=' + repr(mio.parse_personal_notes(text)))
"@
    $helperPath = Join-Path $pyDir 'check.py'
    $pyHelper | Set-Content -LiteralPath $helperPath -Encoding UTF8

    $out = (& python $helperPath 2>&1) -join "`n"

    It 'parse_personal_notes returns empty string when no section exists' {
        Assert-Match "NOTES1='?'" $out
    }
    It 'set_personal_notes inserts the section + body between # title and ---' {
        Assert-Match "NOTES2='Burned out from EG\. Wants new folks\.'" $out
    }
    It 'after set_personal_notes the markdown carries a "## Personal notes" heading' {
        Assert-Match 'HEADING=Y' $out
    }
    It 'set_personal_notes with empty string clears the body but keeps round-trip safe' {
        Assert-Match "NOTES3=''" $out
    }
    Remove-Item -LiteralPath $pyDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Board static carries 1:1 personal notes / milestones / summary cards (v0.8.0)' {
    $appJsText = Get-Content $appJs -Raw -Encoding UTF8
    $cssText   = Get-Content $styleCss -Raw -Encoding UTF8

    It 'app.js declares renderPersonalNotesCard / renderMilestonesCard / renderSummaryCard' {
        Assert-Match 'function renderPersonalNotesCard\(' $appJsText
        Assert-Match 'function renderMilestonesCard\(' $appJsText
        Assert-Match 'function renderSummaryCard\(' $appJsText
    }
    It 'app.js wires renderDirectContextCards to include the new cards' {
        Assert-Match 'renderPersonalNotesCard\(partner' $appJsText
        Assert-Match 'renderMilestonesCard\(partner' $appJsText
        Assert-Match 'renderSummaryCard\(partner' $appJsText
    }
    It 'app.js PATCHes /api/one-on-ones/<slug>/personal-notes on Save' {
        Assert-Match '/personal-notes' $appJsText
        Assert-Match 'savePersonalNotes' $appJsText
        Assert-Match 'method:\s*"PATCH"' $appJsText
    }
    It 'app.js POSTs /api/one-on-ones/<slug>/summary on Send' {
        Assert-Match '/summary' $appJsText
        Assert-Match 'sendOneOnOneSummary' $appJsText
        Assert-Match 'dry_run' $appJsText
    }
    It 'style.css carries the notes / milestones / summary card hooks' {
        Assert-Match '\.notes-card' $cssText
        Assert-Match '\.milestones-card' $cssText
        Assert-Match '\.summary-card' $cssText
        Assert-Match '\.pn-text' $cssText
        Assert-Match '\.sum-text' $cssText
    }
    It 'app.js + style.css no longer carry the "Wins since last 1:1" card (removed per Nir 2026-06-06)' {
        Assert-NotMatch 'renderWinsCard' $appJsText
        Assert-NotMatch 'Wins since last 1:1' $appJsText
        Assert-NotMatch '\.wins-card' $cssText
    }
}

Describe 'serve.py v0.8.0 wires personal-notes + summary endpoints' {
    $serveText = Get-Content $serveScript -Raw -Encoding UTF8
    It 'declares a VERSION at or beyond 0.8.0 (personal-notes/summary shipped in 0.8.0)' {
        Assert-Match 'VERSION\s*=\s*"\d+\.\d+\.\d+"' $serveText
        if ($serveText -match 'VERSION\s*=\s*"(\d+)\.(\d+)\.(\d+)"') {
            $v = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
            Assert-True ($v -ge [version]'0.8.0')
        } else {
            throw 'VERSION not found in serve.py'
        }
    }
    It 'declares mutate_personal_notes(paths, slug, payload)' {
        Assert-Match 'def mutate_personal_notes\(' $serveText
        Assert-Match 'mio\.set_personal_notes' $serveText
    }
    It 'declares send_one_on_one_summary(paths, slug, payload)' {
        Assert-Match 'def send_one_on_one_summary\(' $serveText
        Assert-Match 'subprocess\.Popen' $serveText
        Assert-Match '-SummaryMode' $serveText
    }
    It 'spawn uses CREATE_NO_WINDOW + CREATE_NEW_PROCESS_GROUP + CREATE_BREAKAWAY_FROM_JOB so the runner survives a board restart AND keeps a console (DETACHED_PROCESS would kill pwsh on startup)' {
        Assert-Match '"CREATE_NO_WINDOW"' $serveText
        Assert-Match '"CREATE_NEW_PROCESS_GROUP"' $serveText
        Assert-Match '"CREATE_BREAKAWAY_FROM_JOB"' $serveText
        # Regression guard: DETACHED_PROCESS gives the child no console, and
        # pwsh -File then dies before writing its log ("Dry run does nothing").
        if ($serveText -match '"DETACHED_PROCESS"') {
            throw "serve.py must NOT use DETACHED_PROCESS for the runner spawn (it kills pwsh before it can log)."
        }
    }
    It 'spawn logs request + child PID to server stderr for forensic traceability' {
        Assert-Match 'spawn one-on-one-prep summary slug=' $serveText
        Assert-Match 'spawned one-on-one-prep summary pid=' $serveText
    }
    It 'dry-run summary runs synchronously with -PreviewOut and returns preview_html' {
        # The "preview only" button must SHOW the rendered email, not bury it
        # in a log file. serve.py runs the runner synchronously on dry_run,
        # passing -PreviewOut, then returns the HTML to the browser.
        Assert-Match '-PreviewOut' $serveText
        Assert-Match 'subprocess\.run' $serveText
        Assert-Match '"preview_html"' $serveText
    }
    It 'routes PATCH /api/one-on-ones/<slug>/personal-notes' {
        Assert-Match "/personal-notes" $serveText
    }
    It 'routes POST /api/one-on-ones/<slug>/summary' {
        Assert-Match "/summary" $serveText
    }
    It 'board_snapshot decorates 1:1 records with recent_wins / personal_notes / upcoming_milestones' {
        Assert-Match '"recent_wins"' $serveText
        Assert-Match '"upcoming_milestones"' $serveText
        Assert-Match 'mio\.parse_personal_notes' $serveText
    }
}

Describe 'Board preserves in-flight textarea drafts across 30s auto-refresh (summary + personal notes)' {
    $appJsText = Get-Content $appJs -Raw -Encoding UTF8

    It 'STATE carries summaryDrafts + notesDrafts caches' {
        Assert-Match 'summaryDrafts:\s*\{\}' $appJsText
        Assert-Match 'notesDrafts:\s*\{\}' $appJsText
    }
    It 'renderSummaryCard bakes the cached draft back into the textarea' {
        Assert-Match 'STATE\.summaryDrafts\[partner\.slug\]' $appJsText
        # The textarea body must reference the draft, not stay empty.
        Assert-Match 'data-sum-input="1"[^>]*>\$\{escHtml\(draft\)\}<' $appJsText
    }
    It 'renderPersonalNotesCard prefers the in-flight draft over server-side notes' {
        Assert-Match 'STATE\.notesDrafts\[partner\.slug\]' $appJsText
    }
    It 'declares onCardsInput and wires it as an input delegation on #cards-host' {
        Assert-Match 'function onCardsInput\(' $appJsText
        Assert-Match 'cards-host"\)\.addEventListener\("input",\s*onCardsInput\)' $appJsText
    }
    It 'onCardsInput mirrors keystrokes into STATE.summaryDrafts and STATE.notesDrafts' {
        Assert-Match 'STATE\.summaryDrafts\[root\.dataset\.sumSlug\]\s*=\s*t\.value' $appJsText
        Assert-Match 'STATE\.notesDrafts\[root\.dataset\.pnSlug\]\s*=\s*t\.value'  $appJsText
    }
    It 'sendOneOnOneSummary clears the summary draft only on a real (non-dry-run) send' {
        # Dry-run returns early (after rendering the preview) BEFORE the
        # unconditional draft-clear, so the draft survives a preview and is
        # only dropped on a real send.
        Assert-Match 'if\s*\(dryRun\)\s*\{[\s\S]*?return;[\s\S]*?\}[\s\S]*?delete\s+STATE\.summaryDrafts\[slug\]' $appJsText
    }
    It 'savePersonalNotes clears the notes draft on success' {
        Assert-Match 'delete\s+STATE\.notesDrafts\[slug\]' $appJsText
    }
    It 'dry-run summary renders the returned preview_html in an iframe overlay' {
        Assert-Match 'function showSummaryPreview' $appJsText
        Assert-Match 'res\.preview_html' $appJsText
        Assert-Match 'srcdoc' $appJsText
    }
    It '30s auto-refresh skips ticks while a .sum-text or .pn-text is focused' {
        # Setinterval body must check activeElement against the two draft classes.
        Assert-Match 'setInterval\(\(\)\s*=>\s*\{[\s\S]*?activeElement[\s\S]*?\.sum-text[\s\S]*?\.pn-text[\s\S]*?\},\s*30000\)' $appJsText
    }
}

Describe 'sdk-rotation parser + reorder' {
    $sdkRotIo = Join-Path $boardDir 'sdk_rotation_io.py'

    It 'sdk_rotation_io.py exists' { Assert-True (Test-Path $sdkRotIo) }

    It 'sdk_rotation_io.py parses to valid Python' {
        $r = & python -c "import ast; ast.parse(open(r'$sdkRotIo', encoding='utf-8').read()); print('ok')"
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal 'ok' ($r.Trim())
    }

    It 'parse_sdk_rotation finds the Current order table by heading' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sdk-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import sdk_rotation_io as sdk

text = '''# SDK Task Rotation

## Rules

- Excluded: alice
- First: bob

## Current order

| # | Name | Alias | Status |
|---|------|-------|--------|
| 1 | Bob   | bob   | First |
| 2 | Carol | carol |       |
| 3 | Dave  | dave  | Last  |

## History

_(empty)_
'''
p = sdk.parse_sdk_rotation(text)
print('order_table_index', p['order_table_index'])
print('tables', len(p['tables']))
print('t0_heading', p['tables'][0]['heading'])
print('t0_rows', len(p['tables'][0]['rows']))
print('row0_name', p['tables'][0]['rows'][0]['cells'][1]['raw'])
print('row2_status', p['tables'][0]['rows'][2]['cells'][3]['raw'])
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'order_table_index 0' $out
            Assert-Match 'tables 1' $out
            Assert-Match 't0_heading Current order' $out
            Assert-Match 't0_rows 3' $out
            Assert-Match 'row0_name Bob' $out
            Assert-Match 'row2_status Last' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'parse_sdk_rotation returns order_table_index=None when there is no Current order table' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sdk-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import sdk_rotation_io as sdk

text = '''# Notes

## Misc

| A | B |
|---|---|
| 1 | 2 |
'''
p = sdk.parse_sdk_rotation(text)
print('idx', repr(p['order_table_index']))
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'idx None' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'reorder_sdk_rotation_rows permutes rows AND renumbers column 0' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sdk-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import sdk_rotation_io as sdk

text = '''# SDK Task Rotation

Some rules here.

## Current order

| # | Name | Alias | Status |
|---|------|-------|--------|
| 1 | Bob   | bob   | First |
| 2 | Carol | carol |       |
| 3 | Dave  | dave  | Last  |

## History

_(empty)_
'''
new = sdk.reorder_sdk_rotation_rows(text, [2, 0, 1])
p = sdk.parse_sdk_rotation(new)
for r in p['tables'][0]['rows']:
    print('row', [c['raw'] for c in r['cells']])
print('history_kept', '_(empty)_' in new)
print('rules_kept', 'Some rules here.' in new)
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            # Permuted: original index 2 -> position 1, 0 -> 2, 1 -> 3
            Assert-Match "row \['1', 'Dave', 'dave', 'Last'\]" $out
            Assert-Match "row \['2', 'Bob', 'bob', 'First'\]" $out
            Assert-Match "row \['3', 'Carol', 'carol', ''\]" $out
            Assert-Match 'history_kept True' $out
            Assert-Match 'rules_kept True' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'reorder_sdk_rotation_rows rejects a non-permutation' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sdk-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import sdk_rotation_io as sdk

text = '''## Current order

| # | Name |
|---|------|
| 1 | Bob |
| 2 | Carol |
'''
try:
    sdk.reorder_sdk_rotation_rows(text, [0, 0])
    print('no-throw')
except ValueError as ex:
    print('caught', str(ex))
try:
    sdk.reorder_sdk_rotation_rows(text, [0])
    print('no-throw-len')
except ValueError as ex:
    print('caught-len', str(ex))
try:
    sdk.reorder_sdk_rotation_rows(text, 'not-a-list')
    print('no-throw-type')
except ValueError as ex:
    print('caught-type', str(ex))
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'caught .*permutation' $out
            Assert-Match 'caught-len .*exactly' $out
            Assert-Match 'caught-type .*list' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }

    It 'reorder_sdk_rotation_rows raises when there is no Current order table' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-sdk-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        try {
            $py = @"
# -*- coding: utf-8 -*-
import sys
sys.path.insert(0, r'$boardDir')
import sdk_rotation_io as sdk

text = '''## Misc

| A | B |
|---|---|
| 1 | 2 |
'''
try:
    sdk.reorder_sdk_rotation_rows(text, [0])
    print('no-throw')
except ValueError as ex:
    print('caught', str(ex))
"@
            [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match "caught no 'Current order' table" $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'sdk-rotation API smoke (live server)' {
    $port = 5795
    $proc = $null
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-root-sdk-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $tmpScopeDir = Join-Path $tmpRoot 'reports\directs-scope'
    $tmpConfigDir = Join-Path $tmpRoot 'config'
    New-Item -ItemType Directory -Force -Path $tmpScopeDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tmpConfigDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'reports\personal-todos') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'reports\team-agenda') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'reports\one-on-ones') | Out-Null
    Set-Content -Path (Join-Path $tmpRoot 'reports\personal-todos\todos.md') -Value "# Todos`n`n## Open`n_(Empty)_`n`n## Done`n_(Empty)_`n" -Encoding utf8
    Set-Content -Path (Join-Path $tmpRoot 'reports\team-agenda\open-discussions.md') -Value "# Agenda`n`n## Open`n_(Empty)_`n`n## Closed`n_(Empty)_`n" -Encoding utf8
    Set-Content -Path (Join-Path $tmpScopeDir 'scope-board.md') -Value "# Scope`n`n## Open`n`n| Direct | Now |`n|---|---|`n| _(empty)_ |  |`n" -Encoding utf8

    $sdkMd = Join-Path $tmpConfigDir 'sdk-rotation.md'
    @"
# SDK Task Rotation

Rules.

## Current order

| # | Name  | Alias | Status |
|---|-------|-------|--------|
| 1 | Alice | alice | First  |
| 2 | Bob   | bob   |        |
| 3 | Carol | carol | Last   |

## History

_(empty)_
"@ | Out-File -FilePath $sdkMd -Encoding utf8

    try {
        $proc = Start-Process -FilePath 'python' `
            -ArgumentList @($serveScript, '--port', "$port", '--repo-root', $tmpRoot) `
            -WorkingDirectory $repoRoot `
            -WindowStyle Hidden `
            -PassThru
        $ok = $false
        for ($i=0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 200
            if ($proc.HasExited) { break }
            try {
                $h = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 1
                if ($h.StatusCode -eq 200) { $ok = $true; break }
            } catch { }
        }
        It 'server starts against temp repo-root' { Assert-True $ok }

        It 'GET /api/sdk-rotation returns the parsed table + order_table_index' {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/sdk-rotation" -TimeoutSec 5
            Assert-Equal 200 $resp.StatusCode
            $j = $resp.Content | ConvertFrom-Json
            Assert-True $j.exists
            Assert-Equal 0 $j.order_table_index
            Assert-Equal 'Current order' $j.tables[0].heading
            Assert-Equal 3 $j.tables[0].rows.Count
            Assert-Equal 'Alice' $j.tables[0].rows[0].cells[1].raw
        }

        It '/api/board embeds sdk_rotation + counts.sdk_rotation_rows' {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/api/board" -TimeoutSec 5
            Assert-Equal 200 $resp.StatusCode
            $j = $resp.Content | ConvertFrom-Json
            Assert-True ($null -ne $j.sdk_rotation)
            Assert-Equal 0 $j.sdk_rotation.order_table_index
            Assert-Equal 3 $j.counts.sdk_rotation_rows
        }

        It 'PATCH /api/sdk-rotation updates one cell and persists' {
            $body = '{"table":0,"row":1,"col":3,"value":"Now reviewing"}'
            $resp = Invoke-WebRequest -UseBasicParsing -Method PATCH `
                -Uri "http://127.0.0.1:$port/api/sdk-rotation" `
                -ContentType 'application/json' `
                -Body $body -TimeoutSec 5
            Assert-Equal 200 $resp.StatusCode
            $disk = Get-Content -Path $sdkMd -Raw -Encoding UTF8
            Assert-Match '\| 2 \| Bob \| bob \| Now reviewing \|' $disk
            # Alice + Carol rows untouched.
            Assert-Match '\| 1 \| Alice \| alice \| First  \|' $disk
            Assert-Match '\| 3 \| Carol \| carol \| Last   \|' $disk
        }

        It 'PATCH /api/sdk-rotation/order reorders rows AND renumbers column 0' {
            $body = '{"order":[2,0,1]}'
            $resp = Invoke-WebRequest -UseBasicParsing -Method PATCH `
                -Uri "http://127.0.0.1:$port/api/sdk-rotation/order" `
                -ContentType 'application/json' `
                -Body $body -TimeoutSec 5
            Assert-Equal 200 $resp.StatusCode
            $j = $resp.Content | ConvertFrom-Json
            # Snapshot reflects new order, with column 0 renumbered 1..3.
            Assert-Equal '1' $j.snapshot.tables[0].rows[0].cells[0].raw
            Assert-Equal 'Carol' $j.snapshot.tables[0].rows[0].cells[1].raw
            Assert-Equal '2' $j.snapshot.tables[0].rows[1].cells[0].raw
            Assert-Equal 'Alice' $j.snapshot.tables[0].rows[1].cells[1].raw
            Assert-Equal '3' $j.snapshot.tables[0].rows[2].cells[0].raw
            Assert-Equal 'Bob' $j.snapshot.tables[0].rows[2].cells[1].raw
            # Disk carries the new order too.
            $disk = Get-Content -Path $sdkMd -Raw -Encoding UTF8
            $idxAlice = $disk.IndexOf('| Alice |')
            $idxCarol = $disk.IndexOf('| Carol |')
            $idxBob   = $disk.IndexOf('| Bob |')
            Assert-True ($idxCarol -lt $idxAlice -and $idxAlice -lt $idxBob)
        }

        It 'PATCH /api/sdk-rotation/order rejects a non-permutation with 400' {
            $threw = $false
            try {
                Invoke-WebRequest -UseBasicParsing -Method PATCH `
                    -Uri "http://127.0.0.1:$port/api/sdk-rotation/order" `
                    -ContentType 'application/json' `
                    -Body '{"order":[0,0,1]}' -TimeoutSec 3 | Out-Null
            } catch {
                $threw = $true
                Assert-Match '400' $_.Exception.Message
            }
            Assert-True $threw
        }
    } finally {
        if ($proc -and -not $proc.HasExited) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Remove-Item -Recurse -Force -Path $tmpRoot -ErrorAction SilentlyContinue
    }
}

Describe 'Board static carries sdk-rotation editor + DnD' {
    $indexText = Get-Content -Path $indexHtml -Raw -Encoding UTF8
    $appJsText = Get-Content -Path $appJs    -Raw -Encoding UTF8
    $styleText = Get-Content -Path $styleCss -Raw -Encoding UTF8

    It 'index.html declares a SDK rotation nav item with a counter' {
        Assert-Match 'data-tab="sdk-rotation"' $indexText
        Assert-Match 'id="count-sdk-rotation"' $indexText
    }
    It 'app.js renders sdk-rotation tab via renderSdkRotation + wireSdkRotationEditors' {
        Assert-Match 'STATE\.tab === "sdk-rotation"' $appJsText
        Assert-Match 'function renderSdkRotation' $appJsText
        Assert-Match 'function wireSdkRotationEditors' $appJsText
        Assert-Match 'function openSdkCellEditor' $appJsText
        Assert-Match 'function wireSdkRowDnD' $appJsText
        Assert-Match 'function commitSdkOrder' $appJsText
    }
    It 'app.js PATCHes /api/sdk-rotation on cell save' {
        Assert-Match '/api/sdk-rotation"' $appJsText
        Assert-Match '/api/sdk-rotation/order' $appJsText
    }
    It 'app.js hides the + Add button on the sdk-rotation tab' {
        Assert-Match 'tab === "sdk-rotation"' $appJsText
        Assert-Match 'addBtn\.style\.display' $appJsText
    }
    It 'app.js wires native HTML5 drag-and-drop on order-table rows' {
        Assert-Match 'addEventListener\("dragstart"' $appJsText
        Assert-Match 'addEventListener\("dragover"' $appJsText
        Assert-Match 'addEventListener\("drop"' $appJsText
        Assert-Match 'draggable="true"' $appJsText
    }
    It 'style.css carries the sdk-rotation drag-handle CSS hooks' {
        Assert-Match '\.sdk-drag-handle' $styleText
        Assert-Match '\.sdk-row\.dragging' $styleText
        Assert-Match '\.sdk-row\.drop-before' $styleText
        Assert-Match '\.sdk-row\.drop-after' $styleText
    }
}

Describe 'Board static carries Scheduled tasks tab' {
    $indexText = Get-Content -Path $indexHtml   -Raw -Encoding UTF8
    $appJsText = Get-Content -Path $appJs       -Raw -Encoding UTF8
    $serveText = Get-Content -Path $serveScript -Raw -Encoding UTF8
    $skillText = Get-Content -Path $skillDoc    -Raw -Encoding UTF8

    It 'index.html declares a Scheduled tasks nav item with a counter' {
        Assert-Match 'data-tab="scheduled-tasks"' $indexText
        Assert-Match 'id="count-scheduled-tasks"' $indexText
    }
    It 'app.js renders + lazy-loads the scheduled-tasks tab' {
        Assert-Match 'STATE\.tab === "scheduled-tasks"' $appJsText
        Assert-Match 'function renderScheduledTasks' $appJsText
        Assert-Match 'function loadScheduledTasks' $appJsText
        Assert-Match '/api/scheduled-tasks' $appJsText
    }
    It 'app.js renders the "What it does" explanation column' {
        Assert-Match 'What it does' $appJsText
        Assert-Match 't\.explanation' $appJsText
    }
    It 'serve.py joins schedules.json + skills.json for the explanation' {
        Assert-Match 'def _scheduled_task_meta' $serveText
        Assert-Match 'def _explain_task' $serveText
        Assert-Match 'schedules\.json' $serveText
    }
    It 'app.js hides the + Add button on the scheduled-tasks tab' {
        Assert-Match 'tab === "scheduled-tasks"' $appJsText
        Assert-Match 'addBtn\.style\.display' $appJsText
    }
    It 'serve.py routes GET /api/scheduled-tasks via a cached snapshot' {
        Assert-Match '/api/scheduled-tasks' $serveText
        Assert-Match 'def scheduled_tasks_snapshot' $serveText
        Assert-Match "Get-ScheduledTask -TaskName 'DM-\*'" $serveText
    }
    It 'SKILL.md documents the scheduled-tasks endpoint' {
        Assert-Match '/api/scheduled-tasks' $skillText
    }
    It 'serve.py VERSION is bumped to at least 0.9.0 for the scheduled-tasks tab' {
        if ($serveText -match 'VERSION\s*=\s*"(\d+)\.(\d+)\.(\d+)"') {
            $v = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
            Assert-True ($v -ge [version]'0.9.0')
        } else {
            throw 'VERSION not found in serve.py'
        }
    }
}

Describe 'Board static app.js parses as valid JavaScript' {
    $appJsText = Get-Content -Path $appJs -Raw -Encoding UTF8
    # Regression: on 2026-05-28 a SKILL edit clobbered "function render() {"
    # leaving renderCounts()/renderCards() at top-level with a dangling `}`.
    # The page silently stayed "stuck on loading" because the SyntaxError
    # killed loadBoard() before the first fetch. Catch it at test time.
    It 'has a non-orphaned function render() definition' {
        Assert-Match 'function render\(\)' $appJsText
        Assert-Match '(?s)function render\(\) \{[^}]*renderCounts\(\)[^}]*renderCards\(\)[^}]*\}' $appJsText
    }
    It 'parses cleanly with node --check' {
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) {
            Write-Host '[SKIP] node not on PATH'
            return
        }
        $tmp = [System.IO.Path]::GetTempFileName()
        $tmpJs = $tmp + '.js'
        Move-Item -Path $tmp -Destination $tmpJs -Force
        try {
            [System.IO.File]::WriteAllText($tmpJs, $appJsText, [System.Text.UTF8Encoding]::new($false))
            $out = & node --check $tmpJs 2>&1
            $exit = $LASTEXITCODE
            Assert-Equal 0 $exit ("node --check failed: " + ($out -join "`n"))
        } finally {
            if (Test-Path $tmpJs) { Remove-Item -Path $tmpJs -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'My Day tab (landing view)' {
    $serveText = Get-Content -Path $serveScript -Raw -Encoding UTF8
    $appJsText = Get-Content -Path $appJs -Raw -Encoding UTF8
    $indexText = Get-Content -Path $indexHtml -Raw -Encoding UTF8
    $styleText = Get-Content -Path $styleCss -Raw -Encoding UTF8

    It 'serve.py defines compute_my_day + my_day_snapshot and routes /api/my-day' {
        Assert-Match 'def compute_my_day' $serveText
        Assert-Match 'def my_day_snapshot' $serveText
        Assert-Match '/api/my-day' $serveText
        Assert-Match '_CALENDAR_PS' $serveText
    }
    It 'index.html carries a My Day nav item (and it is the default active tab)' {
        Assert-Match 'data-tab="my-day"' $indexText
        Assert-Match 'nav-item active" data-tab="my-day"' $indexText
    }
    It 'app.js defines renderMyDay + loadMyDay and fetches /api/my-day' {
        Assert-Match 'function renderMyDay' $appJsText
        Assert-Match 'function loadMyDay' $appJsText
        Assert-Match '/api/my-day' $appJsText
    }
    It 'style.css carries the .myday-grid layout' {
        Assert-Match '\.myday-grid' $styleText
    }

    It 'compute_my_day ranks overdue/due-today/1:1-prep/ADO/reminder correctly and drops declined meetings' {
        $pyPath = Join-Path ([IO.Path]::GetTempPath()) ("nirvana-board-myday-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
        $py = @"
import sys, datetime
sys.path.insert(0, r'$boardDir')
import serve as srv

today = datetime.date(2026, 7, 1)
board = {
  'todos': [
    {'id':'PT-001','title':'Overdue','status':'open','priority':'M','due':'2026-06-28','snoozed_until':'-'},
    {'id':'PT-002','title':'DueToday','status':'open','priority':'H','due':'2026-07-01','snoozed_until':'-'},
    {'id':'PT-003','title':'HighPri','status':'open','priority':'H','due':'-','snoozed_until':'-'},
    {'id':'PT-004','title':'SnzPast','status':'snoozed','priority':'M','due':'-','snoozed_until':'2026-06-30'},
    {'id':'PT-005','title':'Done','status':'done','priority':'H','due':'2026-06-01','snoozed_until':'-'},
  ],
  'one_on_ones': [{'slug':'Your Manager-rothschild','label':'Your Manager Rothschild','open_count':3}],
  'ado_tracker': {'items':[{'id':999,'title':'Fix ingestion','state':'Active','changed_date':'2026-06-30'}]},
}
meetings = [
  {'subject':'Your Manager - 1x1','start':'2026-07-01T11:00:00','end':'2026-07-01T11:30:00','allDay':False,'response':1,'busy':2},
  {'subject':'Declined mtg','start':'2026-07-01T09:00:00','end':'2026-07-01T09:30:00','allDay':False,'response':4,'busy':2},
]
reminders = [{'id':'RM-001','title':'ping','when':'today','kind':'absolute'}]
r = srv.compute_my_day(board, meetings, reminders, today)
print('MEETINGS', r['stats']['meetings'])
print('ONEONONE', sum(1 for m in r['meetings'] if m.get('is_one_on_one')))
print('NEEDS0', r['needs_attention'][0]['tag'])
print('HASPREP', any(n['tag']=='1:1 prep' for n in r['needs_attention']))
print('HASADO', any(n['tag']=='ADO' for n in r['needs_attention']))
print('HASREM', any(n['tag']=='Reminder' for n in r['needs_attention']))
print('FOCUS0', r['focus'][0]['ref'])
print('FOCUS1', r['focus'][1]['ref'])
print('OVERDUE', r['stats']['overdue'])
print('DUETODAY', r['stats']['due_today'])
print('SNZ', r['stats']['snoozed_past'])
"@
        [System.IO.File]::WriteAllText($pyPath, $py, [System.Text.UTF8Encoding]::new($false))
        try {
            $out = & python $pyPath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE $out
            Assert-Match 'MEETINGS 1' $out       # declined meeting dropped
            Assert-Match 'ONEONONE 1' $out       # Your Manager 1x1 detected
            Assert-Match 'NEEDS0 Overdue' $out   # overdue ranked first
            Assert-Match 'HASPREP True' $out
            Assert-Match 'HASADO True' $out
            Assert-Match 'HASREM True' $out
            Assert-Match 'FOCUS0 PT-001' $out    # overdue focus first
            Assert-Match 'FOCUS1 PT-002' $out    # due-today focus second
            Assert-Match 'OVERDUE 1' $out
            Assert-Match 'DUETODAY 1' $out
            Assert-Match 'SNZ 1' $out
        } finally {
            Remove-Item -Path $pyPath -ErrorAction SilentlyContinue
        }
    }
}

Exit-WithTestResults


