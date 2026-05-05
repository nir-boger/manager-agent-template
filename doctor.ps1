<#
.SYNOPSIS
  Validates the agent install: config completeness, asset existence, render
  freshness, parse-check on every .ps1.

.DESCRIPTION
  Two modes:
    - Live (default): validate the working tree the user is editing.
      Skips the snapshot-only literal-leak grep.
    - Snapshot (-Root <path>): validate a built snapshot. Runs the literal-leak
      grep against the configured denylist.

  Used by smoke-test.ps1 and by tools/build-snapshot.ps1 (Phase 9).

.PARAMETER Root
  When set, doctor validates the snapshot tree at <Root> instead of the live
  agent root. Activates the literal-leak grep.

.PARAMETER LeakDenylist
  Words that must NOT appear in any snapshot-shipped file (case-insensitive).
  Defaults to the manager's identifying strings derived from config.

.EXAMPLE
  .\doctor.ps1
  .\doctor.ps1 -Root C:\tmp\manager-agent-template
  .\doctor.ps1 -Root C:\tmp\manager-agent-template -LeakDenylist 'manager@example.com','my-id'
#>
[CmdletBinding()]
param(
    [string]   $Root,
    [string[]] $LeakDenylist
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Write-Section($s) { Write-Host ""; Write-Host "== $s ==" -ForegroundColor Cyan }
function Write-Pass($s)    { Write-Host "  [PASS] $s" -ForegroundColor Green }
function Write-Fail($s)    { Write-Host "  [FAIL] $s" -ForegroundColor Red; $script:_Failed++ }
function Write-Skip($s)    { Write-Host "  [SKIP] $s" -ForegroundColor DarkGray }

$script:_Failed = 0

# --- Resolve which root we're checking -----------------------------------
$snapshotMode = [bool]$Root
if ($snapshotMode) {
    if (-not (Test-Path $Root)) { throw "Root not found: $Root" }
    $checkRoot = (Resolve-Path $Root).Path
} else {
    . (Join-Path $PSScriptRoot '.copilot\skills\_shared\config.ps1')
    $checkRoot = Resolve-AgentRoot
}
Write-Host "Checking: $checkRoot" -ForegroundColor White
Write-Host ("Mode:     {0}" -f $(if ($snapshotMode) {'snapshot'} else {'live'})) -ForegroundColor White

# --- 1. config/agent.json required scalars --------------------------------
Write-Section 'config/agent.json'
$cfgPath = Join-Path $checkRoot 'config\agent.json'
if (-not (Test-Path $cfgPath)) {
    Write-Fail "config/agent.json not found"
} else {
    $cfg = Get-Content -Raw -Encoding UTF8 $cfgPath | ConvertFrom-Json
    $required = @(
        @{ path = 'agent.name';                 name = 'agent.name' },
        @{ path = 'agent.trigger_aliases';      name = 'agent.trigger_aliases (array)' },
        @{ path = 'agent.mail_subject_prefix';  name = 'agent.mail_subject_prefix' },
        @{ path = 'agent.idempotency_tag';      name = 'agent.idempotency_tag' },
        @{ path = 'manager.first_name';         name = 'manager.first_name' },
        @{ path = 'manager.email';              name = 'manager.email' },
        @{ path = 'ado.org';                    name = 'ado.org' },
        @{ path = 'ado.project';                name = 'ado.project' },
        @{ path = 'team.name';                  name = 'team.name' },
        @{ path = 'paths.reports_root';         name = 'paths.reports_root' },
        @{ path = 'tasks.prefix';               name = 'tasks.prefix' }
    )
    foreach ($r in $required) {
        $val = $cfg
        foreach ($p in $r.path -split '\.') {
            if ($null -eq $val) { break }
            $val = $val.PSObject.Properties[$p].Value
        }
        $populated = if ($val -is [array]) { $val.Count -gt 0 } else { -not [string]::IsNullOrWhiteSpace([string]$val) }
        if ($populated) { Write-Pass $r.name } else { Write-Fail "missing or empty: $($r.name)" }
    }
}

# --- 2. config-referenced assets exist ------------------------------------
Write-Section 'config-referenced assets'
if ($cfg) {
    $assets = @(
        @{ path = (Join-Path $checkRoot ([string]$cfg.agent.banner_path));      name = "banner ($($cfg.agent.banner_path))";       optional = $true },
        @{ path = (Join-Path $checkRoot ([string]$cfg.voice.profile_path));     name = "voice profile ($($cfg.voice.profile_path))"; optional = $true },
        @{ path = (Join-Path $checkRoot ([string]$cfg.signature.notice_path));  name = "signature notice ($($cfg.signature.notice_path))"; optional = $true }
    )
    foreach ($a in $assets) {
        if ([string]::IsNullOrWhiteSpace($a.path)) { Write-Skip "$($a.name) (not configured)"; continue }
        if (Test-Path $a.path) { Write-Pass $a.name }
        elseif ($a.optional)   { Write-Skip "$($a.name) (optional, not present)" }
        else                   { Write-Fail "missing: $($a.name)" }
    }
}

# --- 3. config/skills.json paths ------------------------------------------
Write-Section 'config/skills.json'
$skillsPath = Join-Path $checkRoot 'config\skills.json'
if (-not (Test-Path $skillsPath)) {
    Write-Fail "config/skills.json not found"
} else {
    $manifest = Get-Content -Raw -Encoding UTF8 $skillsPath | ConvertFrom-Json
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in $manifest.skills) {
        if (-not $names.Add($s.name)) { Write-Fail "duplicate name: $($s.name)" }
        $skillRoot = Join-Path $checkRoot $s.path
        if (-not (Test-Path $skillRoot)) { Write-Fail "$($s.name): path missing ($($s.path))"; continue }
        if ($s.surface -ne 'local-only') {
            $skillMd = Join-Path $skillRoot 'SKILL.md'
            if (-not (Test-Path $skillMd)) { Write-Fail "$($s.name): SKILL.md missing"; continue }
        }
        if ($s.entrypoint_path) {
            $ep = Join-Path $checkRoot $s.entrypoint_path
            if (-not (Test-Path $ep)) { Write-Fail "$($s.name): entrypoint missing ($($s.entrypoint_path))"; continue }
        }
        Write-Pass $s.name
    }
}

