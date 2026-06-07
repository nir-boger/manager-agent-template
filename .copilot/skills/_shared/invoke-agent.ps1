# Single source of truth for invoking the copilot CLI agent from a runner.
#
# WHY THIS EXISTS
#   Every run-*.ps1 used to hand-roll its own `& copilot -p $prompt ...` call.
#   That copy-paste caused two classes of bug to recur across runners (see
#   repository memories, 2026-05-18/19):
#     1. `& copilot -p $largePrompt` mis-quotes prompts that contain quotes,
#        parens, and newlines when launched via wscript -> run-hidden.vbs
#        -> powershell -File  ("too many arguments. Expected 0 ... got N").
#        FIX: pass the prompt over STDIN from a temp UTF-8 (no BOM) file.
#     2. ErrorActionPreference='Stop' bubbling a NativeCommandError when
#        copilot writes to stderr, unwinding scope mid-iteration.
#        FIX: flip EAP to 'Continue' around the invocation, restore after.
#
#   This helper centralizes both fixes so a runner just calls
#   Invoke-CopilotAgent and never re-derives the recipe.
#
# USAGE (from a runner):
#   . (Join-Path $PSScriptRoot '_shared\invoke-agent.ps1')      # if runner is in skills/
#   $r = Invoke-CopilotAgent -Prompt $prompt -LogFile $logFile  # default model
#   if ($r.ExitCode -ne 0) { Write-Log "WARN: copilot exited $($r.ExitCode)" }
#
# DESIGN NOTES
#   - Self-contained: does NOT depend on runner-prelude.ps1 or $AgentConfig.
#   - The argument-building is a SEPARATE pure function (Get-CopilotAgentArgs)
#     so tests can assert the command line without spawning copilot.
#   - The prompt is ALWAYS passed via stdin; `-p` is never used.

$script:DefaultCopilotModel = 'claude-sonnet-4.5'

function Get-CopilotAgentArgs {
    <#
    .SYNOPSIS
      Build the copilot CLI argument array (pure; no side effects, no spawn).
    .DESCRIPTION
      Returns the args that follow the `copilot` executable. The prompt is NOT
      included here -- it is fed over stdin by Invoke-CopilotAgent. `-p` is
      deliberately omitted to dodge the wscript large-prompt quoting bug.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]   $Model        = $script:DefaultCopilotModel,
        [switch]   $AllowAllPaths,
        [string[]] $AddDir        = @(),
        [string[]] $ExtraArgs     = @()
    )

    $argv = [System.Collections.Generic.List[string]]::new()
    $argv.Add('--allow-all-tools')
    $argv.Add('--no-ask-user')

    if ($AllowAllPaths) { $argv.Add('--allow-all-paths') }

    foreach ($d in $AddDir) {
        if (-not [string]::IsNullOrWhiteSpace($d)) {
            $argv.Add('--add-dir')
            $argv.Add($d)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $argv.Add('--model')
        $argv.Add($Model)
    }

    foreach ($e in $ExtraArgs) {
        if (-not [string]::IsNullOrWhiteSpace($e)) { $argv.Add($e) }
    }

    return ,$argv.ToArray()
}

function Invoke-CopilotAgent {
    <#
    .SYNOPSIS
      Run the copilot CLI with $Prompt fed over stdin, teeing output to a log.
    .OUTPUTS
      [pscustomobject] @{ ExitCode; PromptFile; Args; Ran }
        ExitCode   - copilot's $LASTEXITCODE (or -1 if copilot was not found,
                     or 0 with Ran=$false in -DryRun).
        PromptFile - the temp file used (already deleted unless -KeepPromptFile).
        Args       - the resolved argument array (for diagnostics).
        Ran        - $true if copilot was actually spawned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string]   $LogFile,
        [string]   $Model         = $script:DefaultCopilotModel,
        [switch]   $AllowAllPaths,
        [string[]] $AddDir         = @(),
        [string[]] $ExtraArgs      = @(),
        [switch]   $AppendLog,
        [switch]   $DryRun,
        [switch]   $KeepPromptFile
    )

    $resolvedArgs = Get-CopilotAgentArgs -Model $Model -AllowAllPaths:$AllowAllPaths -AddDir $AddDir -ExtraArgs $ExtraArgs

    if ($DryRun) {
        return [pscustomobject]@{ ExitCode = 0; PromptFile = $null; Args = $resolvedArgs; Ran = $false }
    }

    $copilot = Get-Command -Name copilot -ErrorAction SilentlyContinue
    if (-not $copilot) {
        if ($LogFile) { "ERROR: 'copilot' CLI not found in PATH." | Add-Content -Path $LogFile -Encoding UTF8 }
        return [pscustomobject]@{ ExitCode = -1; PromptFile = $null; Args = $resolvedArgs; Ran = $false }
    }

    # Prompt over stdin via a temp UTF-8 (no BOM) file -- dodges the wscript
    # large-prompt quoting bug. See header.
    $promptFile = New-TemporaryFile
    [System.IO.File]::WriteAllText($promptFile.FullName, $Prompt, [System.Text.UTF8Encoding]::new($false))

    $copilotExit = $null
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($LogFile) {
            Get-Content -Path $promptFile.FullName -Raw -Encoding UTF8 |
                & copilot @resolvedArgs *>&1 |
                Tee-Object -FilePath $LogFile -Append:$AppendLog
        } else {
            Get-Content -Path $promptFile.FullName -Raw -Encoding UTF8 |
                & copilot @resolvedArgs *>&1 | Out-Host
        }
        $copilotExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
        if (-not $KeepPromptFile) {
            Remove-Item -Path $promptFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -eq $copilotExit) { $copilotExit = 0 }

    return [pscustomobject]@{
        ExitCode   = $copilotExit
        PromptFile = $promptFile.FullName
        Args       = $resolvedArgs
        Ran        = $true
    }
}
