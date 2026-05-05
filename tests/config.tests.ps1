# Tests for _shared/config.ps1.
# Phase 5 added this file as the executable runtime test for the config helper.
# Rubber-duck flagged that source-inspection tests were not enough -- these
# actually load fixture configs and exercise root resolution + path expansion.

. (Join-Path $PSScriptRoot '_test-runner.ps1')
. (Join-Path $PSScriptRoot '..\.copilot\skills\_shared\config.ps1')

# Helper: build an isolated fake agent root with a known config/agent.json.
function New-FakeAgentRoot {
    param([hashtable] $Config)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-cfg-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $root 'config\agent.json'), $json, [System.Text.UTF8Encoding]::new($false))
    return $root
}

Describe 'Resolve-AgentRoot - walk-up discovery' {

    It 'finds the agent root by walking up from a nested start path' {
        $root = New-FakeAgentRoot -Config @{ agent = @{ name = 'X' } }
        try {
            Clear-AgentConfigCache
            $deep = Join-Path $root 'a\b\c\d'
            New-Item -ItemType Directory -Path $deep -Force | Out-Null
            Remove-Item Env:AGENT_ROOT,Env:NIRVANA_ROOT -ErrorAction SilentlyContinue
            $resolved = Resolve-AgentRoot -StartPath $deep
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) ([System.IO.Path]::GetFullPath($resolved))
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when no config\agent.json is found' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-cfg-empty-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Remove-Item Env:AGENT_ROOT,Env:NIRVANA_ROOT -ErrorAction SilentlyContinue
            $threw = $false
            try { Resolve-AgentRoot -StartPath $tmp | Out-Null }
            catch { $threw = $true; Assert-Match 'config\\agent\.json' $_.Exception.Message }
            Assert-True $threw -Because 'Resolve-AgentRoot must throw when no config exists'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Resolve-AgentRoot - env-var override' {

    It 'AGENT_ROOT env var takes precedence over walk-up' {
        $rootA = New-FakeAgentRoot -Config @{ agent = @{ name = 'A' } }
        $rootB = New-FakeAgentRoot -Config @{ agent = @{ name = 'B' } }
        try {
            Clear-AgentConfigCache
            $env:AGENT_ROOT = $rootB
            try {
                # Even when started from rootA, env var should pick rootB.
                $resolved = Resolve-AgentRoot -StartPath $rootA
                Assert-Equal ([System.IO.Path]::GetFullPath($rootB)) ([System.IO.Path]::GetFullPath($resolved))
            } finally {
                Remove-Item Env:AGENT_ROOT -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item $rootA,$rootB -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'NIRVANA_ROOT works as a backward-compat alias' {
        $root = New-FakeAgentRoot -Config @{ agent = @{ name = 'X' } }
        try {
            Clear-AgentConfigCache
            Remove-Item Env:AGENT_ROOT -ErrorAction SilentlyContinue
            $env:NIRVANA_ROOT = $root
            try {
                $resolved = Resolve-AgentRoot
                Assert-Equal ([System.IO.Path]::GetFullPath($root)) ([System.IO.Path]::GetFullPath($resolved))
            } finally {
                Remove-Item Env:NIRVANA_ROOT -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws when AGENT_ROOT points at a non-config dir' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-bad-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $env:AGENT_ROOT = $root
            try {
                Clear-AgentConfigCache
                $threw = $false
                try { Resolve-AgentRoot | Out-Null }
                catch { $threw = $true; Assert-Match 'AGENT_ROOT' $_.Exception.Message }
                Assert-True $threw -Because 'must throw when env var points at non-config dir'
            } finally {
                Remove-Item Env:AGENT_ROOT -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-AgentConfig - parsing + metadata' {

    It 'parses JSON and stamps _root + _config_path metadata' {
        $root = New-FakeAgentRoot -Config @{ agent = @{ name = 'TestBot' }; manager = @{ first_name = 'Casey' } }
        try {
            Clear-AgentConfigCache
            $cfg = Get-AgentConfig -ConfigPath (Join-Path $root 'config\agent.json')
            Assert-Equal 'TestBot' $cfg.agent.name
            Assert-Equal 'Casey'   $cfg.manager.first_name
            Assert-Equal ([System.IO.Path]::GetFullPath($root)) ([System.IO.Path]::GetFullPath($cfg._root))
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'caches across calls but -NoCache forces a re-read' {
        $root = New-FakeAgentRoot -Config @{ agent = @{ name = 'V1' } }
        try {
            Clear-AgentConfigCache
            $cfg1 = Get-AgentConfig -ConfigPath (Join-Path $root 'config\agent.json')
            Assert-Equal 'V1' $cfg1.agent.name

            # Mutate the file -- the cached value should be stale.
            $newJson = (@{ agent = @{ name = 'V2' } } | ConvertTo-Json -Depth 10)
            [System.IO.File]::WriteAllText((Join-Path $root 'config\agent.json'), $newJson, [System.Text.UTF8Encoding]::new($false))

            $cfgCached = Get-AgentConfig -ConfigPath (Join-Path $root 'config\agent.json')
            Assert-Equal 'V1' $cfgCached.agent.name -Because 'cache should return stale value without -NoCache'

            $cfgFresh = Get-AgentConfig -ConfigPath (Join-Path $root 'config\agent.json') -NoCache
            Assert-Equal 'V2' $cfgFresh.agent.name -Because '-NoCache should re-parse from disk'
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws a clear error when the config file is missing' {
        Clear-AgentConfigCache
        $threw = $false
        try { Get-AgentConfig -ConfigPath 'C:\does\not\exist\agent.json' | Out-Null }
        catch { $threw = $true; Assert-Match 'not found' $_.Exception.Message }
        Assert-True $threw
    }

    It 'throws a clear error on malformed JSON' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-bad-json-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'config\agent.json'), '{ this is not json', [System.Text.UTF8Encoding]::new($false))
        try {
            Clear-AgentConfigCache
            $threw = $false
            try { Get-AgentConfig -ConfigPath (Join-Path $root 'config\agent.json') | Out-Null }
            catch { $threw = $true; Assert-Match 'parse' $_.Exception.Message }
            Assert-True $threw
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-AgentField - dot-path navigation' {

    $cfg = [PSCustomObject]@{
        manager = [PSCustomObject]@{ first_name = 'Casey'; email = 'casey@example.com' }
        nested  = [PSCustomObject]@{ a = [PSCustomObject]@{ b = [PSCustomObject]@{ c = 'deep' } } }
    }

    It 'returns a top-level field' {
        Assert-Equal 'casey@example.com' (Get-AgentField -Path 'manager.email' -Config $cfg)
    }

    It 'returns a deeply nested field' {
        Assert-Equal 'deep' (Get-AgentField -Path 'nested.a.b.c' -Config $cfg)
    }

    It 'returns the default when the path is missing' {
        Assert-Equal 'fallback' (Get-AgentField -Path 'no.such.path' -Config $cfg -Default 'fallback')
    }

    It 'returns the default when the leaf is null' {
        $cfg2 = [PSCustomObject]@{ x = $null }
        Assert-Equal 'd' (Get-AgentField -Path 'x' -Config $cfg2 -Default 'd')
    }
}

Describe 'Resolve-AgentPath - env-var expansion + relative-to-root' {

    $root = New-FakeAgentRoot -Config @{ agent = @{ name = 'X' } }
    Clear-AgentConfigCache
    $cfg = Get-AgentConfig -ConfigPath (Join-Path $root 'config\agent.json')

    It 'expands %USERPROFILE% style env vars' {
        $resolved = Resolve-AgentPath -Path '%USERPROFILE%/foo' -Config $cfg
        $expected = Join-Path $env:USERPROFILE 'foo'
        Assert-Equal ([System.IO.Path]::GetFullPath($expected)) ([System.IO.Path]::GetFullPath($resolved))
    }

    It 'returns absolute paths unchanged (after expansion + normalization)' {
        $resolved = Resolve-AgentPath -Path 'C:\Windows\System32' -Config $cfg
        Assert-Equal 'C:\Windows\System32' $resolved
    }

    It 'resolves relative paths against the agent root' {
        $resolved = Resolve-AgentPath -Path 'reports' -Config $cfg
        $expected = [System.IO.Path]::GetFullPath((Join-Path $root 'reports'))
        Assert-Equal $expected $resolved
    }

    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Exit-WithTestResults