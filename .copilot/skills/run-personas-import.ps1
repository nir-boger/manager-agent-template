# Imports daily persona drops from the local daily-capture handoff folder into
# the team-personas skill.
#
# Source pattern (run-daily-capture.ps1 publishes raw per-persona data per day):
#   <agent-root>\reports\daily-capture\published\personas\<YYYY-MM-DD>\<File>.{json,md}
#   (configurable via paths.daily_capture_personas in config/agent.json)
#
# Two file formats supported (auto-detected by extension):
#
# A) **JSON** (legacy Cowork shape, still supported) — schema:
#       { "format":"markdown",
#         "person_file":"<DisplayName>.md",
#         "capture_window_start":"...", "capture_window_end":"...",
#         "content":"<markdown blob with Teams Messages + Emails sections>" }
#    Filename convention is PascalCase_Underscore (e.g. Teammate1.json,
#    Teammate9.json). The runner converts it to kebab-case (Teammate1-Teammate1,
#    ran-ben-Teammate9) by splitting on underscore AND on CamelCase boundaries.
#    Behavior: mines behavioral quotes + top email subjects from the markdown
#    content and appends idempotent dated lines to people/<alias>.md
#    ## Daily observations. Does NOT overwrite the persona template — the
#    daily-capture producer is the collector, Nirvana is the analyst.
#
# B) **Markdown** (current daily-capture output / synthesized drops) — full persona template.
#    Behavior: overwrites people/<alias>.md while preserving curated
#    ## Notes and ## Daily observations sections (existing-first, dedupe).
#
# Common behavior:
#   - Updates team-overview.md "Last refreshed" date.
#   - Appends an entry to sources.txt.
#   - Deletes the dated source folder after successful import.
#   - Logs to <repo>\reports\logs\personas-import-<YYYY-MM-DD>.log.
#   - Sends a summary email to Nir when work happened or errors occurred.
#
# Invoked every 10 min by the DM-PersonasImport scheduled task (daily 00:00,
# PT10M repetition for 24h). Idempotent — source folder is deleted after import.
# Manual:  powershell -File <repo>\.copilot\skills\run-personas-import.ps1

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$personasSkill = Join-Path $AgentRoot '.copilot\skills\team-personas'
$peopleDir     = Resolve-AgentPath (Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $AgentConfig) -Config $AgentConfig
$overview      = Join-Path $personasSkill 'team-overview.md'
$sourcesFile   = Join-Path $personasSkill 'sources.txt'
$personasRoot  = Resolve-AgentPath (Get-AgentField -Path 'paths.daily_capture_personas' -Default 'reports/daily-capture/published/personas' -Config $AgentConfig) -Config $AgentConfig

# Hot/cold cache plumbing (Areas of ownership / Project ledger / Frequent collaborators).
. (Join-Path $personasSkill 'persona-mining.ps1')
$stateDir   = Get-PersonaStateDir   -PersonasSkillRoot $personasSkill
$archiveDir = Get-PersonaArchiveDir -AgentRoot $AgentRoot
$repoVocab  = Get-PersonaRepoVocab  -PersonasSkillRoot $personasSkill

