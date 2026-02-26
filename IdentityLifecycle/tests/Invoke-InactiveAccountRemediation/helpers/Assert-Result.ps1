function script:Add-AssertionResult {
    param([string]$Scenario, [int]$Run, [string]$Assertion, $Expected, $Actual, [bool]$Pass)
    $detail = if (-not $Pass) { "Expected '$Expected' but got '$Actual'" } else { '' }
    $script:AssertionResults.Add([pscustomobject]@{
        Scenario  = $Scenario
        Why       = $script:CurrentWhy
        Run       = $Run
        Assertion = $Assertion
        Expected  = $Expected
        Actual    = $Actual
        Pass      = $Pass
        Detail    = $detail
    })
    return $Pass
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $pass = ($Actual -eq $Expected)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected $Expected -Actual $Actual -Pass $pass
}

function Assert-True {
    param(
        [bool]   $Condition,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $pass = ($Condition -eq $true)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected '$true' -Actual $Condition -Pass $pass
}

function Assert-False {
    param(
        [bool]   $Condition,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $pass = ($Condition -eq $false)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected '$false' -Actual $Condition -Pass $pass
}

function Assert-Null {
    param(
        $Value,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $pass = ($null -eq $Value)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected '$null' -Actual $Value -Pass $pass
}

function Assert-NotNull {
    param(
        $Value,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $pass = ($null -ne $Value)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected 'non-null' -Actual $Value -Pass $pass
}

function Assert-Empty {
    param(
        $Collection,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $count = if ($null -eq $Collection) { 0 } else { @($Collection).Count }
    $pass  = ($count -eq 0)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected 0 -Actual $count -Pass $pass
}

function Assert-Count {
    param(
        $Collection,
        [int]    $Expected,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $count = if ($null -eq $Collection) { 0 } else { @($Collection).Count }
    $pass  = ($count -eq $Expected)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected $Expected -Actual $count -Pass $pass
}

function Assert-ActionFired {
    param(
        [string] $Action,
        [string] $UPN,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $found  = @($script:MockContext.Actions | Where-Object { $_.Action -eq $Action -and $_.UPN -eq $UPN })
    $pass   = ($found.Count -gt 0)
    $detail = "$Action on $UPN"
    $actual = if ($pass) { $detail } else { 'not fired' }
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected $detail -Actual $actual -Pass $pass
}

function Assert-ActionNotFired {
    param(
        [string] $Action,
        $UPN     = $null,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $found  = @($script:MockContext.Actions | Where-Object {
        $_.Action -eq $Action -and ($null -eq $UPN -or $_.UPN -eq $UPN)
    })
    $pass   = ($found.Count -eq 0)
    $actual = if ($pass) { 'not fired' } else { "fired $($found.Count) time(s)" }
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected 'not fired' -Actual $actual -Pass $pass
}

function Assert-ResultField {
    param(
        $Results,
        [string] $UPN,
        [string] $Field,
        $Expected,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $entry  = @($Results | Where-Object { $_.UPN -eq $UPN }) | Select-Object -First 1
    $actual = if ($null -eq $entry) { '(no entry)' } else { $entry.$Field }
    $pass   = ($actual -eq $Expected)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected $Expected -Actual $actual -Pass $pass
}

function Assert-SummaryField {
    param(
        $Summary,
        [string] $Field,
        $Expected,
        [string] $Message,
        [string] $Scenario = $script:CurrentScenario,
        [int]    $Run      = $script:CurrentRun
    )
    $actual = $Summary.$Field
    $pass   = ($actual -eq $Expected)
    Add-AssertionResult -Scenario $Scenario -Run $Run -Assertion $Message -Expected $Expected -Actual $actual -Pass $pass
}
