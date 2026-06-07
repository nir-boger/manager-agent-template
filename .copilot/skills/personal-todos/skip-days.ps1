# Pure helpers for the personal-todos daily-reminder weekday skip gate.
#
# Nir's work week is Sun-Thu, so the daily "what's on my plate" email is
# suppressed on Friday and Saturday by default. The skip list is config-driven
# (config/personal-todos.yaml -> skip_days) and re-read every run. The on-demand
# "send my daily todo email now" path (-Force) always bypasses the gate.
#
# Dot-sourced by run-personal-todos-daily.ps1 and by tests/personal-todos.tests.ps1.
# ASCII-only: PS 5.1 reads .ps1 via the active codepage and mangles non-ASCII
# without a BOM, so keep this file plain ASCII.

function Get-TodosSkipDays {
    <#
    .SYNOPSIS
    Read the `skip_days:` list of weekday names from personal-todos.yaml.

    Returns a string[] of canonical weekday names (e.g. 'Friday', 'Saturday'),
    or @() when the file is missing, the key is absent, or the list is empty.
    Unknown / malformed entries are ignored. Matching is case-insensitive; the
    returned names are normalised to canonical .NET DayOfWeek spelling.

    Mirrors the list-of-scalars handling in build-daily.py::_load_yaml_simple so
    the two readers agree on the same config shape.
    #>
    param([Parameter(Mandatory)][string] $ConfigFile)

    $valid = @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')

    if (-not (Test-Path -LiteralPath $ConfigFile)) { return @() }
    $lines = Get-Content -LiteralPath $ConfigFile -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    $result = New-Object System.Collections.Generic.List[string]
    $inList = $false
    foreach ($raw in $lines) {
        $line     = $raw.TrimEnd()
        $stripped = $line.TrimStart()
        if ($stripped -eq '' -or $stripped.StartsWith('#')) { continue }

        $indented = ($line -match '^[ \t]')
        if (-not $indented) {
            # A new top-level key ends the previous list. Enter the list only on skip_days.
            $inList = ($stripped -match '^skip_days\s*:')
            continue
        }
        if (-not $inList) { continue }
        if (-not $stripped.StartsWith('- ')) { continue }

        $val = $stripped.Substring(2).Trim()
        $val = ($val -split '\s+#', 2)[0].Trim()          # drop trailing inline comment
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)      # strip surrounding quotes
        }
        if ($val -eq '') { continue }

        $canon = $valid | Where-Object { $_ -ieq $val } | Select-Object -First 1
        if ($canon) { [void]$result.Add($canon) }
    }
    return $result.ToArray()
}

function Test-TodosSkipDay {
    <#
    .SYNOPSIS
    True when $Date's weekday is one of $SkipDays (case-insensitive).
    Empty / null $SkipDays => never a skip day.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]] $SkipDays,
        [Parameter(Mandatory)][datetime] $Date
    )
    if (-not $SkipDays -or $SkipDays.Count -eq 0) { return $false }
    $name = $Date.DayOfWeek.ToString()
    foreach ($d in $SkipDays) {
        if ($d -ieq $name) { return $true }
    }
    return $false
}
