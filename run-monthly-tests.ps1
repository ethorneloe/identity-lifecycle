<#
.SYNOPSIS
    Entry point for the monthly sweep test harness.

.DESCRIPTION
    Wrapper that delegates to the harness script inside
    IdentityLifecycle/tests-monthly/Invoke-MonthlyTest.ps1.
    Run this from the repo root.

.EXAMPLE
    .\run-monthly-tests.ps1
#>

$ErrorActionPreference = 'Stop'

$harnessPath = Join-Path $PSScriptRoot 'IdentityLifecycle\tests-monthly\Invoke-MonthlyTest.ps1'

if (-not (Test-Path $harnessPath)) {
    Write-Error "Monthly test harness not found at: $harnessPath"
    exit 1
}

. $harnessPath
