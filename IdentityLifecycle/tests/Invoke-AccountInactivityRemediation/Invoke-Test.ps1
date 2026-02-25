<#
.SYNOPSIS
    Test harness for Invoke-AccountInactivityRemediation.

.DESCRIPTION
    Runs all scenarios defined in the scenarios/ subdirectory against the real Remediation
    orchestrator, with AD/Entra discovery and action dependencies replaced by in-memory
    mocks injected into the module's script scope.

    Architecture:
        - Module is loaded with Import-Module -Global so all exported commands are
          available, and mocks are injected via & (Get-Module IdentityLifecycle) { }.
        - Get-PrefixedADAccounts and Get-PrefixedEntraAccounts are mocked to return
          lists controlled by the scenario (ADAccountList, EntraAccountList keys).
        - Get-ADUser is mocked for owner resolution (Get-ADAccountOwner calls it internally).
        - Send-GraphMail, Disable-InactiveAccount, and Remove-InactiveAccount are mocked.
        - Connect-MgGraph and Disconnect-MgGraph are mocked.
        - Get-ADAccountOwner and New-InactiveAccountLifecycleMessage run for real.
        - No file I/O; all results are in the returned output object.

.EXAMPLE
    From the repo root:
    . .\IdentityLifecycle\tests\Invoke-AccountInactivityRemediation\Invoke-Test.ps1
#>

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# PATH SETUP
# ---------------------------------------------------------------------------

$TestRoot   = $PSScriptRoot
$ModuleRoot = Join-Path $TestRoot '..\..'
$ReportsDir = Join-Path $TestRoot 'reports'

