# Rebuilds the hot-cache persona sections (## Areas of ownership /
# ## Project ledger / ## Frequent collaborators) from scratch by replaying
# every JSON drop in reports/personas-archive/<YYYY-MM-DD>/.
#
# Use cases:
#   - First-run backfill after a mining rule change (regex, denylist, vocab).
#   - Recovery if the .copilot/skills/team-personas/people-state/*.json
#     sidecars are deleted or corrupted.
#   - One-off audit ("rebuild personas from cold cache and tell me what shifted").
#
# This runner NEVER touches:
#   - The daily-capture handoff folder (reports/daily-capture/published/).
#   - ## Notes, ## Daily observations, ## Employment, ## Snapshot, or any other
#     hand-curated section of a persona file.
# It ONLY rewrites the three auto-maintained sections in place and the
# people-state/<alias>.json sidecars.
#
# Manual:
#   powershell -File <repo>\.copilot\skills\run-personas-rebuild.ps1
#   powershell -File ... -Alias Teammate1-Teammate1          # rebuild one persona only
#   powershell -File ... -DryRun                     # log what would change, no writes
#   powershell -File ... -KeepExisting               # merge into existing state instead of starting from scratch

[CmdletBinding()]
param(
    [string[]]$Alias,
    [switch]$DryRun,
    [switch]$KeepExisting
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '_shared\runner-prelude.ps1')

$personasSkill = Join-Path $AgentRoot '.copilot\skills\team-personas'
$peopleDir     = Resolve-AgentPath (Get-AgentField -Path 'paths.team_personas_people' -Default '.copilot/skills/team-personas/people' -Config $AgentConfig) -Config $AgentConfig

. (Join-Path $personasSkill 'persona-mining.ps1')

$stateDir   = Get-PersonaStateDir   -PersonasSkillRoot $personasSkill
$archiveDir = Get-PersonaArchiveDir -AgentRoot $AgentRoot
$repoVocab  = Get-PersonaRepoVocab  -PersonasSkillRoot $personasSkill

$logFile = Join-Path $LogDir ("personas-rebuild-" + (Get-Date -Format 'yyyy-MM-dd_HHmm') + ".log")
function Write-Log { param([string]$Message) $line = "$(Get-Date -Format o) $Message"; Add-Content -Path $logFile -Value $line -Encoding UTF8; Write-Host $line }

# Single-instance lock (shared with import runner -- they touch the same state).
$lockPath = Join-Path $LogDir 'personas-rebuild.lock'
if (Test-Path $lockPath) {
    $lockAge = (Get-Date) - (Get-Item $lockPath).LastWriteTime
    if ($lockAge.TotalMinutes -lt 60) { Write-Log "Skip: another rebuild in progress (lock age $([int]$lockAge.TotalSeconds)s)."; exit 0 }
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}
"$PID @ $(Get-Date -Format o)" | Set-Content -Path $lockPath -Encoding UTF8

