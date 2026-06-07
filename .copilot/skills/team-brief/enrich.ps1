#requires -Version 5.1
<#
  enrich.ps1 - best-effort WorkIQ enrichment generator for the team-brief skill.

  Invoked by run-team-brief.ps1 only when -Enrich is passed:
      & enrich.ps1 -Mode <daily|weekly> -Dates <yyyy-MM-dd[]> -RangeLabelPlain <str>
                   -DirectsContext <path-to-directs-context.json>
                   -OutFile <path-to-enrichment.json> -LogFile <path>

  It asks the copilot CLI (which has the WorkIQ MCP) for a short, grounded
  per-person Teams/email/meeting/incident summary, and writes/merges
  enrichment.json: { generated_at, source, people: { <alias>: { daily, weekly } } }.

  Design principles:
   - GRACEFUL. Any per-person failure preserves that person's existing cached
     entry. A total failure leaves the existing enrichment.json untouched.
   - Read-only against WorkIQ (the CLI tool is read-only). This script only
     writes the local enrichment.json cache.
   - Uses the stdin-temp-file copilot invocation pattern (NEVER `& copilot -p`),
     per the "powershell external-arg quoting" convention - large prompts with
     quotes/newlines corrupt under run-hidden.vbs -> scheduled tasks otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('daily','weekly')][string] $Mode,
    [string[]] $Dates = @(),
    [string]   $RangeLabelPlain = '',
    [Parameter(Mandatory)][string] $DirectsContext,
    [Parameter(Mandatory)][string] $OutFile,
    [string]   $LogFile = '',
    [string]   $Model = 'claude-opus-4.7-high'
)

$ErrorActionPreference = 'Stop'

function Write-EnrichLog {
    param([string] $m)
    $line = "{0} [enrich] {1}" -f (Get-Date).ToString('o'), $m
    if ($LogFile) { try { Add-Content -Path $LogFile -Value $line } catch { } }
    Write-Host $line
}

# ---- Load directs ---------------------------------------------------------
if (-not (Test-Path $DirectsContext)) {
    Write-EnrichLog "ERROR: directs-context not found at $DirectsContext - nothing to enrich."
    return
}
$ctx = Get-Content $DirectsContext -Raw | ConvertFrom-Json
$directs = $ctx.directs
$aliases = @($directs.PSObject.Properties.Name)
if ($aliases.Count -eq 0) { Write-EnrichLog 'No directs found - exiting.'; return }

# ---- Load existing cache (to merge / preserve) ----------------------------
$people = @{}
if (Test-Path $OutFile) {
    try {
        $existing = Get-Content $OutFile -Raw | ConvertFrom-Json
        $src = if ($existing.people) { $existing.people } else { $existing }
        foreach ($prop in $src.PSObject.Properties) {
            $people[$prop.Name] = @{
                daily  = [string]$prop.Value.daily
                weekly = [string]$prop.Value.weekly
            }
        }
        Write-EnrichLog "Loaded existing cache for $($people.Keys.Count) people (will merge)."
    } catch { Write-EnrichLog "WARN: could not read existing enrichment.json - $($_.Exception.Message). Starting fresh." }
}

