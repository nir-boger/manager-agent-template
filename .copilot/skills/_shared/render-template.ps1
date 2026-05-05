<#
.SYNOPSIS
  Tiny Mustache-lite renderer for the manager-agent template.

.DESCRIPTION
  Supported syntax (intentionally minimal -- rubber-duck flagged generic {{#each}}
  as a maintenance trap; we render lists in dedicated PowerShell code instead):

      {{ field.dotted.path }}        -- scalar substitution from the data context
      {{# if field.dotted.path }}    -- conditional block (truthy -> include)
        ...content...
      {{/ if }}

  Whitespace tolerance: {{x}}, {{ x }}, {{  x.y  }} all work.
  Strict mode (default): unresolved {{ x }} throws. Pass -Lenient to leave the
  literal in place (useful when you want to compose templates in stages).

.PARAMETER Template
  The template string. Newlines preserved as-is.

.PARAMETER Context
  A hashtable / PSCustomObject with the data. Dotted paths walk into nested
  hashtables, dictionaries, or PSCustomObject properties. Missing keys are
  treated as $null (-> falsy for {{# if }}, error for {{ x }} in strict mode).

.PARAMETER Lenient
  When set, unresolved {{ x }} substitutions are left in place instead of throwing.

.OUTPUTS
  [string] The rendered result.
#>

function Get-TemplateField {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Path
    )
    $segments = $Path -split '\.'
    $cur = $Context
    foreach ($seg in $segments) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [hashtable]) {
            if ($cur.ContainsKey($seg)) { $cur = $cur[$seg] } else { return $null }
            continue
        }
        if ($cur -is [System.Collections.IDictionary]) {
            if ($cur.Contains($seg)) { $cur = $cur[$seg] } else { return $null }
            continue
        }
        # PSCustomObject / objects with properties
        $prop = $cur.PSObject.Properties[$seg]
        if ($null -ne $prop) {
            $cur = $prop.Value
        } else {
            return $null
        }
    }
    return $cur
}

function Test-TemplateTruthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return -not [string]::IsNullOrEmpty($Value) }
    if ($Value -is [System.Collections.ICollection]) { return $Value.Count -gt 0 }
    return $true
}

function Render-Template {
    param(
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] $Context,
        [switch] $Lenient
    )

    # Pass 1: resolve {{# if path }}...{{/ if }} blocks. We support nesting by
    # repeated application (no more conditional tokens after enough passes).
    $ifPattern = '(?s)\{\{#\s*if\s+([^\}]+?)\s*\}\}(.*?)\{\{/\s*if\s*\}\}'
    $maxPasses = 16
    for ($pass = 0; $pass -lt $maxPasses; $pass++) {
        if ($Template -notmatch $ifPattern) { break }
        $Template = [regex]::Replace($Template, $ifPattern, {
            param($m)
            $path = $m.Groups[1].Value.Trim()
            $body = $m.Groups[2].Value
            $val = Get-TemplateField -Context $Context -Path $path
            if (Test-TemplateTruthy $val) { return $body } else { return '' }
        })
    }

    # Pass 2: scalar substitution.
    $scalarPattern = '\{\{\s*([a-zA-Z0-9_\.]+)\s*\}\}'
    $strict = -not $Lenient.IsPresent
    $Template = [regex]::Replace($Template, $scalarPattern, {
        param($m)
        $path = $m.Groups[1].Value
        $val = Get-TemplateField -Context $Context -Path $path
        if ($null -eq $val) {
            if ($strict) { throw "Render-Template: unresolved field '{{ $path }}' (use -Lenient to leave in place)." }
            return $m.Value
        }
        return [string]$val
    })

    return $Template
}