$logFile = Join-Path $LogDir ("personas-import-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Curated-section preservation helpers ---------------------------------

# Extract the body of an H2 section (lines after the heading until the next H2 or EOF).
# Returns $null when the section is absent.
function Get-MdSection {
    param([string]$Content, [string]$Heading)
    if (-not $Content) { return $null }
    $escaped = [regex]::Escape($Heading)
    $pattern = "(?ms)^##\s+$escaped\s*\r?\n(.*?)(?=^##\s|\Z)"
    $m = [regex]::Match($Content, $pattern)
    if ($m.Success) {
        return $m.Groups[1].Value.TrimEnd("`r","`n"," ","`t")
    }
    return $null
}

# Remove an H2 section (heading + body) from a markdown blob.
function Remove-MdSection {
    param([string]$Content, [string]$Heading)
    if (-not $Content) { return $Content }
    $escaped = [regex]::Escape($Heading)
    $pattern = "(?ms)^##\s+$escaped\s*\r?\n.*?(?=^##\s|\Z)"
    return [regex]::Replace($Content, $pattern, '')
}

# Merge two sets of section lines, existing-first, exact-match dedupe, drop blank lines.
function Merge-SectionLines {
    param([string]$Existing, [string]$Incoming)
    $existingLines = @()
    $incomingLines = @()
    if ($Existing) { $existingLines = $Existing -split "`r?`n" | Where-Object { $_.Trim() -ne '' } }
    if ($Incoming) { $incomingLines = $Incoming -split "`r?`n" | Where-Object { $_.Trim() -ne '' } }
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($l in @($existingLines) + @($incomingLines)) {
        if (-not $seen.ContainsKey($l)) { $seen[$l] = $true; [void]$out.Add($l) }
    }
    return ($out -join "`r`n")
}

# --- JSON-drop helpers ----------------------------------------------------

# Convert Cowork's PascalCase_Underscore filename to our kebab-case alias.
# Canonical implementation lives in team-personas/persona-mining.ps1 (so the
# rebuild runner and any future tooling can call it too). Dot-sourced above.

# Behavioral-signal regex pool (Hebrew + English). Patterns must match a single
# blockquote line (lines starting with "> ") in the markdown content.
$script:BehavioralPatterns = @(
    @{ Tag='Channel preference'; Re='(?i)(call me|phone is better|prefer.*(call|phone)|push.*notif|התראות?\s*בטלפון|תתקשר|whatsapp)' },
    @{ Tag='Stated position';     Re='(?i)(I (don''?t |do not )?(think|believe|disagree|agree)|I (don''?t|won''?t)|אני חושב|אני לא חושב|אני מסכים|אני לא מסכים|לדעתי)' },
    @{ Tag='Boundary signal';     Re='(?i)(not over the weekend|wait until sunday|won''?t merit a hotfix|not a hotfix|on (leave|reserve)|במילואים|בחופש|לא דחוף)' },
    @{ Tag='Pushback invite';     Re='(?i)(push back if|tell me if I''?m wrong|disagree.*push|תגיד לי אם)' },
    @{ Tag='After-hours apology'; Re='(?i)(sorry to (bother|disturb).*(weekend|friday|night)|מצטער על השעה)' }
)

# Append a single line to the ## Daily observations section of a persona file.
# Idempotent: returns $false if the exact line already exists in the file.
function Append-DailyObservation {
    param([string]$PersonPath, [string]$Line)
    if (-not (Test-Path $PersonPath)) { return $false }
    $content = Get-Content $PersonPath -Raw -Encoding UTF8
    if ($content -match [regex]::Escape($Line)) { return $false }
    if ($content -notmatch '(?ms)^## Daily observations\s*$') {
        $content = $content.TrimEnd() + "`r`n`r`n## Daily observations`r`n$Line`r`n"
    } else {
        $content = $content -replace '(?ms)(^## Daily observations\s*\r?\n)', "`$1$Line`r`n"
    }
    Set-Content -Path $PersonPath -Value $content -Encoding UTF8 -NoNewline:$false
    return $true
}

# Extract behavioral quotes + top email subjects from a JSON drop's markdown
# content, then append dated observation lines to people/<alias>.md.
# Returns @{ Behavioral=<int>; Topic=<int>; Skipped=$false; Reason=$null }.
function Import-PersonaJsonDrop {
    param([string]$JsonPath, [string]$PeopleDir, [string]$CaptureDate, [string]$SourceFile)

    $j = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $alias = Convert-FilenameToAlias $j.person_file
    $personPath = Join-Path $PeopleDir "$alias.md"
    if (-not (Test-Path $personPath)) {
        return @{ Alias=$alias; Behavioral=0; Topic=0; Skipped=$true; Reason="no persona file at $personPath" }
    }

    $behavioralAdded = 0
    $topicAdded = 0
    $seenQuotes = @{}

    foreach ($p in $script:BehavioralPatterns) {
        $matches = [regex]::Matches($j.content, "(?m)^>\s*.*$($p.Re).*$")
        foreach ($m in $matches) {
            $quote = ($m.Value -replace '^>\s*','').Trim()
            if ($quote.Length -gt 240) { $quote = $quote.Substring(0, 240) + [char]0x2026 }
            $key = "$($p.Tag)::$quote"
            if ($seenQuotes.ContainsKey($key)) { continue }
            $seenQuotes[$key] = $true
            $line = "- $CaptureDate (behavioral, raw): $($p.Tag): ""$quote"" [src: $SourceFile]"
            if (Append-DailyObservation $personPath $line) { $behavioralAdded++ }
        }
    }

    # One topic line per file, drawn from the first 3 non-noise email subjects.
    $subjects = [regex]::Matches($j.content, '(?m)^- Subject:\s*(.+)$') |
        ForEach-Object { $_.Groups[1].Value.Trim() } |
        Where-Object { $_ -notmatch '(?i)nirvana|funny joke' } |
        Select-Object -Unique -First 3
    if ($subjects -and $subjects.Count -gt 0) {
        $topic = ($subjects -join ' | ')
        if ($topic.Length -gt 240) { $topic = $topic.Substring(0, 240) + [char]0x2026 }
        $emDash = [char]0x2014
        $line = "- $CaptureDate (raw 24h): top email threads $emDash $topic [src: $SourceFile]"
        if (Append-DailyObservation $personPath $line) { $topicAdded++ }
    }

    return @{ Alias=$alias; Behavioral=$behavioralAdded; Topic=$topicAdded; Skipped=$false; Reason=$null }
}

# --- Single-instance lock ---
$lockPath = Join-Path $LogDir 'personas-import.lock'
if (Test-Path $lockPath) {
    $lockAge = (Get-Date) - (Get-Item $lockPath).LastWriteTime
    if ($lockAge.TotalMinutes -lt 30) { Write-Log "Skip: another run in progress (lock age $([int]$lockAge.TotalSeconds)s)."; exit 0 }
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {
    if (-not (Test-Path $personasRoot)) {
        Write-Log "Personas root missing: $personasRoot - nothing to do."
        exit 0
    }

    # Note: we intentionally do NOT sweep empty dated folders. They are harmless -
    # the script ignores any dated folder that has no .md/.json files.

    # Find every <date>/ folder under the Personas root that has at least one .md OR .json file.
    $datedFolders = Get-ChildItem $personasRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and (Get-ChildItem $_.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.md','.json' })
    }

    if (-not $datedFolders) {
        Write-Log "No new persona drops found under $personasRoot."
        exit 0
    }

    $importedAny = $false
    $totals = [pscustomobject]@{ Files = 0; Folders = 0; Errors = 0; Behavioral = 0; Topics = 0; SkippedNoFile = 0; AreaMentions = 0; UniqueAreas = 0; CollabMentions = 0 }
    $aliasesImported = New-Object System.Collections.Generic.HashSet[string]

    foreach ($folder in $datedFolders) {
        $folderPath = $folder.FullName
        $folderDate = $folder.Name
        Write-Log "Importing from $folderPath"
        $folderOk = $true

        $files = Get-ChildItem $folderPath -File | Where-Object { $_.Extension -in '.md','.json' }
        foreach ($f in $files) {
            try {
                if ($f.Extension -ieq '.json') {
                    # --- JSON branch (raw signal -> ## Daily observations) ---------
                    $r = Import-PersonaJsonDrop -JsonPath $f.FullName -PeopleDir $peopleDir -CaptureDate $folderDate -SourceFile $f.Name
                    if ($r.Skipped) {
                        $totals.SkippedNoFile++
                        Write-Log "  $($r.Alias): SKIP - $($r.Reason)"
                    } else {
                        $totals.Files++
                        $totals.Behavioral += $r.Behavioral
                        $totals.Topics     += $r.Topic
                        if ($r.Behavioral -gt 0 -or $r.Topic -gt 0) { [void]$aliasesImported.Add($r.Alias) }

                        # Hot-cache mining: Areas / Ledger / Collaborators.
                        try {
                            $personPath = Join-Path $peopleDir ($r.Alias + '.md')
                            $mineResult = Invoke-PersonaMineForDrop `
                                -JsonPath   $f.FullName `
                                -Alias      $r.Alias `
                                -DropDate   $folderDate `
                                -StateDir   $stateDir `
                                -PersonPath $personPath `
                                -RepoVocab  $repoVocab
                            $totals.AreaMentions   += [int]$mineResult.Areas
                            $totals.UniqueAreas    += [int]$mineResult.UniqueAreas
                            $totals.CollabMentions += [int]$mineResult.Collaborators
                            [void]$aliasesImported.Add($r.Alias)
                            Write-Log ("  {0}: behavioral={1} topic={2} areas={3} (unique={4}) collab={5}" -f $r.Alias, $r.Behavioral, $r.Topic, $mineResult.Areas, $mineResult.UniqueAreas, $mineResult.Collaborators)
                        } catch {
                            Write-Log "  WARN mining $($r.Alias): $($_.Exception.Message)"
                        }
                    }
                    continue
                }

                # --- Markdown branch (legacy: synthesized persona template) -----
                $alias = Convert-FilenameToAlias $f.Name
                $dest  = Join-Path $peopleDir ($alias + '.md')

                # Read existing curated sections (if file exists).
                $existing = if (Test-Path $dest) { Get-Content $dest -Raw -Encoding UTF8 } else { '' }
                $existingNotes      = Get-MdSection $existing 'Notes'
                $existingDaily      = Get-MdSection $existing 'Daily observations'
                $existingEmployment = Get-MdSection $existing 'Employment'

                # Read incoming Cowork drop and strip any Notes/Daily-observations/Employment it may carry.
                $newContent = Get-Content $f.FullName -Raw -Encoding UTF8
                $incomingNotes = Get-MdSection $newContent 'Notes'
                $incomingDaily = Get-MdSection $newContent 'Daily observations'
                $newContent = Remove-MdSection $newContent 'Notes'
                $newContent = Remove-MdSection $newContent 'Daily observations'
                $newContent = Remove-MdSection $newContent 'Employment'
                $newContent = $newContent.TrimEnd("`r","`n"," ","`t")

                # Merge curated sections (existing-first, dedupe).
                $mergedNotes = Merge-SectionLines $existingNotes $incomingNotes
                $mergedDaily = Merge-SectionLines $existingDaily $incomingDaily

                $sb = New-Object System.Text.StringBuilder
                [void]$sb.Append($newContent)
                if ($existingEmployment) {
                    [void]$sb.Append("`r`n`r`n## Employment`r`n")
                    [void]$sb.Append($existingEmployment)
                    [void]$sb.Append("`r`n")
                }
                [void]$sb.Append("`r`n`r`n## Notes`r`n")
                if ($mergedNotes) { [void]$sb.Append($mergedNotes); [void]$sb.Append("`r`n") }
                [void]$sb.Append("`r`n## Daily observations`r`n")
                if ($mergedDaily) { [void]$sb.Append($mergedDaily); [void]$sb.Append("`r`n") }

                Set-Content -Path $dest -Value $sb.ToString() -Encoding UTF8 -NoNewline:$false

                # Canonicalize the H1 right after the write so the upstream
                # Cowork wording (e.g. "Working-Style Persona: Teammate1")
                # never leaks into the site sidebar. Mirrors the same call
                # in Write-PersonaSections for the JSON branch.
                $h1Content = Get-Content $dest -Raw -Encoding UTF8
                $h1Fixed   = Set-CanonicalPersonaH1 -Content $h1Content -Alias $alias
                if ($h1Fixed -ne $h1Content) {
                    Set-Content -Path $dest -Value $h1Fixed -Encoding UTF8 -NoNewline:$false
                }

                $totals.Files++
                [void]$aliasesImported.Add($alias)

                $notesCount = if ($mergedNotes) { ($mergedNotes -split "`r?`n").Count } else { 0 }
                $dailyCount = if ($mergedDaily) { ($mergedDaily -split "`r?`n").Count } else { 0 }
                Write-Log "  ${alias}: preserved Notes=$notesCount, Daily=$dailyCount  ->  $dest"
            }
            catch {
                $totals.Errors++
                $folderOk = $false
                Write-Log "  ERROR importing $($f.Name): $($_.Exception.Message)"
            }
        }

        if ($folderOk) {
            try {
                # Cold-cache archive: move files to reports/personas-archive/<date>/
                # (de-duplicate by appending HHmmss suffix if a file with the
                # same name already exists -- happens when the producer re-drops
                # the same day). Once the dated folder is empty, remove it
                # locally; the handoff folder is local, so the delete is clean
                # (no cloud-side resurrection to defend against).
                $archiveDate = Join-Path $archiveDir $folderDate
                New-Item -ItemType Directory -Force -Path $archiveDate | Out-Null
                foreach ($af in (Get-ChildItem $folderPath -File -ErrorAction SilentlyContinue)) {
                    $dest = Join-Path $archiveDate $af.Name
                    if (Test-Path $dest) {
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($af.Name)
                        $ext  = $af.Extension
                        $dest = Join-Path $archiveDate ("{0}.{1}{2}" -f $base, (Get-Date -Format 'HHmmss'), $ext)
                    }
                    Move-Item -Path $af.FullName -Destination $dest -Force
                }
                Remove-Item $folderPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Archived source folder to $archiveDate (and removed $folderPath)."
                $totals.Folders++
                $importedAny = $true
                $logEntry = '# {0} imported {1} persona file(s) from {2} (date {3}); behavioral={4} topics={5} areas={6} collab={7} skipped={8}; archive: {9}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $files.Count, $folderPath, $folderDate, $totals.Behavioral, $totals.Topics, $totals.AreaMentions, $totals.CollabMentions, $totals.SkippedNoFile, $archiveDate
                Add-Content -Path $sourcesFile -Encoding UTF8 -Value $logEntry
            }
            catch {
                $totals.Errors++
                Write-Log ("ERROR archiving " + $folderPath + ": " + $_.Exception.Message)
            }
        }
        else {
            Write-Log ("Source folder " + $folderPath + " kept - one or more files failed. Fix and re-run.")
        }
    }

    if ($importedAny) {
        # Update "Last refreshed" header in team-overview.md.
        try {
            $today = Get-Date -Format 'yyyy-MM-dd'
            $ov = Get-Content $overview -Raw -Encoding UTF8
            $ov = [regex]::Replace($ov, '(?m)^>\s*\*\*Last refreshed:\*\*\s*.*$', "> **Last refreshed:** $today (auto-imported by DM-PersonasImport)")
            Set-Content -Path $overview -Value $ov -Encoding UTF8 -NoNewline:$false
            Write-Log "Updated team-overview.md last-refreshed to $today."
        }
        catch {
            Write-Log "WARN: could not update team-overview.md header: $($_.Exception.Message)"
        }
    }

    Write-Log "Done. Files=$($totals.Files) Folders=$($totals.Folders) Behavioral=$($totals.Behavioral) Topics=$($totals.Topics) Areas=$($totals.AreaMentions) Collab=$($totals.CollabMentions) SkippedNoFile=$($totals.SkippedNoFile) Errors=$($totals.Errors)."

    # --- End-of-run summary email (only when work happened or errors occurred) ----
    if ($importedAny -or $totals.Errors -gt 0) {
        . (Join-Path $PSScriptRoot '_runner-email.ps1')

        $aliases = @($aliasesImported | Sort-Object)
        $subjectSuffix = "files=$($totals.Files), behavioral=$($totals.Behavioral), topics=$($totals.Topics), areas=$($totals.AreaMentions), collab=$($totals.CollabMentions), errors=$($totals.Errors)"

        $bodyParts = New-Object System.Collections.ArrayList
        [void]$bodyParts.Add("<p><b>Imported:</b> $($totals.Files) persona file(s) from $($totals.Folders) dated folder(s).</p>")
        [void]$bodyParts.Add("<p><b>Signal mined:</b> $($totals.Behavioral) behavioral quote(s), $($totals.Topics) topic line(s), $($totals.AreaMentions) area mention(s), $($totals.CollabMentions) collaborator mention(s).</p>")
        [void]$bodyParts.Add("<p><b>Cold cache:</b> raw drops archived to <code>reports/personas-archive/&lt;date&gt;/</code> (never deleted).</p>")
        if ($aliases.Count -gt 0) {
            [void]$bodyParts.Add("<p><b>Aliases refreshed:</b> " + ($aliases -join ', ') + "</p>")
        }
        if ($totals.SkippedNoFile -gt 0) {
            [void]$bodyParts.Add("<p style='color:#b80'><b>Skipped (no persona file):</b> $($totals.SkippedNoFile) &mdash; check filename mapping.</p>")
        }
        if ($totals.Errors -gt 0) {
            [void]$bodyParts.Add("<p style='color:#b00'><b>Errors:</b> $($totals.Errors) &mdash; source folders kept for retry. Check the log.</p>")
        }
        [void]$bodyParts.Add("<p style='color:#888;font-size:12px'>Log: <code>$logFile</code></p>")

        $jokes = @(
            "Personas refreshed. Hot cache stocked; cold cache filed; mind reading still off.",
            "Areas of ownership counted, collaborators tallied. The persona file finally remembers who works on what.",
            "Cowork drops the raw, Nirvana shelves the cold and stocks the hot. Cache hierarchy, baby.",
            "Hebrew quotes preserved; WIT counters incremented; nothing diagnostic, nothing manipulative.",
            "Another day of evidence, neatly accreted. The persona slowly becomes itself."
        )

        [void](Send-RunnerSummaryEmail `
            -RunnerName 'DM-PersonasImport' `
            -SubjectSuffix $subjectSuffix `
            -BodyHtml ($bodyParts -join "`n") `
            -JokePool $jokes)
    }
}
finally {
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

