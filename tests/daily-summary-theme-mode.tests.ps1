# Tests for the theme-mode helpers added to run-daily-summary-import.ps1
# (covers the 2026-05-06 incident where Cowork output drifted to a theme/metric
# layout with no '## By Person' section, plus the looser '## Activity by Person'
# variant the same drift produced).
#
# The runner is dot-sourced with $env:NIRVANA_TEST_DOTSOURCE='1' which short-
# circuits Main and exposes the helpers (ConvertFrom-Alias,
# Get-DisplayNamesFromPersonaFile, Get-PersonNameIndex, Get-NameMentions,
# ConvertFrom-ThemeMarkdown, Get-FileContentHash, plus the legacy
# Get-ByPersonBlock / Split-PersonEntries pair we widened).

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$runnerPath = Join-Path $PSScriptRoot '..\.copilot\skills\run-daily-summary-import.ps1'

$env:NIRVANA_TEST_DOTSOURCE = '1'
try {
    . $runnerPath
}
finally {
    $env:NIRVANA_TEST_DOTSOURCE = $null
}

# Build a small persona fixture that exercises every heading variant the real
# people/ + contacts/ trees throw at us today, including the cp1252-mojibake
# em-dash sequence "â€"".
$fixtureRoot = Join-Path $env:TEMP ("nirvana-tm-fixture-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$peopleDir   = Join-Path $fixtureRoot 'people'
$contactsDir = Join-Path $fixtureRoot 'contacts'
$null = New-Item -ItemType Directory -Path $peopleDir   -Force
$null = New-Item -ItemType Directory -Path $contactsDir -Force

# Variant 1: 'Working-Style Persona: <Name>' prefix form.
Set-Content -Path (Join-Path $peopleDir 'Teammate1-Teammate1.md') -Encoding UTF8 -Value @'
# Working-Style Persona: Teammate1

**Subject:** Teammate1 (someone@example.com), Senior Software Engineer
'@

# Variant 2: '<Name> â€" Working-Style Persona' (mojibake em-dash).
Set-Content -Path (Join-Path $peopleDir 'maya-Teammate4.md') -Encoding UTF8 -Value @'
# Teammate4 â€" Working-Style Persona

**Subject:** Teammate4 (someone@example.com), Software Engineer
'@

# Variant 3: '<Name> â€" Persona' (mojibake em-dash, short form).
Set-Content -Path (Join-Path $peopleDir 'lea-Teammate2.md') -Encoding UTF8 -Value @'
# Teammate2 â€" Persona
'@

# Variant 4: '<Name> â€" Working Persona' (mojibake em-dash, no hyphen).
Set-Content -Path (Join-Path $peopleDir 'roni-Teammate11.md') -Encoding UTF8 -Value @'
# Teammate11 â€" Working Persona
'@

# Variant 5: hyphenated alias title-cased baseline (no body, just heading).
Set-Content -Path (Join-Path $contactsDir 'your-vp.md') -Encoding UTF8 -Value @'
# Your VP (your-vp)
'@

# Variant 6: contact with bare '# <Name> (<alias>)' form.
Set-Content -Path (Join-Path $contactsDir 'arnaud-flutre.md') -Encoding UTF8 -Value @'
# Teammate23 (arnaud-flutre)
'@

Describe 'ConvertFrom-Alias - title-case alias splitter' {
    It 'splits hyphenated aliases' {
        Assert-Equal 'Teammate1' (ConvertFrom-Alias 'Teammate1-Teammate1')
    }
    It 'handles 3-token aliases' {
        Assert-Equal 'Your VP' (ConvertFrom-Alias 'your-vp')
    }
    It 'returns falsy for empty input' {
        $result = ConvertFrom-Alias ''
        Assert-True ([string]::IsNullOrEmpty($result)) ("expected null/empty, got: '$result'")
    }
}

Describe 'Get-DisplayNamesFromPersonaFile - heading variants' {
    It 'parses Working-Style Persona: <Name> form' {
        $names = Get-DisplayNamesFromPersonaFile -Alias 'Teammate1-Teammate1' -FilePath (Join-Path $peopleDir 'Teammate1-Teammate1.md')
        Assert-Contains 'Teammate1' $names
    }

    It 'parses <Name> mojibake-em-dash Working-Style Persona form' {
        $names = Get-DisplayNamesFromPersonaFile -Alias 'maya-Teammate4' -FilePath (Join-Path $peopleDir 'maya-Teammate4.md')
        Assert-Contains 'Teammate4' $names
        Assert-NotMatch 'Working-Style' ($names -join '|')
        Assert-NotMatch 'â' ($names -join '|')
    }

    It 'parses <Name> mojibake-em-dash Persona short form' {
        $names = Get-DisplayNamesFromPersonaFile -Alias 'lea-Teammate2' -FilePath (Join-Path $peopleDir 'lea-Teammate2.md')
        Assert-Contains 'Teammate2' $names
    }

    It 'parses <Name> mojibake-em-dash Working Persona form' {
        $names = Get-DisplayNamesFromPersonaFile -Alias 'roni-Teammate11' -FilePath (Join-Path $peopleDir 'roni-Teammate11.md')
        Assert-Contains 'Teammate11' $names
    }

    It 'parses contact <Name> (<alias>) form and strips the parenthetical' {
        $names = Get-DisplayNamesFromPersonaFile -Alias 'arnaud-flutre' -FilePath (Join-Path $contactsDir 'arnaud-flutre.md')
        Assert-Contains 'Teammate23' $names
        Assert-NotMatch '\(' ($names -join '|')
    }
}

Describe 'Get-PersonNameIndex - composite name -> alias map' {
    $idx = Get-PersonNameIndex -PeopleDir $peopleDir -ContactsDir $contactsDir

    It 'covers all fixture directs' {
        Assert-True $idx.ContainsKey('Teammate1') 'Teammate1 missing'
        Assert-True $idx.ContainsKey('Teammate4')  'Teammate4 missing'
        Assert-True $idx.ContainsKey('Teammate2')  'Teammate2 missing'
        Assert-True $idx.ContainsKey('Teammate11') 'Teammate11 missing'
    }

    It 'covers fixture contacts' {
        Assert-True $idx.ContainsKey('Teammate23')           'Teammate23 missing'
        Assert-True $idx.ContainsKey('Your VP') 'Your VP missing'
    }

    It 'directs win the IsDirect flag' {
        $entry = $idx['Teammate1']
        Assert-True $entry.IsDirect 'Teammate1 should be flagged as direct'
    }

    It 'contacts get IsDirect=false' {
        $entry = $idx['Teammate23']
        Assert-False $entry.IsDirect 'Teammate23 should not be flagged as direct'
    }

    It 'contains no mojibake-laden keys' {
        $bad = @($idx.Keys | Where-Object { $_ -match 'â' -or $_ -match 'Persona' -or $_ -match 'Working' })
        Assert-Equal 0 $bad.Count ("expected no junk keys, got: " + ($bad -join ', '))
    }
}

Describe 'Get-NameMentions - locate per-person snippets in theme text' {
    $idx = Get-PersonNameIndex -PeopleDir $peopleDir -ContactsDir $contactsDir

    It 'finds a direct in a theme bullet' {
        $md = "## Top Themes`n- **Bug:** Teammate1 identified two long-standing bugs in the DM service.`n"
        $hits = Get-NameMentions -Markdown $md -NameIndex $idx
        Assert-True $hits.ContainsKey('Teammate1-Teammate1') ("expected an Teammate1 hit, keys: " + ($hits.Keys -join ','))
        $entry = $hits['Teammate1-Teammate1']
        Assert-Equal 'Teammate1-Teammate1'   $entry.Alias
        Assert-Equal 'Teammate1'   $entry.DisplayName
        Assert-True ($entry.Snippets.Count -ge 1) "expected >= 1 snippet"
        Assert-Match 'Teammate1' ($entry.Snippets -join '|')
    }

    It 'does not match a name absent from the index' {
        $md = "- Some random Joe Schmo did a thing.`n"
        $hits = Get-NameMentions -Markdown $md -NameIndex $idx
        Assert-Equal 0 $hits.Count "expected no mentions for unknown name"
    }

    It 'matches across multiple paragraphs' {
        $md = @"
- **Theme A:** Teammate1 did X.
- **Theme B:** Teammate4 led Y.
"@
        $hits = Get-NameMentions -Markdown $md -NameIndex $idx
        Assert-True $hits.ContainsKey('Teammate1-Teammate1') 'expected Teammate1-Teammate1 key'
        Assert-True $hits.ContainsKey('maya-Teammate4')  'expected maya-Teammate4 key'
    }

    It 'respects unicode word boundaries (no false-positive on substring)' {
        # 'Asafetida' contains 'Teammate1' but should not match 'Teammate1'.
        $md = "- Asafetida is a spice. Plain text mention of Teammate1 (no space) should also miss.`n"
        $hits = Get-NameMentions -Markdown $md -NameIndex $idx
        Assert-False $hits.ContainsKey('Teammate1-Teammate1') 'word-boundary should reject Asafetida and Teammate1'
    }
}

Describe 'ConvertFrom-ThemeMarkdown - synthesizes per-person entries' {
    $idx = Get-PersonNameIndex -PeopleDir $peopleDir -ContactsDir $contactsDir

    It 'returns one entry per matched person with Alias filled in' {
        $md = @"
## Top Themes
- **DM Bugs:** Teammate1 shipped two fixes today.
- **Aria streaming:** Teammate4 completed migration validation.
"@
        $entries = @(ConvertFrom-ThemeMarkdown -Markdown $md -NameIndex $idx)
        $aliases = @($entries | ForEach-Object { $_.Alias } | Sort-Object -Unique)
        Assert-Contains 'Teammate1-Teammate1' $aliases
        Assert-Contains 'maya-Teammate4'  $aliases
    }
}

Describe 'Get-FileContentHash - stable + content-sensitive' {
    $tmp1 = Join-Path $fixtureRoot 'h1.md'
    $tmp2 = Join-Path $fixtureRoot 'h2.md'
    Set-Content -Path $tmp1 -Encoding UTF8 -Value 'hello world'
    Set-Content -Path $tmp2 -Encoding UTF8 -Value 'hello world'

    It 'returns the same hash for identical content' {
        $h1 = Get-FileContentHash -Path $tmp1
        $h2 = Get-FileContentHash -Path $tmp2
        Assert-Equal $h1 $h2
    }

    It 'returns a different hash when content changes' {
        $before = Get-FileContentHash -Path $tmp1
        Set-Content -Path $tmp1 -Encoding UTF8 -Value 'hello world!!'
        $after = Get-FileContentHash -Path $tmp1
        Assert-NotMatch ([regex]::Escape($before)) $after
    }
}

Describe 'Get-ByPersonBlock - heading variant tolerance' {
    It 'matches the legacy "## By Person" heading' {
        $md = "## Top`nfoo`n## By Person`n### Alice`n- did stuff`n## Tail`nbar"
        $block = Get-ByPersonBlock -Markdown $md
        Assert-Match 'Alice' $block
    }

    It 'matches the newer "## Activity by Person" heading' {
        $md = "## Top`nfoo`n## Activity by Person`n### Bob`n- did stuff`n## Tail`nbar"
        $block = Get-ByPersonBlock -Markdown $md
        Assert-Match 'Bob' $block
    }

    It 'returns null when neither variant is present' {
        $md = "## Top`nfoo`n## Themes`n- bullet`n"
        $block = Get-ByPersonBlock -Markdown $md
        Assert-True ($null -eq $block -or $block -eq '') 'expected null for missing By-Person section'
    }
}

Describe 'Build-DailyObservation - layout tolerance' {
    It 'still prefers "Discussion topic:" line' {
        $body = @(
            'Discussion topic: shipped the gRPC retry fix',
            '- bullet 1',
            '- bullet 2'
        )
        $obs = Build-DailyObservation -BodyLines $body -Role 'direct'
        Assert-Match 'Discussion topic\? *|^shipped the gRPC retry fix$' $obs
        Assert-Match 'gRPC retry fix' $obs
    }

    It 'extracts informative bold-key bullet from new layout' {
        $body = @(
            '**Role:** Senior Software Engineer (direct report to Your Name)',
            '',
            '**PRs completed today:** PR 15637723 (fix DM Aria data loss), PR 15637827 (SRE-DM agent skill).',
            '**Teams (group chat, 15:14-15:15 UTC):** Briefed Nir on two DM bugs.',
            '',
            '---'
        )
        $obs = Build-DailyObservation -BodyLines $body -Role 'direct'
        Assert-Match 'PRs completed today' $obs
        Assert-NotMatch '^Role:' $obs
    }

    It 'falls back to first non-Role bold-key when no preferred keys present' {
        $body = @(
            '**Role:** Software Engineer',
            '**Email to Nir:** Meeting invite "Kusto Transient Error bug" at 10:00 IDT.'
        )
        $obs = Build-DailyObservation -BodyLines $body -Role 'direct'
        Assert-Match 'Email to Nir' $obs
        Assert-NotMatch '^\*\*Role' $obs
    }

    It 'skips horizontal-rule separators between sections' {
        $body = @(
            '',
            '**Active PR:** 15604369 - Report successful streaming ingestions.',
            '',
            '---'
        )
        $obs = Build-DailyObservation -BodyLines $body -Role 'direct'
        Assert-NotMatch '^-+$' $obs
        Assert-Match 'Active PR' $obs
    }

    It 'returns null for empty body' {
        $obs = Build-DailyObservation -BodyLines @() -Role 'direct'
        Assert-True ($null -eq $obs -or $obs -eq '') 'expected null/empty for empty body'
    }
}

Describe 'ConvertFrom-CommunicationsJson - 2026-05-19+ Cowork shape' {
    It 'splits the (email, role, direct report) parenthetical into Name + Role' {
        $json = '{"communications":[{"person":"Teammate1 (someone@example.com, Senior SWE, direct report)","channel":"Teams","time_utc":"2026-05-19T11:21Z","summary":"Requested urgent review of PR 15741904.","action":"Review ASAP"}]}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        Assert-Equal 1 $entries.Count
        Assert-Match '^Teammate1 - Senior SWE, direct report$' $entries[0].Heading
        $body = ($entries[0].BodyLines -join "`n")
        Assert-Match 'Discussion topic: Requested urgent review of PR 15741904' $body
        Assert-Match 'Action item: Review ASAP' $body
        Assert-Match 'Teams @ 2026-05-19T11:21Z' $body
    }

    It 'unwraps "Azure DevOps Notifications (on behalf of <RealName>)"' {
        $json = '{"communications":[{"person":"Azure DevOps Notifications (on behalf of Teammate67)","channel":"Email","summary":"PR review request."}]}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        Assert-Equal 1 $entries.Count
        Assert-Equal 'Teammate67' $entries[0].Heading
        Assert-NotMatch 'Notifications' $entries[0].Heading
    }

    It 'drops automated / bot / notification senders' {
        $json = @'
{"communications":[
  {"person":"Nirvana Agent (automated)","summary":"Sprint announced."},
  {"person":"Your Name","summary":"self-mention"},
  {"person":"Some Bot (bot)","summary":"noise"},
  {"person":"Microsoft Graph Notifications","summary":"auto-ping"},
  {"person":"Real Person","summary":"actual content here"}
]}
'@
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        Assert-Equal 1 $entries.Count
        Assert-Equal 'Real Person' $entries[0].Heading
    }

    It 'prefixes summary with subject when both present' {
        $json = '{"communications":[{"person":"Teammate45","subject":"GitHub access","summary":"shared izikl handle"}]}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        Assert-Match 'Discussion topic: GitHub access -- shared izikl handle' ($entries[0].BodyLines -join "`n")
    }

    It 'suppresses "None"/"Completed" actions but keeps the discussion topic' {
        $json = @'
{"communications":[
  {"person":"Teammate22","summary":"positive feedback exchange","action":"None - relationship building"},
  {"person":"Teammate45","summary":"shared github handle","action":"Completed - no further action"}
]}
'@
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        Assert-Equal 2 $entries.Count
        foreach ($e in $entries) {
            Assert-NotMatch 'Action item:' ($e.BodyLines -join "`n")
            Assert-Match 'Discussion topic:'  ($e.BodyLines -join "`n")
        }
    }

    It 'returns @() when no communications property exists' {
        $obj = (@{ date = '2026-05-19'; people = @() } | ConvertTo-Json) | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        Assert-Equal 0 $entries.Count
    }

    It 'returns @() when communications is empty' {
        $obj = '{"communications":[]}' | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        Assert-Equal 0 $entries.Count
    }

    It 'handles the full 2026-05-19 fixture end-to-end' {
        $json = @'
{
  "date":"2026-05-19", "format":"markdown",
  "overview":{"emails_received":1,"top_themes":["PR Reviews"]},
  "communications":[
    {"person":"Teammate1 (someone@example.com, Senior Software Engineer, direct report)",
     "channel":"Teams","time_utc":"2026-05-19T11:21Z",
     "summary":"Requested urgent review of PR 15741904.","action":"Review ASAP"},
    {"person":"Azure DevOps Notifications (on behalf of Teammate67)",
     "channel":"Email","time_utc":"2026-05-19T13:14Z",
     "subject":"PR 15776393","summary":"Nir added as reviewer.",
     "action":"Review and approve PR 15776393"},
    {"person":"Nirvana Agent (automated)","channel":"Teams","summary":"Sprint 2Wk25 created.","action":"None"},
    {"person":"Teammate45","channel":"Teams - 1:1 chat","time_utc":"2026-05-19T13:48Z",
     "summary":"shared GitHub handle izikl","action":"Completed - no further action"},
    {"person":"Teammate22","channel":"Teams - 1:1 chat","time_utc":"2026-05-19T05:50Z",
     "summary":"unsolicited positive feedback on Nir presentation",
     "action":"None - relationship building exchange"}
  ]
}
'@
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-CommunicationsJson -Obj $obj)
        $headings = @($entries | ForEach-Object { $_.Heading })
        Assert-Equal 4 $entries.Count "expected 4 entries (skipping Nirvana Agent), got: $($headings -join ' | ')"
        Assert-Contains 'Teammate67' $headings
        Assert-Contains 'Teammate45' $headings
        Assert-Contains 'Teammate22' $headings
        Assert-Match '^Teammate1 - Senior Software Engineer, direct report$' (($headings | Where-Object { $_ -match 'Teammate1' }) -join '')
    }
}