# --- 4. AGENTS.md is in sync ---------------------------------------------
Write-Section 'AGENTS.md (rendered from template)'
$renderer = Join-Path $checkRoot '.copilot\skills\_shared\render-agents.ps1'
if (-not (Test-Path $renderer)) {
    Write-Fail "render-agents.ps1 not found"
} else {
    $tmpEnv = $env:AGENT_ROOT
    try {
        $env:AGENT_ROOT = $checkRoot
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $renderer -Check 2>&1
        $rc = $LASTEXITCODE
        if ($rc -eq 0) { Write-Pass "AGENTS.md matches a fresh render" }
        else           { Write-Fail "AGENTS.md is out of sync: $output" }
    } finally {
        if ($null -eq $tmpEnv) { Remove-Item Env:AGENT_ROOT -ErrorAction SilentlyContinue }
        else { $env:AGENT_ROOT = $tmpEnv }
    }
}

# --- 5. Parse-check every .ps1 -------------------------------------------
Write-Section 'PowerShell parse-check'
$rootPrefix = [regex]::Escape($checkRoot.TrimEnd('\','/'))
$psFiles = Get-ChildItem -Path $checkRoot -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Where-Object {
        $rel = if ($_.FullName -match "^$rootPrefix[\\/](.*)$") { $matches[1] } else { $_.FullName }
        $rel -notmatch '^(node_modules|\.git|tmp|reports)[\\/]'
    }
$badParse = 0
foreach ($f in $psFiles) {
    $errors = $null
    [void][System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -Encoding UTF8 $f.FullName), [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Fail ("parse error: {0} ({1})" -f $f.FullName.Substring($checkRoot.Length+1), $errors[0].Message)
        $badParse++
    }
}
if ($badParse -eq 0) { Write-Pass "$($psFiles.Count) .ps1 files parse cleanly" }

# --- 6. Snapshot-only: literal-leak grep ---------------------------------
if ($snapshotMode) {
    Write-Section 'snapshot leak-grep (denylist)'
    if (-not $LeakDenylist -or $LeakDenylist.Count -eq 0) {
        # Default denylist is PII-only: full name, alias, email. Brand strings
        # (e.g. agent name) intentionally allowed in body prose since the
        # template repo ships as a worked example.
        $defaultEmail   = $cfg.manager.email
        $defaultAlias   = $cfg.manager.alias
        $defaultFull    = $cfg.manager.full_name
        $defaultDenylist = @()
        if ($defaultFull   -and $defaultFull   -ne 'Your Name')      { $defaultDenylist += $defaultFull }
        if ($defaultAlias  -and $defaultAlias  -ne 'youralias')      { $defaultDenylist += $defaultAlias }
        if ($defaultEmail  -and $defaultEmail  -ne 'you@example.com'){ $defaultDenylist += $defaultEmail }
        $LeakDenylist = $defaultDenylist
    }
    if (-not $LeakDenylist -or $LeakDenylist.Count -eq 0) {
        Write-Skip "no denylist configured (manager.* fields are template defaults)"
    } else {
        Write-Host "  (denylist: $($LeakDenylist -join ', '))" -ForegroundColor DarkGray
        $rxParts = $LeakDenylist | ForEach-Object { [regex]::Escape($_) }
        $pattern = '(?i)(' + ($rxParts -join '|') + ')'
        $hits = Get-ChildItem -Path $checkRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.md','.ps1','.json','.txt','.py' -and $_.FullName -notmatch '\\\.git\\' } |
            Select-String -Pattern $pattern -SimpleMatch:$false |
            Select-Object -First 50
        if ($hits) {
            foreach ($h in $hits) { Write-Fail ("leak in {0}:L{1} -> {2}" -f $h.Path.Substring($checkRoot.Length+1), $h.LineNumber, $h.Line.Trim()) }
        } else {
            Write-Pass "no denied tokens found"
        }
    }
} else {
    Write-Section 'snapshot leak-grep'
    Write-Skip 'snapshot mode only (-Root)'
}

# --- Summary --------------------------------------------------------------
Write-Host ""
if ($script:_Failed -eq 0) {
    Write-Host "doctor: OK ($($psFiles.Count) parse-checked, mode=$(if ($snapshotMode) {'snapshot'} else {'live'}))" -ForegroundColor Green
    exit 0
} else {
    Write-Host "doctor: $script:_Failed FAIL(s)" -ForegroundColor Red
    exit 1
}