# ---- Prompt builder -------------------------------------------------------
function Build-EnrichPrompt {
    param([string] $Name, [string] $Smtp, [string] $Mode, [string] $RangeLabelPlain)
    $window = if ($Mode -eq 'weekly') {
        "the work week of $RangeLabelPlain (Sunday through Thursday, Israeli work week)"
    } else {
        "the single work day of $RangeLabelPlain"
    }
    $field = if ($Mode -eq 'weekly') { 'weekly' } else { 'daily' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("You are gathering a short, grounded work summary for a manager's team-brief email.")
    [void]$sb.AppendLine("Use the WorkIQ tool (workiq-ask_work_iq) - it is read-only - to find what this engineer did.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Engineer: $Name <$Smtp>, on the Microsoft Your Team (DM) team.")
    [void]$sb.AppendLine("Window: $window.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Ask WorkIQ: in 2-3 sentences, what did this engineer work on and accomplish during $window? Focus on concrete technical work, key Teams/email discussions, incidents handled, and decisions driven. Be specific and concise. If you find little, say so briefly and honestly - do NOT invent activity.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Then reply with ONLY a single strict JSON object on one line, no markdown, no code fences:")
    [void]$sb.AppendLine("{`"$field`": `"<the 2-3 sentence summary, plain text, no citations or links>`"}")
    [void]$sb.AppendLine("If there was no tracked activity, set the value to a short honest note like `"No tracked activity this window.`".")
    return $sb.ToString()
}

# ---- Parse the agent's JSON reply -----------------------------------------
function Format-EnrichFromAgentJson {
    param([string] $RawText, [string] $Mode)
    if ([string]::IsNullOrWhiteSpace($RawText)) { return $null }
    $field = if ($Mode -eq 'weekly') { 'weekly' } else { 'daily' }
    # Pull the last {...} block (the agent may print tool chatter before it).
    $matches = [regex]::Matches($RawText, '\{(?:[^{}]|\{[^{}]*\})*\}')
    for ($i = $matches.Count - 1; $i -ge 0; $i--) {
        $candidate = $matches[$i].Value
        try {
            $obj = $candidate | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains $field) {
                $val = [string]$obj.$field
                if (-not [string]::IsNullOrWhiteSpace($val)) { return $val.Trim() }
            }
        } catch { continue }
    }
    return $null
}

# ---- Per-person enrichment ------------------------------------------------
$copilot = Get-Command copilot -ErrorAction SilentlyContinue
if (-not $copilot) {
    Write-EnrichLog "WARN: copilot CLI not found on PATH - cannot refresh via WorkIQ. Preserving existing cache."
    return
}

$updated = 0; $kept = 0; $failed = 0
foreach ($alias in $aliases) {
    $p = $directs.$alias
    $name = [string]$p.name
    $smtp = [string]$p.smtp
    if (-not $people.ContainsKey($alias)) { $people[$alias] = @{ daily = ''; weekly = '' } }

    $prompt = Build-EnrichPrompt -Name $name -Smtp $smtp -Mode $Mode -RangeLabelPlain $RangeLabelPlain
    $promptFile = New-TemporaryFile
    [System.IO.File]::WriteAllText($promptFile.FullName, $prompt, [System.Text.UTF8Encoding]::new($false))
    try {
        Write-EnrichLog "WorkIQ enrich ($Mode): $name <$smtp> ..."
        $raw = Get-Content -Path $promptFile.FullName -Raw -Encoding UTF8 | & copilot --allow-all-tools --no-ask-user --model $Model 2>&1 | Out-String
        $val = Format-EnrichFromAgentJson -RawText $raw -Mode $Mode
        if ($val) {
            $people[$alias][$Mode] = $val
            $updated++
            Write-EnrichLog "  -> updated $Mode ($($val.Length) chars)."
        } else {
            $kept++
            Write-EnrichLog "  -> no usable JSON; kept existing $Mode."
        }
    } catch {
        $failed++
        Write-EnrichLog "  -> ERROR: $($_.Exception.Message). Kept existing $Mode."
    } finally {
        Remove-Item -Path $promptFile.FullName -ErrorAction SilentlyContinue
    }
}

# ---- Write merged cache atomically ----------------------------------------
$out = [ordered]@{
    generated_at = (Get-Date).ToString('o')
    source       = "WorkIQ (read-only) via enrich.ps1 - $Mode refresh for $RangeLabelPlain."
    people       = [ordered]@{}
}
foreach ($alias in ($people.Keys | Sort-Object)) {
    $out.people[$alias] = [ordered]@{
        daily  = [string]$people[$alias].daily
        weekly = [string]$people[$alias].weekly
    }
}
$json = $out | ConvertTo-Json -Depth 6
$tmp = "$OutFile.tmp"
[System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
Move-Item -Path $tmp -Destination $OutFile -Force
Write-EnrichLog "Wrote enrichment.json: updated=$updated kept=$kept failed=$failed (total $($people.Keys.Count) people)."