Describe 'ConvertFrom-GenericPersonArrayJson - forward-compat fallback' {
    It 'picks up a top-level "interactions" array of name+summary objects' {
        $json = '{"date":"2026-06-01","interactions":[{"name":"Foo Bar","summary":"did a thing"},{"name":"Baz Qux","summary":"did another thing"}]}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-GenericPersonArrayJson -Obj $obj)
        Assert-Equal 2 $entries.Count
        $headings = @($entries | ForEach-Object { $_.Heading })
        Assert-Contains 'Foo Bar' $headings
        Assert-Contains 'Baz Qux' $headings
    }

    It 'prefers an array with higher name+body coverage' {
        # "noise" array has names but no body fields; "good" has both.
        $json = '{"noise":[{"name":"X"},{"name":"Y"}],"good":[{"who":"Real Name","notes":"real content"}]}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-GenericPersonArrayJson -Obj $obj)
        Assert-Equal 1 $entries.Count
        Assert-Equal 'Real Name' $entries[0].Heading
    }

    It 'ignores string-only arrays like top_themes' {
        $json = '{"top_themes":["theme 1","theme 2","theme 3"]}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-GenericPersonArrayJson -Obj $obj)
        Assert-Equal 0 $entries.Count
    }

    It 'drops bots / automated entries' {
        $json = '{"messages":[{"sender":"Some Bot (bot)","content":"noise"},{"sender":"Real Human","content":"signal"}]}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-GenericPersonArrayJson -Obj $obj)
        Assert-Equal 1 $entries.Count
        Assert-Equal 'Real Human' $entries[0].Heading
    }

    It 'returns @() when no array looks person-shaped' {
        $json = '{"foo":"bar","baz":42}'
        $obj = $json | ConvertFrom-Json
        $entries = @(ConvertFrom-GenericPersonArrayJson -Obj $obj)
        Assert-Equal 0 $entries.Count
    }
}

