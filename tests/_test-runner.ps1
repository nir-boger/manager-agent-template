# Tiny self-contained test framework for Nirvana.
#
# Why not Pester? The Windows-built-in Pester is 3.4.0 (very old; different API
# from 5.x). Requiring a Pester install is friction for a manager forking the
# template. This file gives us a minimal Describe/It/Assert API in ~80 lines,
# zero dependencies, runs on stock Windows PowerShell 5.1+ and PowerShell 7+.
#
# Usage:
#   . (Join-Path $PSScriptRoot '_test-runner.ps1')
#   Describe 'Foo' {
#       It 'does X' {
#           Assert-Equal 'expected' (Foo-X)
#       }
#       It 'matches a pattern' {
#           Assert-Match '\bbar\b' (Foo-Bar)
#       }
#   }
#   Exit-WithTestResults
#
# Or run all tests:
#   .\tests\run-all.ps1

$script:_TestState = @{
    DescribeStack = @()
    Passed        = 0
    Failed        = 0
    Failures      = @()
    StartTime     = Get-Date
}

function Describe {
    param(
        [Parameter(Mandatory)] [string]      $Name,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    $script:_TestState.DescribeStack += $Name
    Write-Host ""
    Write-Host ("  " * ($script:_TestState.DescribeStack.Count - 1)) -NoNewline
    Write-Host $Name -ForegroundColor Cyan
    try {
        & $Body
    } finally {
        if ($script:_TestState.DescribeStack.Count -gt 1) {
            $script:_TestState.DescribeStack = @($script:_TestState.DescribeStack[0..($script:_TestState.DescribeStack.Count - 2)])
        } else {
            $script:_TestState.DescribeStack = @()
        }
    }
}

function It {
    param(
        [Parameter(Mandatory)] [string]      $Name,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    $indent = "  " * ($script:_TestState.DescribeStack.Count + 1)
    try {
        & $Body
        $script:_TestState.Passed++
        Write-Host "$indent[PASS] $Name" -ForegroundColor Green
    } catch {
        $script:_TestState.Failed++
        $fullPath = ($script:_TestState.DescribeStack -join ' > ') + " > $Name"
        $script:_TestState.Failures += [PSCustomObject]@{
            Path  = $fullPath
            Error = $_.Exception.Message
        }
        Write-Host "$indent[FAIL] $Name" -ForegroundColor Red
        Write-Host "$indent       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Because = '')
    if ($Expected -ne $Actual) {
        $msg = "Expected '$Expected' but got '$Actual'."
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Assert-Match {
    param([string] $Pattern, [string] $Actual, [string] $Because = '')
    if ($Actual -notmatch $Pattern) {
        $msg = "Expected text to match /$Pattern/ but got: '$Actual'"
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Assert-NotMatch {
    param([string] $Pattern, [string] $Actual, [string] $Because = '')
    if ($Actual -match $Pattern) {
        $msg = "Expected text NOT to match /$Pattern/ but it did. Got: '$Actual'"
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Assert-Contains {
    param([string] $Substring, [string] $Actual, [string] $Because = '')
    if ($Actual -notlike "*$Substring*") {
        $msg = "Expected text to contain '$Substring' but got: '$Actual'"
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Assert-NotContains {
    param([string] $Substring, [string] $Actual, [string] $Because = '')
    if ($Actual -like "*$Substring*") {
        $msg = "Expected text NOT to contain '$Substring' but it did. Got: '$Actual'"
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Assert-Empty {
    param($Actual, [string] $Because = '')
    if (-not [string]::IsNullOrEmpty($Actual)) {
        $msg = "Expected empty/null but got: '$Actual'"
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Assert-True {
    param($Value, [string] $Because = '')
    if (-not $Value) {
        $msg = "Expected truthy but got: '$Value'"
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Assert-False {
    param($Value, [string] $Because = '')
    if ($Value) {
        $msg = "Expected falsy but got: '$Value'"
        if ($Because) { $msg += " ($Because)" }
        throw $msg
    }
}

function Exit-WithTestResults {
    $elapsed = ((Get-Date) - $script:_TestState.StartTime).TotalSeconds
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    $color = if ($script:_TestState.Failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("Tests: {0} passed, {1} failed in {2:N2}s" -f $script:_TestState.Passed, $script:_TestState.Failed, $elapsed) -ForegroundColor $color
    if ($script:_TestState.Failed -gt 0) {
        Write-Host ""
        Write-Host "Failures:" -ForegroundColor Red
        foreach ($f in $script:_TestState.Failures) {
            Write-Host "  - $($f.Path)" -ForegroundColor Red
            Write-Host "      $($f.Error)" -ForegroundColor Red
        }
        exit 1
    }
    exit 0
}
