# Single source of truth for reading runtime config.
#
# Usage (dot-source from any helper or runner):
#   . (Join-Path $PSScriptRoot 'config.ps1')              # if in _shared/
#   $cfg   = Get-AgentConfig
#   $first = Get-AgentField -Path 'manager.first_name'
#   $first = Get-AgentField -Path 'manager.first_name' -Default 'Manager'
#   $abs   = Resolve-AgentPath -Path '%USERPROFILE%/.copilot/connect-buddy'
#
# Root resolution
#   1. If $env:AGENT_ROOT is set and points at a directory containing
#      config\agent.json, that directory is the agent root.
#      (Backward-compat alias: $env:NIRVANA_ROOT.)
#   2. Otherwise, walk up from $PSScriptRoot looking for config\agent.json.
#      Up to 8 levels. First match wins.
#   3. If still not found, throw a clear error pointing the manager at
#      init.ps1.
#
# Path semantics
#   - paths.* in agent.json that are relative are resolved against the
#     agent root (the directory that contains config\agent.json).
#   - %ENV% references are expanded via [Environment]::ExpandEnvironmentVariables.
#   - Absolute paths are returned as-is.
#
# Cache
#   $script:_AgentConfigCache caches the parsed JSON per-process keyed by
#   resolved config path. Use -NoCache or Clear-AgentConfigCache to bust.

$script:_AgentConfigCache = @{}

function Resolve-AgentRoot {
    [CmdletBinding()]
    param(
        # Optional starting directory for the walk-up. Defaults to
        # $PSScriptRoot of the calling script, falling back to current dir.
        [string] $StartPath
    )

    # Env var wins.
    foreach ($var in 'AGENT_ROOT','NIRVANA_ROOT') {
        $val = [System.Environment]::GetEnvironmentVariable($var)
        if ($val) {
            $candidate = [System.Environment]::ExpandEnvironmentVariables($val)
            if (Test-Path (Join-Path $candidate 'config\agent.json')) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
            throw "`$env:$var points at '$candidate' but config\agent.json was not found there. Fix the env var or unset it to fall back to walk-up discovery."
        }
    }

    if (-not $StartPath) {
        if ($PSScriptRoot) { $StartPath = $PSScriptRoot }
        else               { $StartPath = (Get-Location).Path }
    }
    if (-not (Test-Path $StartPath)) {
        throw "Resolve-AgentRoot: start path '$StartPath' does not exist."
    }

    $cur = (Get-Item $StartPath).FullName
    for ($i = 0; $i -lt 8; $i++) {
        $candidate = Join-Path $cur 'config\agent.json'
        if (Test-Path $candidate) { return $cur }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }

    throw "Could not find config\agent.json by walking up from '$StartPath'. Set `$env:AGENT_ROOT or run init.ps1."
}

function Get-AgentConfig {
    [CmdletBinding()]
    param(
        # Explicit config path. When omitted, resolved via Resolve-AgentRoot.
        [string] $ConfigPath,

        # Bypass the per-process cache.
        [switch] $NoCache
    )

    if (-not $ConfigPath) {
        $root = Resolve-AgentRoot
        $ConfigPath = Join-Path $root 'config\agent.json'
    }

    $key = ([System.IO.Path]::GetFullPath($ConfigPath)).ToLowerInvariant()

    if (-not $NoCache -and $script:_AgentConfigCache.ContainsKey($key)) {
        return $script:_AgentConfigCache[$key]
    }

    if (-not (Test-Path $ConfigPath)) {
        throw "Agent config not found at: $ConfigPath. Run init.ps1 to bootstrap."
    }

    $json = Get-Content $ConfigPath -Raw -Encoding UTF8
    try {
        $obj = $json | ConvertFrom-Json
    } catch {
        throw "Failed to parse agent config '$ConfigPath': $($_.Exception.Message)"
    }

    # Stash resolved root + config path on the parsed object so downstream
    # consumers (e.g. Resolve-AgentPath) don't have to re-walk.
    $resolvedRoot = (Split-Path -Parent (Split-Path -Parent $ConfigPath))
    $obj | Add-Member -NotePropertyName '_root'        -NotePropertyValue $resolvedRoot -Force
    $obj | Add-Member -NotePropertyName '_config_path' -NotePropertyValue ([System.IO.Path]::GetFullPath($ConfigPath)) -Force

    $script:_AgentConfigCache[$key] = $obj
    return $obj
}

function Get-AgentField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [object] $Default = $null,
        [object] $Config
    )
    if ($null -eq $Config) { $Config = Get-AgentConfig }
    $cur = $Config
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) {
            if ($cur.Contains($part)) { $cur = $cur[$part] } else { return $Default }
        } elseif ($cur.PSObject -and $cur.PSObject.Properties[$part]) {
            $cur = $cur.PSObject.Properties[$part].Value
        } else {
            return $Default
        }
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function Resolve-AgentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [string] $Path,
        [object] $Config
    )
    process {
        if ($null -eq $Config) { $Config = Get-AgentConfig }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
        if ([System.IO.Path]::IsPathRooted($expanded)) {
            return [System.IO.Path]::GetFullPath($expanded)
        }
        $root = $Config._root
        if (-not $root) { throw "Resolve-AgentPath: config has no _root metadata; load via Get-AgentConfig." }
        return [System.IO.Path]::GetFullPath((Join-Path $root $expanded))
    }
}

function Clear-AgentConfigCache {
    [CmdletBinding()]
    param()
    $script:_AgentConfigCache = @{}
}