Describe 'ConvertTo-FlattenedThemeMarkdown - last-resort string flattener' {
    It 'flattens nested string values into a markdown bullet list' {
        $obj = [pscustomobject]@{
            overview = [pscustomobject]@{
                top_themes = @('first long theme here', 'second long theme also')
                action_required = @('do thing alpha')
            }
            communications = @(
                [pscustomobject]@{ person = 'Teammate1'; summary = 'a substantive summary line' }
            )
        }
        $md = ConvertTo-FlattenedThemeMarkdown -Obj $obj
        Assert-True ($null -ne $md) 'expected non-null markdown'
        Assert-Match '## Synthesized themes' $md
        Assert-Match 'first long theme here' $md
        Assert-Match 'second long theme also' $md
        Assert-Match 'do thing alpha' $md
        Assert-Match 'Teammate1' $md
        Assert-Match 'a substantive summary line' $md
    }

    It 'skips short strings (< 10 chars)' {
        $obj = [pscustomobject]@{ short = 'hi'; long = 'a long enough string to keep' }
        $md = ConvertTo-FlattenedThemeMarkdown -Obj $obj
        Assert-NotMatch '^\- hi$' $md
        Assert-Match 'a long enough string to keep' $md
    }

    It 'returns $null on a JSON object containing only primitives/short strings' {
        $obj = [pscustomobject]@{ x = 1; y = $true; z = 'no' }
        $md = ConvertTo-FlattenedThemeMarkdown -Obj $obj
        Assert-True ($null -eq $md) 'expected null for a no-signal object'
    }

    It 'returns $null on $null input' {
        $md = ConvertTo-FlattenedThemeMarkdown -Obj $null
        Assert-True ($null -eq $md) 'expected null for null input'
    }
}

