<#
.SYNOPSIS
    Runs both test suites.

.DESCRIPTION
    Runs the test harnesses for both orchestrator functions:
        - Invoke-AccountInactivityRemediationWithImport
        - Invoke-AccountInactivityRemediation

    Run this from the repo root.

.EXAMPLE
    .\run-tests.ps1
#>

$ErrorActionPreference = 'Stop'

$suites = @(
    'IdentityLifecycle\tests\Invoke-AccountInactivityRemediationWithImport\Invoke-Test.ps1'
    'IdentityLifecycle\tests\Invoke-AccountInactivityRemediation\Invoke-Test.ps1'
)

foreach ($suite in $suites) {
    $path = Join-Path $PSScriptRoot $suite
    if (-not (Test-Path $path)) {
        Write-Error "Test harness not found at: $path"
        exit 1
    }
    . $path
}
