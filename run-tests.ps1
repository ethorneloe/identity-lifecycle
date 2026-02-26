<#
.SYNOPSIS
    Runs the test suite.

.DESCRIPTION
    Runs the test harness for Invoke-InactiveAccountRemediation (merged orchestrator).

    Run this from the repo root.

.EXAMPLE
    .\run-tests.ps1
#>

$ErrorActionPreference = 'Stop'

$suites = @(
    'IdentityLifecycle\tests\Invoke-InactiveAccountRemediation\Invoke-Test.ps1'
)

foreach ($suite in $suites) {
    $path = Join-Path $PSScriptRoot $suite
    if (-not (Test-Path $path)) {
        Write-Error "Test harness not found at: $path"
        exit 1
    }
    . $path
}