Describe 'Get-JsonTopLevelKeys - drift diagnostic' {
    It 'returns a comma-joined list of top-level property names' {
        $obj = '{"date":"x","communications":[],"overview":{}}' | ConvertFrom-Json
        Assert-Equal 'date, communications, overview' (Get-JsonTopLevelKeys -Obj $obj)
    }

    It 'returns empty string on null/empty input' {
        Assert-Equal '' (Get-JsonTopLevelKeys -Obj $null)
    }

    It 'returns the literal "(empty)" sentinel on an empty parsed object (so log lines stay readable)' {
        $obj = '{}' | ConvertFrom-Json
        Assert-Equal '(empty)' (Get-JsonTopLevelKeys -Obj $obj)
    }
}

Describe 'Test-IsCoworkUploadStub - quiet-skip upload-tool scaffolding' {
    It 'returns $false on $null input' {
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $null)
    }

    It 'returns $false on an array (e.g. top-level JSON array)' {
        $arr = '[{"name":"x"},{"name":"y"}]' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $arr)
    }

    It 'returns $false on a legitimate communications-schema object' {
        $obj = '{"date":"2026-05-20","communications":[],"overview":{}}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects the Cowork __file_upload__ placeholder (Shape 1)' {
        $obj = '{"__file_upload__":true,"local_path":"/mnt/workspace/output/x.md"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects a literal empty object "{}" as upload-in-flight scaffolding (2026-05-28 incident, SHA-256 44136fa3...)' {
        $obj = '{}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'ignores __file_upload__:false (treated as not a stub)' {
        $obj = '{"__file_upload__":false,"local_path":"/mnt/workspace/output/x.md"}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects an all-Graph-metadata stub like @microsoft.graph.conflictBehavior (Shape 2)' {
        $obj = '{"@microsoft.graph.conflictBehavior":"replace"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects multi-key all-Graph-metadata stubs' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","@odata.context":"https://graph.microsoft.com"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects the Graph driveItem envelope with content:"placeholder" (Shape 3)' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","content":"placeholder"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects Graph envelope with empty-string content' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","content":""}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects Graph envelope with whitespace-only content' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","content":"   \n\t  "}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects Graph envelope with case-variant "Placeholder"' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","content":"Placeholder"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'allows Graph envelope with sibling driveItem fields (name, size, webUrl) when content is stubbed' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","name":"DailySummary.md","size":71,"webUrl":"https://...","content":"placeholder"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'does NOT quiet-skip when content carries real markdown (Shape 1 markdown-wrapper case)' {
        $real = '## By Person' + "`n`n" + '### Teammate1' + "`n" + 'Discussion topic: shipping' + "`n"
        $obj = [pscustomobject]@{
            '@odata.type' = '#microsoft.graph.driveItem'
            'content'     = $real
        }
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'does NOT quiet-skip an object with a content key but no Graph metadata' {
        $obj = [pscustomobject]@{ content = 'placeholder' }
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'does NOT quiet-skip a Graph envelope with an unrecognized substantive sibling key' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","communications":[{"person":"X","summary":"y"}]}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'covers the live 2026-05-23 file shape verbatim' {
        $raw = '{"@odata.type": "#microsoft.graph.driveItem", "content": "placeholder"}'
        $obj = $raw | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects Graph envelope with short scaffolding content "# test" (Shape 3b, live 2026-05-26)' {
        # The exact bytes that landed in DailySummary_2026-05-26.md and triggered the
        # "unknown JSON shape; keys: @odata.type, content" alert email this rule was
        # added to suppress. Keep this literal in case Cowork drifts another shape and
        # we forget which alert we were silencing.
        $raw = '{"@odata.type": "#microsoft.graph.driveItem", "content": "# test"}'
        $obj = $raw | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects Graph envelope with short scaffolding content "# placeholder"' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","content":"# placeholder"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'detects Graph envelope with bare scaffolding content (no markdown markers at all)' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","content":"hello world"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'does NOT quiet-skip Graph envelope when content has a "## " heading (theme-mode signal)' {
        $obj = [pscustomobject]@{
            '@odata.type' = '#microsoft.graph.driveItem'
            'content'     = "## Themes`n`n- Mise V2 rollout"
        }
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'does NOT quiet-skip Graph envelope when content has a "### " heading (per-person signal)' {
        $obj = [pscustomobject]@{
            '@odata.type' = '#microsoft.graph.driveItem'
            'content'     = "### Teammate1`nshipped the gRPC retry fix"
        }
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }

    It 'does NOT quiet-skip Graph envelope when content is long (>= 256 chars) even without headings' {
        # Defensive: a real summary could theoretically be rendered as a long prose blob
        # with no markdown markers. Length alone gates it through to theme/flattened-theme.
        $long = 'a' * 300
        $obj = [pscustomobject]@{
            '@odata.type' = '#microsoft.graph.driveItem'
            'content'     = $long
        }
        Assert-Equal $false (Test-IsCoworkUploadStub -Obj $obj)
    }
}

Describe 'run-daily-summary-import.ps1 - upload-stub wiring' {
    It 'calls Test-IsCoworkUploadStub from the main loop and quiet-logs the keys' {
        $runnerText = Get-Content -Raw -Path $runnerPath
        Assert-Match 'Test-IsCoworkUploadStub\s+-Obj\s+\$obj'    $runnerText
        Assert-Match 'Skip:\s+upload\s+stub\s+\(keys:'           $runnerText
        Assert-NotMatch '__file_upload__=true'                   $runnerText
    }
}

Describe 'Test-IsCoworkPointerStub - quiet-skip sentinel/pointer docs' {
    It 'returns $false on $null input' {
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $null)
    }

    It 'returns $false on an array (top-level JSON array)' {
        $arr = '[{"_doc_type":"x"}]' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $arr)
    }

    It 'returns $false on an empty object' {
        $obj = '{}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    # --- Signal 1: underscore-prefixed sentinel fields ----------------------

    It 'detects the live 2026-05-24 .json shape (_doc_type, _date, _owner, _note, markdown_content_truncated_indicator)' {
        $raw = '{"_doc_type":"daily_summary_markdown_v1","_date":"2026-05-24","_owner":"you@example.com","_note":"see email","markdown_content_truncated_indicator":"in email"}'
        $obj = $raw | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects the live 2026-05-24 .md shape (_doc_type, _date, _owner, _note, see_email, markdown_url_in_email)' {
        $raw = '{"_doc_type":"daily_summary_v1_json_wrapped","_date":"2026-05-24","_owner":"you@example.com","_note":"see email","see_email":"Daily Activity Summary","markdown_url_in_email":"Attached as DailySummary_2026-05-24.md"}'
        $obj = $raw | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects a single underscore-prefixed property even when other fields are mundane' {
        $obj = '{"_schema":"v2","date":"2026-05-24","title":"x"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    # --- Signal 2: explicit "look in the email" pointer keys ----------------

    It 'detects see_email as a pointer key (case-insensitive)' {
        $obj = '{"date":"2026-05-24","See_Email":"Daily Activity Summary"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects markdown_url_in_email as a pointer key' {
        $obj = '{"date":"2026-05-24","markdown_url_in_email":"attached"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects markdown_content_truncated_indicator as a pointer key' {
        $obj = '{"date":"2026-05-24","markdown_content_truncated_indicator":"see email"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects the live 2026-05-27 file_path sandbox-pointer shape (regression: false-alarm error email)' {
        $raw = '{"file_path": "/mnt/workspace/output/DailySummary_2026-05-27.md"}'
        $obj = $raw | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects file_path as a pointer key (case-insensitive)' {
        $obj = '{"date":"2026-05-27","File_Path":"/mnt/workspace/x.md"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects sibling sandbox-pointer keys (source_path, local_file, sandbox_path, output_path)' {
        foreach ($k in @('source_path','local_file','sandbox_path','output_path')) {
            $obj = ("{`"date`":`"2026-05-27`",`"$k`":`"/mnt/workspace/x.md`"}") | ConvertFrom-Json
            Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
        }
    }

    It 'does NOT quiet-skip a legitimate doc that mentions file_path alongside real content' {
        $real = '## By Person' + "`n`n" + '### Teammate1' + "`n" + 'Discussion topic: shipping'
        $obj = [pscustomobject]@{
            'file_path' = '/mnt/workspace/output/DailySummary_2026-05-27.md'
            'content'   = $real
        }
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    # --- Signal 2b: forward-compat generic suffix-match heuristic -----------
    # Forward-compat for the next stub shape Cowork invents (e.g.
    # output_uri, payload_path, manifest_location). Catches any non-graph,
    # non-allow-list key whose name ends in _path/_url/_file/_location/_uri
    # and whose value is a non-empty string, AS LONG AS every non-graph,
    # non-underscore-prefixed key in the object matches that rule OR an
    # allow-list of safe sibling keys (name/size/id/etag/etc.).

    It 'detects a forward-compat output_uri shape (one suffix-matched pointer key)' {
        $obj = '{"output_uri":"/mnt/workspace/output/x.md"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects a forward-compat payload_path shape with safe siblings (name, size)' {
        $obj = '{"payload_path":"/mnt/workspace/x.md","name":"x.md","size":42}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects a forward-compat manifest_location shape' {
        $obj = '{"manifest_location":"/mnt/workspace/out/manifest.json"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'does NOT quiet-skip when a suffix-matched key has an empty string value (genuinely unknown shape)' {
        $obj = '{"output_uri":""}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'does NOT quiet-skip when a non-suffix non-allow-list key exists alongside a suffix-matched key' {
        # A real summary that carries a `report_url` attribution alongside an
        # unrecognized `topic_count` (substantive-shaped key) must NOT be
        # quiet-skipped. The substantive-content override only catches well-known
        # content keys; this case relies on the suffix-match guard.
        $obj = '{"report_url":"http://x","topic_count":7}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'does NOT quiet-skip when there are zero suffix-matched keys (avoids overlap with Signal 3)' {
        # A pure allow-list-only doc is upload-control territory, not pointer.
        # Test ensures the suffix-match path does not fire spuriously on objects
        # with no pointer-shaped key.
        $obj = '{"name":"x.md","size":42,"id":"abc"}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    # --- Signal 3: upload-control-only key set ------------------------------

    It 'detects the live 2026-05-24 first-shape upload-control trio (sourcePath, uploadAsRaw, contentType)' {
        $raw = '{"sourcePath":"/mnt/workspace/output/x.md","uploadAsRaw":true,"contentType":"text/markdown"}'
        $obj = $raw | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects a single-key upload-control doc (uploadAsRaw only)' {
        $obj = '{"uploadAsRaw":true}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'detects upload-control with extra mediaType/charset fields' {
        $obj = '{"sourcePath":"/x","contentType":"text/markdown","mediaType":"text/markdown","charset":"utf-8"}' | ConvertFrom-Json
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'does NOT classify as upload-control when a non-control key sneaks in' {
        $obj = '{"sourcePath":"/x","contentType":"text/markdown","content":"## By Person\n\n### Teammate1"}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    # --- Substantive-content override --------------------------------------

    It 'does NOT quiet-skip a legitimate markdown-wrapper even when an underscore field exists' {
        $real = '## By Person' + "`n`n" + '### Teammate1' + "`n" + 'Discussion topic: shipping'
        $obj = [pscustomobject]@{
            '_doc_type' = 'daily_summary_v1'
            'date'      = '2026-05-24'
            'content'   = $real
        }
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'does NOT quiet-skip a legitimate structured shape with non-empty people[]' {
        $obj = [pscustomobject]@{
            '_doc_type' = 'daily_summary_v2'
            'date'      = '2026-05-24'
            'people'    = @(
                [pscustomobject]@{ name = 'Teammate1'; actions = @('shipped X') }
            )
        }
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'does NOT quiet-skip a legitimate communications shape with non-empty communications[]' {
        $obj = [pscustomobject]@{
            'see_email'      = 'header text'
            'communications' = @(
                [pscustomobject]@{ person = 'X'; summary = 'y' }
            )
        }
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'DOES quiet-skip when content is the literal "placeholder" string (no real data)' {
        $obj = [pscustomobject]@{
            '_doc_type' = 'daily_summary_v1'
            'content'   = 'placeholder'
        }
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'DOES quiet-skip when content is whitespace-only (no real data)' {
        $obj = [pscustomobject]@{
            '_doc_type' = 'daily_summary_v1'
            'content'   = "   `n`t  "
        }
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'DOES quiet-skip when people[] is present but empty' {
        $obj = [pscustomobject]@{
            '_doc_type' = 'daily_summary_v2'
            'people'    = @()
        }
        Assert-Equal $true (Test-IsCoworkPointerStub -Obj $obj)
    }

    # --- Mundane shapes that must pass through unchanged --------------------

    It 'returns $false on a Graph-metadata upload stub (handled by Test-IsCoworkUploadStub, not us)' {
        $obj = '{"@odata.type":"#microsoft.graph.driveItem","content":"placeholder"}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }

    It 'returns $false on a normal markdown-wrapper shape' {
        $obj = '{"date":"2026-05-24","owner":"Your Name","format":"markdown","content":"## By Person\n\n### Teammate1"}' | ConvertFrom-Json
        Assert-Equal $false (Test-IsCoworkPointerStub -Obj $obj)
    }
}

Describe 'run-daily-summary-import.ps1 - pointer-stub wiring' {
    It 'calls Test-IsCoworkPointerStub from the main loop and quiet-logs the keys' {
        $runnerText = Get-Content -Raw -Path $runnerPath
        Assert-Match 'Test-IsCoworkPointerStub\s+-Obj\s+\$obj'   $runnerText
        Assert-Match 'Skip:\s+pointer\s+stub\s+\(keys:'          $runnerText
    }

    It 'invokes Test-IsCoworkPointerStub AFTER Test-IsCoworkUploadStub in the main loop' {
        $runnerText = Get-Content -Raw -Path $runnerPath
        $idxUpload  = $runnerText.IndexOf('Test-IsCoworkUploadStub -Obj $obj')
        $idxPointer = $runnerText.IndexOf('Test-IsCoworkPointerStub -Obj $obj')
        Assert-Equal $true ($idxUpload  -gt 0)
        Assert-Equal $true ($idxPointer -gt 0)
        Assert-Equal $true ($idxPointer -gt $idxUpload)
    }
}

Describe 'Test-IsMarkdownStub - quiet-skip non-JSON .md placeholder/pointer files' {
    It 'returns $false on $null input' {
        Assert-Equal $false (Test-IsMarkdownStub -Text $null)
    }

    It 'detects an empty file' {
        Assert-Equal $true (Test-IsMarkdownStub -Text '')
    }

    It 'detects a whitespace-only file' {
        Assert-Equal $true (Test-IsMarkdownStub -Text "   `r`n`t  `n ")
    }

    It 'detects a title-only stub ("# Daily Summary <date>" and nothing else) (2026-05-28 incident)' {
        Assert-Equal $true (Test-IsMarkdownStub -Text "# Daily Summary 2026-05-28`n")
    }

    It 'detects a "real content is in the companion email" pointer body' {
        $md = "# Daily Summary 2026-05-28`n`nThe real content is in the companion email."
        Assert-Equal $true (Test-IsMarkdownStub -Text $md)
    }

    It 'detects a "see the email" pointer phrase (case-insensitive)' {
        $md = "# DailySummary`n`nPlease SEE THE EMAIL for the full summary."
        Assert-Equal $true (Test-IsMarkdownStub -Text $md)
    }

    It 'detects a "content truncated" / truncation-indicator pointer' {
        $md = "# Summary`n`n[content truncated - markdown_content_truncated_indicator]"
        Assert-Equal $true (Test-IsMarkdownStub -Text $md)
    }

    It 'does NOT classify a real summary with per-person headings as a stub' {
        $md = "# Daily Summary 2026-05-28`n`n## By Person`n`n### Teammate1`n- shipped the gRPC retry fix`n`n### Teammate4`n- completed migration validation`n"
        Assert-Equal $false (Test-IsMarkdownStub -Text $md)
    }

    It 'does NOT classify a long body with no heading as a stub (only short + headingless qualifies)' {
        $long = '# Title' + "`n`n" + ('Lots of genuine narrative content. ' * 20)
        Assert-Equal $false (Test-IsMarkdownStub -Text $long)
    }

    It 'does NOT misfire on a short body that DOES carry a "###" person heading' {
        $md = "## By Person`n### Bob`n- did a thing"
        Assert-Equal $false (Test-IsMarkdownStub -Text $md)
    }
}

Describe 'run-daily-summary-import.ps1 - markdown-stub wiring' {
    It 'calls Test-IsMarkdownStub and quiet-logs a markdown-stub skip' {
        $runnerText = Get-Content -Raw -Path $runnerPath
        Assert-Match 'Test-IsMarkdownStub\s+-Text\s+\$rawText' $runnerText
        Assert-Match 'Skip:\s+markdown\s+stub'                 $runnerText
    }

    It 'gates the markdown-stub guard to non-JSON .md files only (cannot suppress new JSON shapes)' {
        $runnerText = Get-Content -Raw -Path $runnerPath
        Assert-Match '\$null\s+-eq\s+\$obj\s+-and\s+\$f\.Extension\s+-ieq\s+''\.md''' $runnerText
    }

    It 'runs the markdown-stub guard BEFORE the no-schema ERROR branch' {
        $runnerText = Get-Content -Raw -Path $runnerPath
        $idxGuard = $runnerText.IndexOf('Test-IsMarkdownStub -Text $rawText')
        $idxError = $runnerText.IndexOf('file matches no known schema')
        Assert-Equal $true ($idxGuard -gt 0)
        Assert-Equal $true ($idxError -gt 0)
        Assert-Equal $true ($idxGuard -lt $idxError)
    }
}

# Cleanup
try { Remove-Item $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Exit-WithTestResults