try {
    if (-not (Test-Path $archiveDir)) {
        Write-Log "Archive folder missing: $archiveDir -- nothing to replay."
        return
    }

    # Build alias -> list of (date, jsonPath) tuples from the archive layout.
    $aliasDrops = @{}
    $dated = Get-ChildItem $archiveDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name
    foreach ($d in $dated) {
        foreach ($jf in (Get-ChildItem $d.FullName -File -Filter *.json -ErrorAction SilentlyContinue)) {
            # Strip optional HHmmss disambiguation suffix before alias conversion:
            #   Teammate1.json            -> Teammate1-Teammate1
            #   Teammate1.121530.json     -> Teammate1-Teammate1
            $name = $jf.Name
            $stripped = $name -replace '\.\d{6}(?=\.json$)',''
            $aliasFromFile = Convert-FilenameToAlias $stripped
            if (-not $aliasFromFile) { continue }
            if ($Alias -and ($Alias -notcontains $aliasFromFile)) { continue }
            if (-not $aliasDrops.ContainsKey($aliasFromFile)) { $aliasDrops[$aliasFromFile] = New-Object System.Collections.ArrayList }
            [void]$aliasDrops[$aliasFromFile].Add(@{ Date = $d.Name; Path = $jf.FullName })
        }
    }

    if ($aliasDrops.Count -eq 0) {
        Write-Log "No archive drops matched (archive=$archiveDir, alias filter=$($Alias -join ','))."
        return
    }

    $totals = [pscustomobject]@{ Aliases = 0; Drops = 0; AreaMentions = 0; CollabMentions = 0; Errors = 0; Skipped = 0 }
    foreach ($aliasKey in ($aliasDrops.Keys | Sort-Object)) {
        $personPath = Join-Path $peopleDir "$aliasKey.md"
        if (-not (Test-Path $personPath)) {
            Write-Log "  ${aliasKey}: SKIP -- no persona file at $personPath"
            $totals.Skipped++
            continue
        }

        # Either start fresh or merge into the current state.
        if ($KeepExisting) {
            $state = Load-PersonaState -StateDir $stateDir -Alias $aliasKey
            Write-Log "  ${aliasKey}: keeping existing state (areas=$($state.areas.Count), collab=$($state.collaborators.Count))"
        } else {
            $state = New-EmptyPersonaState -Alias $aliasKey
        }
        $selfName = Convert-AliasToDisplayName -Alias $aliasKey

        $dropList = $aliasDrops[$aliasKey] | Sort-Object { $_.Date }
        $aliasAreas = 0; $aliasCollab = 0
        foreach ($drop in $dropList) {
            try {
                $j = Get-Content $drop.Path -Raw -Encoding UTF8 | ConvertFrom-Json
                $signal = Get-PersonaDropSignal -ContentMd $j.content -RepoVocab $repoVocab
                $state  = Update-PersonaState -State $state -Signal $signal -DropDate $drop.Date -SelfName $selfName
                $aliasAreas  += @($signal.areas).Count
                $aliasCollab += @($signal.collaborators).Count
                $totals.Drops++
            } catch {
                $totals.Errors++
                Write-Log "  ERROR replaying $($drop.Path): $($_.Exception.Message)"
            }
        }
        $totals.AreaMentions   += $aliasAreas
        $totals.CollabMentions += $aliasCollab
        $totals.Aliases++

        if ($DryRun) {
            Write-Log "  ${aliasKey}: would write -- areas=$($state.areas.Count) collab=$($state.collaborators.Count) ledger=$($state.ledger.Count) months (drops=$($dropList.Count))"
        } else {
            Save-PersonaState -StateDir $stateDir -State $state
            Write-PersonaSections -PersonPath $personPath -State $state
            Write-Log "  ${aliasKey}: wrote -- areas=$($state.areas.Count) collab=$($state.collaborators.Count) ledger=$($state.ledger.Count) months (drops=$($dropList.Count))"
        }
    }

    Write-Log "Rebuild done. Aliases=$($totals.Aliases) Drops=$($totals.Drops) AreaMentions=$($totals.AreaMentions) CollabMentions=$($totals.CollabMentions) Skipped=$($totals.Skipped) Errors=$($totals.Errors) DryRun=$DryRun KeepExisting=$KeepExisting"

    if (-not $DryRun -and ($totals.Aliases -gt 0 -or $totals.Errors -gt 0)) {
        . (Join-Path $PSScriptRoot '_runner-email.ps1')
        $body = New-Object System.Collections.ArrayList
        [void]$body.Add("<p><b>Rebuild completed.</b> Replayed $($totals.Drops) drop(s) across $($totals.Aliases) persona(s) from the cold cache.</p>")
        [void]$body.Add("<p><b>Signal:</b> $($totals.AreaMentions) area mention(s), $($totals.CollabMentions) collaborator mention(s).</p>")
        [void]$body.Add("<p><b>Mode:</b> KeepExisting=$KeepExisting (false = wipe state and rebuild from cold cache)</p>")
        if ($totals.Skipped -gt 0) { [void]$body.Add("<p style='color:#b80'><b>Skipped:</b> $($totals.Skipped) alias(es) with no persona file in <code>people/</code>.</p>") }
        if ($totals.Errors -gt 0)  { [void]$body.Add("<p style='color:#b00'><b>Errors:</b> $($totals.Errors) drop(s) failed to parse. See log.</p>") }
        [void]$body.Add("<p style='color:#888;font-size:12px'>Log: <code>$logFile</code></p>")
        $jokes = @(
            "Hot cache rebuilt from cold cache. Like a phoenix, but with less drama and more JSON.",
            "Past-life regression for personas: replayed the archive, came back wiser.",
            "Areas re-counted. Ledger re-stamped. Collaborators re-tallied. Now back to your regular programming.",
            "The cold cache is the source of truth. Today we just reminded the hot cache."
        )
        [void](Send-RunnerSummaryEmail -RunnerName 'DM-PersonasRebuild' -SubjectSuffix "aliases=$($totals.Aliases), drops=$($totals.Drops), errors=$($totals.Errors)" -BodyHtml ($body -join "`n") -JokePool $jokes)
    }
}
finally {
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

