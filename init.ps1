<#
.SYNOPSIS
  Initialize / re-initialize a manager-agent install from config answers.

.DESCRIPTION
  Two modes:
    - Engine (non-interactive): -ConfigFile <path-to-answers.json>
        Reads a JSON file with all answers, applies them, writes config files,
        renders generated artifacts (AGENTS.md, prompts/CUSTOM_INSTRUCTIONS.md).
    - Interactive (default): prompts for each answer, builds an in-memory
        answer object, then calls the same engine path.

  Effects:
    - Writes config/agent.json from answers.
    - Writes config/banner.txt (custom path | default ASCII | empty if skipped).
    - Writes config/voice.md (with an "active banks" pointer to chosen profile).
    - Writes config/signature-notice.txt (empty by default; user edits later).
    - Renders AGENTS.md via _shared/render-agents.ps1.
    - Renders prompts/CUSTOM_INSTRUCTIONS.md from prompts/CUSTOM_INSTRUCTIONS.md.tmpl.

  Does NOT:
    - Register scheduled tasks (use -RegisterTasks; otherwise prints commands).
    - Delete examples/personal/.
    - Prompt for personas (capability-gated; persona-dependent skills are
      auto-disabled in AGENTS.md if team-personas/people/ is empty — Phase 9
      snapshot tool will enforce this gating).
    - Prompt for feature toggles (the agent.json features.* block is
      aspirational; runtime gating is not yet wired — see Phase 8 critique
      blocker #1, deferred).

.PARAMETER ConfigFile
  Path to a JSON answers file. Schema: same shape as config/agent.json plus
  optional 'banner_source' (default|file:<path>|skip), 'voice_profile'
  (none|nirvana-band|kusto-kql|<path>), and 'register_tasks' (bool).
  When present, runs non-interactively.

.PARAMETER RegisterTasks
  Run the generic scheduled-task registrar after init. Skipped by default.

.PARAMETER Force
  Overwrite existing config/agent.json without confirmation.

.EXAMPLE
  .\init.ps1 -ConfigFile answers.json
  .\init.ps1                         # interactive
#>
[CmdletBinding()]
param(
    [string] $ConfigFile,
    [switch] $RegisterTasks,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = $PSScriptRoot

function Read-Default([string]$prompt, [string]$default) {
    $line = Read-Host ("{0} [{1}]" -f $prompt, $default)
    if ([string]::IsNullOrWhiteSpace($line)) { return $default }
    return $line
}

function Read-Choice([string]$prompt, [string[]]$choices, [string]$default) {
    $line = Read-Host ("{0} ({1}) [{2}]" -f $prompt, ($choices -join '|'), $default)
    if ([string]::IsNullOrWhiteSpace($line)) { return $default }
    if ($choices -notcontains $line) { throw "Invalid choice: $line. Expected one of: $($choices -join ', ')" }
    return $line
}

function Get-Answers-Interactive {
    Write-Host ""
    Write-Host "=== Manager-Agent Init ===" -ForegroundColor Cyan
    Write-Host "Press <enter> to accept the default in [brackets]." -ForegroundColor DarkGray
    Write-Host ""
    $name           = Read-Default "Agent display name" "Nirvana"
    $managerFirst   = Read-Default "Manager first name" "Nir"
    $managerFull    = Read-Default "Manager full name" ("$managerFirst Boger")
    $managerEmail   = Read-Default "Manager email" "$($managerFirst.ToLower())@example.com"
    $managerAlias   = Read-Default "Manager alias (e.g. ad-username)" $managerFirst.ToLower()
    $adoOrg         = Read-Default "ADO org" "your-ado-org"
    $adoProject     = Read-Default "ADO project" "One"
    $teamName       = Read-Default "Team display name" "My Team"
    $teamAlias      = Read-Default "Team alias (short)" "myteam"
    $reportsRoot    = Read-Default "Reports root (relative path)" "reports"
    $tasksPrefix    = Read-Default "Scheduled-task prefix" $managerAlias.Substring(0,[Math]::Min(3,$managerAlias.Length)).ToUpper()
    $bannerSource   = Read-Choice  "Banner source" @('default','file','skip') 'default'
    $bannerFile     = if ($bannerSource -eq 'file') { Read-Default "Path to banner file" "" } else { '' }
    $voiceProfile   = Read-Choice  "Voice profile" @('none','nirvana-band','kusto-kql','custom') 'none'
    $voiceCustom    = if ($voiceProfile -eq 'custom') { Read-Default "Path to voice profile" "config/voice.md" } else { '' }
    $localeLang     = Read-Default "Locale language" "en"
    $localeTz       = Read-Default "Timezone (IANA, e.g. America/Los_Angeles)" "Asia/Jerusalem"
    $localeTzAbbr   = Read-Default "Timezone abbreviation" "PT"
    $weekStart      = Read-Default "Work week start (Sun|Mon)" "Mon"

    return [pscustomobject]@{
        agent_name      = $name
        manager_first   = $managerFirst
        manager_full    = $managerFull
        manager_email   = $managerEmail
        manager_alias   = $managerAlias
        ado_org         = $adoOrg
        ado_project     = $adoProject
        team_name       = $teamName
        team_alias      = $teamAlias
        reports_root    = $reportsRoot
        tasks_prefix    = $tasksPrefix
        banner_source   = $bannerSource
        banner_file     = $bannerFile
        voice_profile   = $voiceProfile
        voice_custom    = $voiceCustom
        locale_language = $localeLang
        locale_timezone = $localeTz
        locale_tz_abbr  = $localeTzAbbr
        week_start      = $weekStart
    }
}

function Build-AgentConfig($a) {
    $voicePath = switch ($a.voice_profile) {
        'none'         { '' }
        'nirvana-band' { 'examples/voice-profiles/nirvana-band.md' }
        'kusto-kql'    { 'examples/voice-profiles/kusto-kql.md' }
        'custom'       { $a.voice_custom }
        default        { '' }
    }
    return [ordered]@{
        agent     = [ordered]@{
            name                = $a.agent_name
            trigger_aliases     = @($a.agent_name.ToLower(), '@' + $a.agent_name.ToLower())
            mail_subject_prefix = '[' + $a.agent_name + ']'
            idempotency_tag     = $a.agent_name + 'Processed'
            banner_path         = 'config/banner.txt'
        }
        manager   = [ordered]@{
            first_name = $a.manager_first
            full_name  = $a.manager_full
            email      = $a.manager_email
            alias      = $a.manager_alias
        }
        ado       = [ordered]@{ org = $a.ado_org; project = $a.ado_project }
        team      = [ordered]@{ name = $a.team_name; alias = $a.team_alias }
        tasks     = [ordered]@{ prefix = $a.tasks_prefix }
        paths     = [ordered]@{
            reports_root         = $a.reports_root
            team_personas_people = '.copilot/skills/team-personas/people'
            connect_buddy_root   = '%USERPROFILE%/.copilot/connect-buddy'
        }
        locale    = [ordered]@{
            language               = $a.locale_language
            timezone               = $a.locale_timezone
            timezone_abbreviation  = $a.locale_tz_abbr
            work_week_start        = $a.week_start
        }
        signature = [ordered]@{
            auto_reply_disclosure       = '{first} is on the thread; reply directly if I got it wrong.'
            brand_html                  = ''
            whatsapp_group_signature_he = ''
            notice_path                 = 'config/signature-notice.txt'
        }
        voice     = [ordered]@{ profile_path = $voicePath }
        features  = [ordered]@{
            inbox_watch       = $false
            team_milestones   = $false
            connect_buddy     = $false
            whatsapp          = $false
            pilates           = $false
            kusto_codebase    = $false
        }
    }
}

function Apply-Init($a) {
    Write-Host ""
    Write-Host "Applying init..." -ForegroundColor Cyan

    # 1. agent.json
    $cfg = Build-AgentConfig $a
    $cfgJson = ($cfg | ConvertTo-Json -Depth 8)
    $cfgPath = Join-Path $repoRoot 'config\agent.json'
    if ((Test-Path $cfgPath) -and -not $Force) {
        $confirm = Read-Host "config/agent.json already exists. Overwrite? [y/N]"
        if ($confirm -notmatch '^[yY]') { Write-Host "Aborted."; return }
    }
    [System.IO.File]::WriteAllText($cfgPath, $cfgJson, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "  wrote config/agent.json"

    # 2. banner
    $bannerOut = Join-Path $repoRoot 'config\banner.txt'
    switch ($a.banner_source) {
        'default' {
            if (-not (Test-Path $bannerOut)) {
                $defaultBanner = "    [ banner placeholder for $($a.agent_name) - replace with your own ]"
                [System.IO.File]::WriteAllText($bannerOut, $defaultBanner, (New-Object System.Text.UTF8Encoding $false))
                Write-Host "  wrote config/banner.txt (placeholder)"
            } else { Write-Host "  config/banner.txt already exists - left alone" }
        }
        'file' {
            if (-not (Test-Path $a.banner_file)) { throw "Banner file not found: $($a.banner_file)" }
            Copy-Item $a.banner_file $bannerOut -Force
            Write-Host "  copied banner from $($a.banner_file)"
        }
        'skip' {
            [System.IO.File]::WriteAllText($bannerOut, "", (New-Object System.Text.UTF8Encoding $false))
            Write-Host "  wrote config/banner.txt (empty)"
        }
    }

    # 3. signature-notice (start empty unless user has one already)
    $noticePath = Join-Path $repoRoot 'config\signature-notice.txt'
    if (-not (Test-Path $noticePath)) {
        [System.IO.File]::WriteAllText($noticePath, "", (New-Object System.Text.UTF8Encoding $false))
        Write-Host "  wrote config/signature-notice.txt (empty)"
    }

    # 4. voice.md (rewrite to reflect chosen profile)
    $voicePath = Join-Path $repoRoot 'config\voice.md'
    $voiceContent = "# Active voice profile`r`n`r`nThis file is what ``voice.profile_path`` in ``config/agent.json`` points to. The`r`njoke playbook (`_shared/joke-playbook.md`) is voice-agnostic - flavor-bonus`r`nmaterial lives here.`r`n`r`n## Active banks`r`n`r`n"
    switch ($a.voice_profile) {
        'none'         { $voiceContent += "(none)`r`n" }
        'nirvana-band' { $voiceContent += "- ``examples/voice-profiles/nirvana-band.md```r`n" }
        'kusto-kql'    { $voiceContent += "- ``examples/voice-profiles/kusto-kql.md```r`n" }
        'custom'       { $voiceContent += "- ``$($a.voice_custom)```r`n" }
    }
    [System.IO.File]::WriteAllText($voicePath, $voiceContent, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "  wrote config/voice.md"

    # 5. AGENTS.md via render-agents.ps1
    Write-Host "  rendering AGENTS.md..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot '.copilot\skills\_shared\render-agents.ps1')
    if ($LASTEXITCODE -ne 0) { throw "AGENTS.md render failed" }

    # 6. prompts/CUSTOM_INSTRUCTIONS.md
    Write-Host "  rendering prompts/CUSTOM_INSTRUCTIONS.md..."
    . (Join-Path $repoRoot '.copilot\skills\_shared\render-template.ps1')
    . (Join-Path $repoRoot '.copilot\skills\_shared\config.ps1')
    Clear-AgentConfigCache
    $tplPath = Join-Path $repoRoot 'prompts\CUSTOM_INSTRUCTIONS.md.tmpl'
    $outPath = Join-Path $repoRoot 'prompts\CUSTOM_INSTRUCTIONS.md'
    if (Test-Path $tplPath) {
        $tpl = Get-Content -Raw -Encoding UTF8 $tplPath
        $cfgLoaded = Get-AgentConfig
        function ConvertTo-RenderHashtable2 {
            param($Obj)
            if ($null -eq $Obj) { return $null }
            if ($Obj -is [System.Management.Automation.PSCustomObject]) {
                $h = @{}
                foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-RenderHashtable2 $p.Value }
                return $h
            }
            return $Obj
        }
        $rendered = Render-Template -Template $tpl -Context (ConvertTo-RenderHashtable2 $cfgLoaded)
        [System.IO.File]::WriteAllText($outPath, $rendered, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "    wrote $outPath"
    } else { Write-Host "    template missing: $tplPath" -ForegroundColor Yellow }

    # 7. scheduled tasks
    if ($RegisterTasks) {
        Write-Host "  registering scheduled tasks (-RegisterTasks)..." -ForegroundColor Yellow
        Write-Host "  (no generic registrar yet - skipping; see examples/personal/pilates/register-tasks.ps1 for an example)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "Scheduled tasks NOT registered. Example: see examples/personal/pilates/register-tasks.ps1." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "init: OK" -ForegroundColor Green
    Write-Host "Next: .\doctor.ps1   then   .\smoke-test.ps1" -ForegroundColor Cyan
}

# --- Main -----------------------------------------------------------------
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) { throw "Config file not found: $ConfigFile" }
    $a = Get-Content -Raw -Encoding UTF8 $ConfigFile | ConvertFrom-Json
    Apply-Init $a
} else {
    $a = Get-Answers-Interactive
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    $a | Format-List | Out-String | Write-Host
    $confirm = Read-Host "Apply? [Y/n]"
    if ($confirm -match '^[nN]') { Write-Host "Aborted."; exit 0 }
    Apply-Init $a
}