if (-not (Test-Path $ReportsDir)) {
    New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# SCRIPT-SCOPE STATE
# ---------------------------------------------------------------------------

$script:AssertionResults = [System.Collections.Generic.List[pscustomobject]]::new()
$script:CurrentScenario  = ''
$script:CurrentRun       = 1

$script:MockContext = @{
    ADAccountList        = @()
    EntraAccountList     = @()
    ADUsers              = @{}
    MgUserSponsors       = @{}
    Actions              = [System.Collections.Generic.List[pscustomobject]]::new()
    NotifyFail           = @()
    DisableFail          = @()
    RemoveFail           = @()
    ConnectFail          = $false
    ADAccountListFail    = $false
}

# ---------------------------------------------------------------------------
# LOAD MODULE
# ---------------------------------------------------------------------------

Write-Host "Loading module..." -ForegroundColor Cyan
$psdPath = Join-Path $ModuleRoot 'IdentityLifecycle.psd1'
Import-Module $psdPath -Global -Force -WarningAction SilentlyContinue

# ---------------------------------------------------------------------------
# LOAD HELPERS
# ---------------------------------------------------------------------------

. (Join-Path $TestRoot 'helpers\New-TestAccount.ps1')
. (Join-Path $TestRoot 'helpers\Assert-Result.ps1')
. (Join-Path $TestRoot 'helpers\Set-Mocks.ps1')

Set-Mocks -MockContext $script:MockContext

# ---------------------------------------------------------------------------
# RUNNER HELPERS
# ---------------------------------------------------------------------------

function Invoke-RemediationOnce {
    param(
        [bool] $EnableDeletion          = $false,
        [int]  $WarnThreshold           = 90,
        [int]  $DisableThreshold        = 120,
        [int]  $DeleteThreshold         = 180,
        [bool] $UseExistingGraphSession = $true,
        [bool] $WhatIf                  = $false
    )

    $params = @{
        Prefixes         = @('admin', 'priv')
        ADSearchBase     = 'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au'
        Sender           = 'iam-automation@corp.local'
        WarnThreshold    = $WarnThreshold
        DisableThreshold = $DisableThreshold
        DeleteThreshold  = $DeleteThreshold
        SkipModuleImport = $true
        Confirm          = $false
        WarningAction    = 'SilentlyContinue'
        Verbose          = $false
        WhatIf           = $WhatIf
    }

    if ($UseExistingGraphSession) { $params['UseExistingGraphSession'] = $true }
    if ($EnableDeletion)          { $params['EnableDeletion']          = $true }

    Invoke-AccountInactivityRemediation @params
}

function Set-ScenarioContext {
    param($Scenario)

    $script:MockContext.Actions           = [System.Collections.Generic.List[pscustomobject]]::new()
    $script:MockContext.ADAccountList     = @(if ($Scenario.ContainsKey('ADAccountList'))    { $Scenario.ADAccountList }    else { @() })
    $script:MockContext.EntraAccountList  = @(if ($Scenario.ContainsKey('EntraAccountList')) { $Scenario.EntraAccountList } else { @() })
    $script:MockContext.ADUsers           = if ($Scenario.ContainsKey('ADUsers'))            { $Scenario.ADUsers }          else { @{} }
    $script:MockContext.MgUserSponsors    = if ($Scenario.ContainsKey('MgUserSponsors'))     { $Scenario.MgUserSponsors }   else { @{} }
    $script:MockContext.NotifyFail        = @(if ($Scenario.ContainsKey('NotifyFail'))       { $Scenario.NotifyFail }       else { @() })
    $script:MockContext.DisableFail       = @(if ($Scenario.ContainsKey('DisableFail'))      { $Scenario.DisableFail }      else { @() })
    $script:MockContext.RemoveFail        = @(if ($Scenario.ContainsKey('RemoveFail'))       { $Scenario.RemoveFail }       else { @() })
    $script:MockContext.ConnectFail       = if ($Scenario.ContainsKey('ConnectFail'))        { $Scenario.ConnectFail }      else { $false }
    $script:MockContext.ADAccountListFail = if ($Scenario.ContainsKey('ADAccountListFail'))  { $Scenario.ADAccountListFail } else { $false }
}

function Invoke-Scenario {
    param($Scenario)

    $script:CurrentScenario = $Scenario.Name
    $script:CurrentRun      = 1

    Set-ScenarioContext $Scenario

    $invokeParams = @{}

    if ($Scenario.ContainsKey('EnableDeletion'))          { $invokeParams['EnableDeletion']          = $Scenario.EnableDeletion }
    if ($Scenario.ContainsKey('WarnThreshold'))           { $invokeParams['WarnThreshold']           = $Scenario.WarnThreshold }
    if ($Scenario.ContainsKey('DisableThreshold'))        { $invokeParams['DisableThreshold']        = $Scenario.DisableThreshold }
    if ($Scenario.ContainsKey('DeleteThreshold'))         { $invokeParams['DeleteThreshold']         = $Scenario.DeleteThreshold }
    if ($Scenario.ContainsKey('UseExistingGraphSession')) { $invokeParams['UseExistingGraphSession'] = $Scenario.UseExistingGraphSession }
    if ($Scenario.ContainsKey('WhatIf'))                  { $invokeParams['WhatIf']                  = $Scenario.WhatIf }

    $result = Invoke-RemediationOnce @invokeParams
    if ($Scenario.ContainsKey('AssertAfterRun')) {
        & $Scenario.AssertAfterRun $result $script:MockContext
    }
}

# ---------------------------------------------------------------------------
# RUN ALL SCENARIOS
# ---------------------------------------------------------------------------

$scenarioFiles = @(Get-ChildItem -Path (Join-Path $TestRoot 'scenarios') -Filter '*.scenarios.ps1' | Sort-Object Name)

Write-Host ''
Write-Host 'Invoke-AccountInactivityRemediation - Test Harness' -ForegroundColor White
Write-Host '===================================================' -ForegroundColor White
Write-Host "Scenario files found: $($scenarioFiles.Count)" -ForegroundColor Cyan
Write-Host ''

$sweepStart = [DateTime]::UtcNow

foreach ($file in $scenarioFiles) {
    Write-Host "  Loading: $($file.Name)" -ForegroundColor DarkCyan
    $Scenarios = $null
    . $file.FullName

    if ($null -eq $Scenarios -or $Scenarios.Count -eq 0) {
        Write-Host '    (no scenarios defined)' -ForegroundColor DarkYellow
        continue
    }

    foreach ($scenario in $Scenarios) {
        Write-Host "  Running: $($scenario.Name)" -ForegroundColor White
        try {
            Invoke-Scenario $scenario
        } catch {
            $script:AssertionResults.Add([pscustomobject]@{
                Scenario  = $scenario.Name
                Run       = 0
                Assertion = 'Scenario threw an unexpected exception'
                Expected  = 'No exception'
                Actual    = $_.Exception.Message
                Pass      = $false
                Detail    = $_.ScriptStackTrace
            })
            Write-Host "    [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

$sweepEnd = [DateTime]::UtcNow

# ---------------------------------------------------------------------------
# CONSOLE SUMMARY
# ---------------------------------------------------------------------------

$totalPass = @($script:AssertionResults | Where-Object { $_.Pass }).Count
$totalFail = @($script:AssertionResults | Where-Object { -not $_.Pass }).Count
$totalAll  = $script:AssertionResults.Count

Write-Host ''
Write-Host '===============================================' -ForegroundColor White
Write-Host "Results: $totalAll assertions  |  $totalPass PASS  |  $totalFail FAIL" -ForegroundColor White

if ($totalFail -gt 0) {
    Write-Host ''
    Write-Host 'Failed assertions:' -ForegroundColor Red
    foreach ($r in ($script:AssertionResults | Where-Object { -not $_.Pass })) {
        Write-Host "  [$($r.Scenario)] $($r.Assertion)" -ForegroundColor Red
        if ($r.Detail) {
            Write-Host "    $($r.Detail)" -ForegroundColor DarkRed
        }
    }
}

# ---------------------------------------------------------------------------
# HTML REPORT
# ---------------------------------------------------------------------------

function ConvertTo-HtmlSafe {
    param([string]$s)
    if ($null -eq $s) { return '' }
    $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

$genTimestamp = $sweepStart.ToString('yyyyMMdd-HHmmss')
$reportPath   = Join-Path $ReportsDir ("RemediationTest-" + $genTimestamp + ".html")
$durationSec  = [math]::Round(($sweepEnd - $sweepStart).TotalSeconds, 1)
$genDateStr   = $sweepStart.ToString('yyyy-MM-dd HH:mm:ss')

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('<!DOCTYPE html>')
$lines.Add('<html lang="en">')
$lines.Add('<head>')
$lines.Add('<meta charset="UTF-8">')
$lines.Add('<title>Invoke-AccountInactivityRemediation - Test Report</title>')
$lines.Add('<style>')
$lines.Add('  body  { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; margin: 24px; color: #333; background: #fafafa; }')
$lines.Add('  h1    { font-size: 20px; margin-bottom: 4px; }')
$lines.Add('  .meta { color: #666; font-size: 12px; margin-bottom: 18px; }')
$lines.Add('  .summary { display: inline-block; background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: 12px 20px; margin-bottom: 20px; }')
$lines.Add('  .summary span { margin-right: 20px; font-size: 14px; }')
$lines.Add('  .pass-count { color: #3c763d; font-weight: bold; }')
$lines.Add('  .fail-count { color: #a94442; font-weight: bold; }')
$lines.Add('  table { border-collapse: collapse; width: 100%; background: #fff; border: 1px solid #ddd; border-radius: 4px; }')
$lines.Add('  th    { background: #3a3a3a; color: #fff; padding: 9px 12px; text-align: left; font-size: 12px; }')
$lines.Add('  td    { padding: 7px 12px; border-bottom: 1px solid #eee; vertical-align: top; font-size: 12px; }')
$lines.Add('  tr.pass td { background-color: #f0fff0; }')
$lines.Add('  tr.fail td { background-color: #fff0f0; }')
$lines.Add('  .badge-pass { color: #3c763d; font-weight: bold; }')
$lines.Add('  .badge-fail { color: #a94442; font-weight: bold; }')
$lines.Add('  .detail     { color: #888; font-style: italic; }')
$lines.Add('</style>')
$lines.Add('</head>')
$lines.Add('<body>')
$lines.Add('<h1>Invoke-AccountInactivityRemediation - Test Report</h1>')
$lines.Add('<div class="meta">Generated: ' + $genDateStr + ' UTC | Duration: ' + $durationSec + 's</div>')
$lines.Add('<div class="summary">')
$lines.Add('  <span>Total: <strong>' + $totalAll + '</strong></span>')
$lines.Add('  <span class="pass-count">Pass: ' + $totalPass + '</span>')
$lines.Add('  <span class="fail-count">Fail: ' + $totalFail + '</span>')
$lines.Add('</div>')
$lines.Add('<table>')
$lines.Add('<thead><tr>')
$lines.Add('  <th>Scenario</th><th>Run</th><th>Assertion</th><th>Expected</th><th>Actual</th><th>Result</th>')
$lines.Add('</tr></thead>')
$lines.Add('<tbody>')

foreach ($r in $script:AssertionResults) {
    $rowClass   = if ($r.Pass) { 'pass' } else { 'fail' }
    $badgeClass = if ($r.Pass) { 'badge-pass' } else { 'badge-fail' }
    $badgeText  = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    $detailHtml = if ($r.Detail) { '<br><span class="detail">' + (ConvertTo-HtmlSafe $r.Detail) + '</span>' } else { '' }
    $lines.Add('<tr class="' + $rowClass + '">')
    $lines.Add('  <td>' + (ConvertTo-HtmlSafe $r.Scenario) + '</td>')
    $lines.Add('  <td>' + $r.Run + '</td>')
    $lines.Add('  <td>' + (ConvertTo-HtmlSafe $r.Assertion) + $detailHtml + '</td>')
    $lines.Add('  <td>' + (ConvertTo-HtmlSafe "$($r.Expected)") + '</td>')
    $lines.Add('  <td>' + (ConvertTo-HtmlSafe "$($r.Actual)") + '</td>')
    $lines.Add('  <td><span class="' + $badgeClass + '">' + $badgeText + '</span></td>')
    $lines.Add('</tr>')
}

$lines.Add('</tbody>')
$lines.Add('</table>')
$lines.Add('</body>')
$lines.Add('</html>')

[System.IO.File]::WriteAllLines($reportPath, $lines, [System.Text.Encoding]::UTF8)

Write-Host ''
Write-Host "Report: $reportPath" -ForegroundColor Cyan

if ($env:CI -ne 'true') {
    Invoke-Item $reportPath
}

# ---------------------------------------------------------------------------
# EXIT CODE
# ---------------------------------------------------------------------------

if ($totalFail -gt 0) { exit 1 } else { exit 0 }
