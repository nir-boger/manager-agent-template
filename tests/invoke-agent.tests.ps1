# Tests for _shared/invoke-agent.ps1 (P1 refactor).
# Validates the pure argument-builder and the source-level guarantees that
# protect against the two recurring runner bugs:
#   1. prompt MUST go over stdin (never `-p`) -- wscript large-prompt quoting bug
#   2. EAP flipped to Continue around the invocation -- NativeCommandError unwind

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$invokePath = Join-Path $PSScriptRoot '..\.copilot\skills\_shared\invoke-agent.ps1'
. $invokePath

Describe 'invoke-agent.ps1 - Get-CopilotAgentArgs' {

    It 'always includes --allow-all-tools and --no-ask-user' {
        $a = Get-CopilotAgentArgs
        Assert-True ($a -contains '--allow-all-tools')
        Assert-True ($a -contains '--no-ask-user')
    }

    It 'never emits -p (prompt goes over stdin)' {
        $a = Get-CopilotAgentArgs -Model 'claude-opus-4.8'
        Assert-True (-not ($a -contains '-p'))
    }

    It 'defaults the model to claude-sonnet-4.5' {
        $a = Get-CopilotAgentArgs
        $i = [array]::IndexOf($a, '--model')
        Assert-True ($i -ge 0)
        Assert-Equal 'claude-sonnet-4.5' $a[$i + 1]
    }

    It 'honors an explicit model' {
        $a = Get-CopilotAgentArgs -Model 'claude-opus-4.8'
        $i = [array]::IndexOf($a, '--model')
        Assert-Equal 'claude-opus-4.8' $a[$i + 1]
    }

    It 'omits --model when model is blank' {
        $a = Get-CopilotAgentArgs -Model ''
        Assert-True (-not ($a -contains '--model'))
    }

    It 'adds --allow-all-paths only when requested' {
        $without = Get-CopilotAgentArgs
        Assert-True (-not ($without -contains '--allow-all-paths'))
        $with = Get-CopilotAgentArgs -AllowAllPaths
        Assert-True ($with -contains '--allow-all-paths')
    }

    It 'emits one --add-dir pair per directory, skipping blanks' {
        $a = Get-CopilotAgentArgs -AddDir @('C:\one', '', 'C:\two')
        $count = ($a | Where-Object { $_ -eq '--add-dir' }).Count
        Assert-Equal 2 $count
        Assert-True ($a -contains 'C:\one')
        Assert-True ($a -contains 'C:\two')
    }

    It 'appends ExtraArgs verbatim, skipping blanks' {
        $a = Get-CopilotAgentArgs -ExtraArgs @('--foo', '', '--bar')
        Assert-True ($a -contains '--foo')
        Assert-True ($a -contains '--bar')
    }

    It 'returns a string array' {
        $a = Get-CopilotAgentArgs
        Assert-True ($a -is [array])
    }
}

Describe 'invoke-agent.ps1 - Invoke-CopilotAgent dry run' {

    It 'does not spawn copilot in -DryRun and reports Ran=$false' {
        $r = Invoke-CopilotAgent -Prompt 'hello' -DryRun
        Assert-Equal $false $r.Ran
        Assert-Equal 0 $r.ExitCode
        Assert-True ($r.Args -contains '--allow-all-tools')
    }
}

Describe 'invoke-agent.ps1 - source inspection' {

    $content = Get-Content -Raw -Encoding UTF8 $invokePath

    It 'feeds the prompt over stdin via a temp UTF-8 file' {
        Assert-Match 'New-TemporaryFile' $content
        Assert-Match 'WriteAllText' $content
        Assert-Match 'UTF8Encoding' $content
        Assert-Match 'Get-Content[^\r\n]*-Raw[^\r\n]*\| *\r?\n? *& copilot' $content
    }

    It 'invokes copilot with a splatted arg array (not -p)' {
        Assert-Match '& copilot @resolvedArgs' $content
    }

    It 'flips ErrorActionPreference to Continue around the invocation' {
        Assert-Match "ErrorActionPreference = 'Continue'" $content
        Assert-Match '\$prevEAP' $content
    }

    It 'cleans up the temp prompt file in a finally block' {
        Assert-Match '(?ims)finally\s*\{' $content
        Assert-Match 'Remove-Item' $content
    }

    It 'is self-contained (does not dot-source runner-prelude)' {
        Assert-True (-not ($content -match '\.\s*\(Join-Path[^\r\n)]*runner-prelude'))
    }
}

Exit-WithTestResults
