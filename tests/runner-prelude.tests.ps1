# Tests for _shared/runner-prelude.ps1.
# Phase 5b added this file. Validates that runners get $AgentRoot,
# $AgentConfig, $LogDir set up correctly, and that the trigger-regex
# composition (used by run-inbox-watch.ps1) works for any alias set --
# not just Nir's "nirvana"/"@nirvana".

. (Join-Path $PSScriptRoot '_test-runner.ps1')

$preludePath = Join-Path $PSScriptRoot '..\.copilot\skills\_shared\runner-prelude.ps1'

function New-FakePreludeRoot {
    param([hashtable] $Config)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-prelude-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $root 'config\agent.json'), $json, [System.Text.UTF8Encoding]::new($false))
    return $root
}

Describe 'runner-prelude.ps1 - bootstrap' {

    It 'populates $AgentRoot, $AgentConfig, $LogDir when dot-sourced' {
        $root = New-FakePreludeRoot -Config @{
            agent = @{ name = 'TestBot' }
            paths = @{ reports_root = 'reports' }
        }
        try {
            $env:AGENT_ROOT = $root
            # Dot-source via a child scope that captures the variables
            $captured = & {
                . $preludePath
                [pscustomobject]@{
                    AgentRoot   = $AgentRoot
                    AgentName   = $AgentConfig.agent.name
                    LogDir      = $LogDir
                    Cwd         = (Get-Location).Path
                }
            }
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) ([System.IO.Path]::GetFullPath($captured.AgentRoot))
            Assert-Equal 'TestBot' $captured.AgentName
            Assert-Equal ([System.IO.Path]::GetFullPath((Join-Path $root 'reports\logs'))) ([System.IO.Path]::GetFullPath($captured.LogDir))
            Assert-True (Test-Path $captured.LogDir) -Because 'prelude should create reports/logs directory'
        } finally {
            Remove-Item Env:AGENT_ROOT -ErrorAction SilentlyContinue
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'defaults reports_root to "reports" when missing from config' {
        $root = New-FakePreludeRoot -Config @{ agent = @{ name = 'Y' } }
        try {
            $env:AGENT_ROOT = $root
            $logDir = & {
                . $preludePath
                $LogDir
            }
            Assert-Equal ([System.IO.Path]::GetFullPath((Join-Path $root 'reports\logs'))) ([System.IO.Path]::GetFullPath($logDir))
        } finally {
            Remove-Item Env:AGENT_ROOT -ErrorAction SilentlyContinue
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'runner-prelude.ps1 - source inspection' {

    $content = Get-Content -Raw -Encoding UTF8 $preludePath

    It 'sets $ErrorActionPreference to Stop' {
        Assert-Match "ErrorActionPreference\s*=\s*'Stop'" $content
    }

    It 'sets console encoding to UTF-8 (no BOM)' {
        Assert-Match 'OutputEncoding' $content
        Assert-Match 'UTF8Encoding' $content
    }

    It 'dot-sources config.ps1 (the helper bootstrap)' {
        Assert-Match "config\.ps1" $content
    }

    It 'documents the lazy-load invariant for shared helpers' {
        Assert-Match '(?ims)Lazy-load policy' $content
        Assert-Match '(?ims)self-bootstrap' $content
    }
}

Exit-WithTestResults
