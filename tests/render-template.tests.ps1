# Tests for _shared/render-template.ps1.
# Phase 6 added this Mustache-lite renderer.

. (Join-Path $PSScriptRoot '_test-runner.ps1')
. (Join-Path $PSScriptRoot '..\.copilot\skills\_shared\render-template.ps1')

Describe 'Render-Template - scalar substitution' {
    It 'substitutes {{ field }}' {
        $out = Render-Template -Template 'hello {{ name }}!' -Context @{ name = 'world' }
        Assert-Equal 'hello world!' $out
    }

    It 'substitutes nested {{ field.path }}' {
        $out = Render-Template -Template 'hi {{ user.first }}' -Context @{ user = @{ first = 'Nir' } }
        Assert-Equal 'hi Nir' $out
    }

    It 'tolerates whitespace inside braces' {
        $out = Render-Template -Template '{{x}} {{ x }} {{  x  }}' -Context @{ x = 'A' }
        Assert-Equal 'A A A' $out
    }

    It 'walks PSCustomObject properties' {
        $cfg = [pscustomobject]@{ agent = [pscustomobject]@{ name = 'Foo' } }
        $out = Render-Template -Template '{{ agent.name }}' -Context $cfg
        Assert-Equal 'Foo' $out
    }

    It 'throws on unresolved field in strict mode (default)' {
        $threw = $false
        try { Render-Template -Template '{{ missing }}' -Context @{} } catch { $threw = $true }
        Assert-True $threw -Because 'strict mode must throw on unresolved fields'
    }

    It 'leaves unresolved field literal in -Lenient mode' {
        $out = Render-Template -Template '{{ missing }}' -Context @{} -Lenient
        Assert-Equal '{{ missing }}' $out
    }
}

Describe 'Render-Template - {{# if }} blocks' {
    It 'includes block when value is truthy' {
        $out = Render-Template -Template 'A{{# if x }}B{{/ if }}C' -Context @{ x = 'yes' }
        Assert-Equal 'ABC' $out
    }

    It 'excludes block when value is falsy (empty string)' {
        $out = Render-Template -Template 'A{{# if x }}B{{/ if }}C' -Context @{ x = '' }
        Assert-Equal 'AC' $out
    }

    It 'excludes block when field is missing' {
        $out = Render-Template -Template 'A{{# if x }}B{{/ if }}C' -Context @{}
        Assert-Equal 'AC' $out
    }

    It 'excludes block when value is $null' {
        $out = Render-Template -Template 'A{{# if x }}B{{/ if }}C' -Context @{ x = $null }
        Assert-Equal 'AC' $out
    }

    It 'excludes block when value is $false' {
        $out = Render-Template -Template 'A{{# if x }}B{{/ if }}C' -Context @{ x = $false }
        Assert-Equal 'AC' $out
    }

    It 'excludes block when value is empty array' {
        $out = Render-Template -Template 'A{{# if x }}B{{/ if }}C' -Context @{ x = @() }
        Assert-Equal 'AC' $out
    }

    It 'walks dotted path inside if' {
        $out = Render-Template -Template 'A{{# if cfg.flag }}YES{{/ if }}' -Context @{ cfg = @{ flag = $true } }
        Assert-Equal 'AYES' $out
    }

    It 'supports substitution inside an if block' {
        $out = Render-Template -Template '{{# if cfg.x }}got {{ cfg.x }}{{/ if }}' -Context @{ cfg = @{ x = 'A' } }
        Assert-Equal 'got A' $out
    }
}

Describe 'Render-Template - dotted-path resolution' {
    It 'returns $null when intermediate object is missing (strict throws)' {
        $threw = $false
        try { Render-Template -Template '{{ a.b.c }}' -Context @{} } catch { $threw = $true }
        Assert-True $threw
    }

    It 'returns the value at the leaf for hashtables' {
        $out = Render-Template -Template '{{ a.b.c }}' -Context @{ a = @{ b = @{ c = 'leaf' } } }
        Assert-Equal 'leaf' $out
    }
}

Exit-WithTestResults
