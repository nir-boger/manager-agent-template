# Context-oriented welcome-back Teams message helpers for team-vacation-watch.
# Teams posts are unsigned and joke-free by convention.

# Map a vacation length (in Israel WORKING days, Sun-Thu) to a short qualitative phrase.
# We deliberately never print raw dates / day counts in the welcome-back post (Nir's ask):
# just a warm "short break" / "long stretch off" flavor. Falls back to $null when unknown.
# Pure: no I/O.
function Get-VacationLengthPhrase {
    [CmdletBinding()]
    param([AllowNull()][object] $WorkDays)

    if ($null -eq $WorkDays) { return $null }
    $n = 0
    if (-not [int]::TryParse(([string]$WorkDays).Trim(), [ref]$n)) { return $null }
    if ($n -le 0) { return $null }

    if ($n -le 1)      { return 'quick day off' }
    elseif ($n -le 2)  { return 'short break' }
    elseif ($n -le 4)  { return 'few days off' }
    elseif ($n -le 7)  { return 'week off' }
    elseif ($n -le 10) { return 'long break' }
    else               { return 'long stretch off' }
}

# Read the team's display names (persona H1 "# <Display Name> (<alias>)") from the people
# dir, excluding nirvana. Used to scope the "what you missed" PR brief to the team.
function Get-TeamDisplayNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $PeopleDir)

    $names = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $PeopleDir)) { return @() }
    try {
        $files = Get-ChildItem -Path $PeopleDir -Filter '*.md' -ErrorAction Stop | Where-Object { $_.BaseName -ne 'nirvana' }
    } catch { return @() }
    foreach ($f in $files) {
        try {
            $head = Get-Content $f.FullName -TotalCount 1 -Encoding UTF8
            $h1 = [regex]::Match("$head", '^#\s+(.+?)\s*\((.+?)\)\s*$')
            if ($h1.Success) {
                $disp = $h1.Groups[1].Value.Trim()
                if ($disp) { $names.Add($disp) | Out-Null }
            }
        } catch { }
    }
    return @($names)
}

function Build-WelcomeBackMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FirstName,
        [string] $VacStart,
        [string] $VacEnd,
        [object] $VacDays,
        [object] $WorkDays,
        [string[]] $Highlights = @(),
        [string] $ReturnDate
    )

    $escape = {
        param([AllowNull()][object] $Value)
        if ($null -eq $Value) { return '' }
        return ([string]$Value).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    }

    $nameHtml = & $escape $FirstName

    # Prefer the working-day length; fall back to calendar days if that's all we have.
    $phrase = Get-VacationLengthPhrase -WorkDays $WorkDays
    if (-not $phrase) { $phrase = Get-VacationLengthPhrase -WorkDays $VacDays }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;">')
    $lines.Add("  <p>&#128075; Welcome back, <b>$nameHtml</b>!</p>")

    if ($phrase) {
        $lines.Add("  <p>Hope that $phrase was just what you needed &mdash; we missed you.</p>")
    } else {
        $lines.Add('  <p>Hope you had a great one &mdash; we missed you.</p>')
    }

    $cleanHighlights = @($Highlights | Where-Object { $null -ne $_ -and ([string]$_).Trim().Length -gt 0 } | Select-Object -First 4)
    if ($cleanHighlights.Count -gt 0) {
        $lines.Add('  <p>A quick brief on what moved in the team&rsquo;s PRs while you were out:</p>')
        $lines.Add('  <ul>')
        foreach ($item in $cleanHighlights) {
            $lines.Add("    <li>$(& $escape (([string]$item).Trim()))</li>")
        }
        $lines.Add('  </ul>')
        $lines.Add('  <p>Ease back in, and ping the team if you want more context.</p>')
    } else {
        $lines.Add('  <p>Ease back in, and ping the team if you want a quick catch-up on what shipped while you were out.</p>')
    }

    $lines.Add('</div>')
    return ($lines -join "`r`n")
}

function Get-AbsenceHighlights {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FirstName,
        [string] $VacStart,
        [string] $ReturnDate,
        [string[]] $TeamMembers = @(),
        [int] $Max = 4
    )

    # This runs only at actual post time (rare), never in the deterministic scan path.
    # Any slow or failed context lookup falls back to no highlights, so posting can proceed.
    try {
        if ($Max -lt 1) { return @() }
        if (-not $VacStart -or -not $ReturnDate) { return @() }

        $roster = @($TeamMembers | Where-Object { $null -ne $_ -and ([string]$_).Trim().Length -gt 0 } | ForEach-Object { ([string]$_).Trim() })
        $rosterLine = if ($roster.Count -gt 0) { ($roster -join ', ') } else { "Your Name's direct reports" }

        $prompt = @"
You are drafting ONLY the "what you missed" brief for a Teams welcome-back post for the Your Team.

STRICT SOURCE RULE (do not violate): use ONLY Azure DevOps pull requests. NEVER use email,
Teams/chat messages, calendar, or any other source. If you cannot get pull-request data, return nothing.

Task: using the Azure DevOps tools, find the most notable pull requests in repo
"Azure-Kusto-Service" (org "your-ado-org", project "One") that were COMPLETED/merged during the
half-open window [$VacStart, $ReturnDate) -- i.e. while $FirstName was on vacation -- and that
were authored by a member of the Your Team.
Team members to treat as "the team" (authors): $rosterLine.

Output rules:
- Return at most $Max lines, one short plain-text bullet per pull request.
- No numbering, no markdown, no links, ASCII only, each line <= 140 chars.
- Format each line as: <concise PR title> (<author first name>).
- Prefer broadly relevant / larger PRs over trivial ones.
- If you cannot confirm completed team pull requests in that window from Azure DevOps, return nothing at all.
"@

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'copilot'
        $psi.Arguments = '--allow-all-tools --no-ask-user'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $process) { return @() }
        $process.StandardInput.WriteLine($prompt)
        $process.StandardInput.Close()

        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill() } catch { }
            return @()
        }
        if ($process.ExitCode -ne 0) { return @() }

        $output = $process.StandardOutput.ReadToEnd()
        if (-not $output) { return @() }

        $items = @()
        foreach ($line in ($output -split "`r?`n")) {
            $text = ([string]$line).Trim()
            $text = $text -replace '^[\-*\d\.\)\s]+', ''
            $text = $text -replace '[^\x09\x0A\x0D\x20-\x7E]', ''
            if ($text -and $text.Length -le 180) { $items += $text }
            if ($items.Count -ge $Max) { break }
        }
        return @($items | Select-Object -First $Max)
    } catch {
        return @()
    }
}

