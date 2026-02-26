# Threshold scenarios -- shared logic, no mode branching.
# Alternate import/discovery across scenarios to exercise both paths without doubling every case.
# 03-09 disc slot is repurposed as a custom-thresholds check (null Created is import-only).

# ---------------------------------------------------------------------------
# Helper: build a threshold scenario for a given mode
# ---------------------------------------------------------------------------

function New-ThresholdScenario {
    param(
        [string] $Name,
        [string] $Why,
        [string] $Mode,       # 'import' or 'discovery'
        [int]    $DaysAgo,
        [int]    $WhenCreatedDaysAgo = 400,
        [string] $ExpectedAction,       # 'Notify','Disable','Delete', or ''
        [string] $ExpectedStatus,       # 'Completed' or 'Skipped'
        [string] $ExpectedSkipReason = '',
        [string] $SummaryKey,
        [int]    $SummaryVal,
        [bool]   $EnableDeletion    = $false,
        [bool]   $AlreadyDisabled   = $false,
        [int]    $WarnThreshold     = 90,
        [int]    $DisableThreshold  = 120,
        [int]    $DeleteThreshold   = 180
    )

    $tag  = "[$Mode]"
    $sam  = "admin.thr$([guid]::NewGuid().ToString('N').Substring(0,6))"
    $upn  = "$sam@corp.local"
    $std  = $sam -replace '^admin\.', ''

    if ($Mode -eq 'import') {
        $lastLogonDate = if ($DaysAgo -gt 0) { [datetime]::UtcNow.AddDays(-$DaysAgo) } else { $null }
        $scenario = @{
            Name     = "$Name $tag"
            Why      = $Why
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo $DaysAgo `
                    -WhenCreatedDaysAgo $WhenCreatedDaysAgo -AccountEnabled (-not $AlreadyDisabled)
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate $lastLogonDate `
                    -WhenCreatedDaysAgo $WhenCreatedDaysAgo -Enabled (-not $AlreadyDisabled)
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
        }
    } else {
        $scenario = @{
            Name          = "$Name $tag"
            Why           = $Why
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo $DaysAgo `
                    -WhenCreatedDaysAgo $WhenCreatedDaysAgo -Enabled (-not $AlreadyDisabled)
            )
            ADUsers = @{
                $std = New-DiscoveryOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
        }
    }

    if ($EnableDeletion)           { $scenario['EnableDeletion']    = $true }
    if ($WarnThreshold -ne 90)     { $scenario['WarnThreshold']     = $WarnThreshold }
    if ($DisableThreshold -ne 120) { $scenario['DisableThreshold']  = $DisableThreshold }
    if ($DeleteThreshold -ne 180)  { $scenario['DeleteThreshold']   = $DeleteThreshold }

    $capturedUpn    = $upn
    $capturedAction = $ExpectedAction
    $capturedStatus = $ExpectedStatus
    $capturedSkip   = $ExpectedSkipReason
    $capturedKey    = $SummaryKey
    $capturedVal    = $SummaryVal

    $scenario['AssertAfterRun'] = [scriptblock]::Create(@"
        param(`$result, `$ctx)
        Assert-SummaryField `$result.Summary '$capturedKey' $capturedVal '$tag $capturedKey = $capturedVal'
        Assert-ResultField  `$result.Results '$capturedUpn' 'Status' '$capturedStatus' '$tag Status = $capturedStatus'
$(if ($capturedAction) { "        Assert-ResultField  `$result.Results '$capturedUpn' 'ActionTaken' '$capturedAction' '$tag ActionTaken = $capturedAction'" })
$(if ($capturedSkip)   { "        Assert-ResultField  `$result.Results '$capturedUpn' 'SkipReason'  '$capturedSkip'   '$tag SkipReason = $capturedSkip'" })
"@)

    return $scenario
}

$Scenarios = @(

    # ------------------------------------------------------------------
    # 03-01: 90 days inactive -- Warn [import]
    # ------------------------------------------------------------------
    (New-ThresholdScenario -Name '03-01: WarnThreshold (90d) -- Notify sent' `
        -Why 'Boundary check: exactly at WarnThreshold must trigger a warning notification.' `
        -Mode 'import' -DaysAgo 90 `
        -ExpectedAction 'Notify' -ExpectedStatus 'Completed' `
        -SummaryKey 'Warned' -SummaryVal 1),

    # ------------------------------------------------------------------
    # 03-02: 89 days inactive -- no action [discovery]
    # ------------------------------------------------------------------
    (New-ThresholdScenario -Name '03-02: Below WarnThreshold (89d) -- ActivityDetected' `
        -Why 'One day below the warn boundary must produce no action -- confirms the threshold is inclusive, not off-by-one.' `
        -Mode 'discovery' -DaysAgo 89 `
        -ExpectedStatus 'Skipped' -ExpectedSkipReason 'ActivityDetected' `
        -SummaryKey 'Skipped' -SummaryVal 1),

    # ------------------------------------------------------------------
    # 03-03: 120 days inactive -- Disable [import]
    # ------------------------------------------------------------------
    (New-ThresholdScenario -Name '03-03: DisableThreshold (120d) -- Disable fired' `
        -Why 'Boundary check: exactly at DisableThreshold must disable the account and notify the owner.' `
        -Mode 'import' -DaysAgo 120 `
        -ExpectedAction 'Disable' -ExpectedStatus 'Completed' `
        -SummaryKey 'Disabled' -SummaryVal 1),

    # ------------------------------------------------------------------
    # 03-04: 150 days inactive -- Disable (between disable and delete) [discovery]
    # ------------------------------------------------------------------
    (New-ThresholdScenario -Name '03-04: Between Disable and Delete (150d) -- Disable fired' `
        -Why 'Confirms Disable is still the correct action when inactivity is above DisableThreshold but below DeleteThreshold.' `
        -Mode 'discovery' -DaysAgo 150 `
        -ExpectedAction 'Disable' -ExpectedStatus 'Completed' `
        -SummaryKey 'Disabled' -SummaryVal 1),

    # ------------------------------------------------------------------
    # 03-05: 180 days inactive, EnableDeletion=false -- Disable only [import]
    # ------------------------------------------------------------------
    (New-ThresholdScenario -Name '03-05: DeleteThreshold (180d), EnableDeletion=false -- Disable only' `
        -Why 'When deletion is not enabled, accounts at the delete threshold must still only be disabled -- the delete gate must be respected.' `
        -Mode 'import' -DaysAgo 180 -WhenCreatedDaysAgo 500 `
        -ExpectedAction 'Disable' -ExpectedStatus 'Completed' `
        -SummaryKey 'Disabled' -SummaryVal 1 -EnableDeletion $false),

    # ------------------------------------------------------------------
    # 03-06: 180 days inactive, EnableDeletion=true -- Delete [discovery]
    # ------------------------------------------------------------------
    (New-ThresholdScenario -Name '03-06: DeleteThreshold (180d), EnableDeletion=true -- Delete fired' `
        -Why 'Boundary check: exactly at DeleteThreshold with EnableDeletion must remove the account.' `
        -Mode 'discovery' -DaysAgo 180 -WhenCreatedDaysAgo 500 `
        -ExpectedAction 'Delete' -ExpectedStatus 'Completed' `
        -SummaryKey 'Deleted' -SummaryVal 1 -EnableDeletion $true),

    # ------------------------------------------------------------------
    # 03-07: Already-disabled at delete threshold, EnableDeletion=true -- Delete, no re-disable [import]
    # ------------------------------------------------------------------
    (New-ThresholdScenario -Name '03-07: Already-disabled, EnableDeletion=true -- Delete, no Disable call' `
        -Why 'An account disabled by a previous sweep must go straight to deletion without a redundant Disable call.' `
        -Mode 'import' -DaysAgo 200 -WhenCreatedDaysAgo 500 `
        -ExpectedAction 'Delete' -ExpectedStatus 'Completed' `
        -SummaryKey 'Deleted' -SummaryVal 1 -EnableDeletion $true -AlreadyDisabled $true),

    # ------------------------------------------------------------------
    # 03-08: No logon date, Created 300 days ago -- Created used as baseline [discovery]
    # ------------------------------------------------------------------
    $(
        $sam8d = 'admin.nolog08d'; $upn8d = 'admin.nolog08d@corp.local'; $std8d = 'nolog08d'
        @{
            Name          = '03-08: No logon date, Created 300d ago -- Created used as baseline (Disable) [disc]'
            Why           = 'When LastLogonDate is absent, Created date must be used as the inactivity baseline so newly-provisioned but never-used accounts are still caught.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $sam8d -UPN $upn8d -LastLogonDaysAgo -1 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $std8d = New-DiscoveryOwnerADUser -SamAccountName $std8d -EmailAddress "$std8d@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[disc] Disabled = 1 (Created baseline)'
                Assert-ResultField  `$result.Results '$upn8d' 'ActionTaken' 'Disable' '[disc] ActionTaken = Disable'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-09: No logon date AND no Created -- Error (import-only; string parse) [import]
    # ------------------------------------------------------------------
    $(
        $sam9i = 'admin.nodata09i'; $upn9i = 'admin.nodata09i@corp.local'; $std9i = 'nodata09i'
        @{
            Name     = '03-09: No logon date AND no Created -- Error (cannot calculate inactivity) [import]'
            Why      = 'When both date fields are blank in the CSV, inactivity cannot be determined -- the account must be flagged as an error rather than silently skipped or incorrectly actioned.'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName      = $sam9i
                    UserPrincipalName   = $upn9i
                    LastLogonDate       = ''
                    Created             = ''
                    Enabled             = 'True'
                    EntraObjectId       = ''
                    entraLastSignInAEST = ''
                    Description         = ''
                }
            )
            ADUsers  = @{
                $sam9i = New-ImportADUser -SamAccountName $sam9i -UPN $upn9i `
                    -LastLogonDate $null -WhenCreatedDaysAgo 400 -Enabled $true
                $std9i = New-ImportADUser -SamAccountName $std9i -UPN "$std9i@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 '[import] Errors = 1 (no date data)'
                Assert-ResultField  `$result.Results '$upn9i' 'Status' 'Error' '[import] Status = Error'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-10: Custom thresholds -- 60d above WarnThreshold 50, below DisableThreshold 80 [discovery]
    # ------------------------------------------------------------------
    $(
        $sam10d = 'admin.custom10d'; $upn10d = 'admin.custom10d@corp.local'; $std10d = 'custom10d'
        @{
            Name             = '03-10: Custom thresholds (50/80/100) -- 60d inactive -- Warn [disc]'
            Why              = 'Confirms that caller-supplied threshold values override the defaults, allowing the same function to serve different policies.'
            ADAccountList    = @(
                New-DiscoveryADAccount -SamAccountName $sam10d -UPN $upn10d -LastLogonDaysAgo 60 -WhenCreatedDaysAgo 200
            )
            WarnThreshold    = 50
            DisableThreshold = 80
            DeleteThreshold  = 100
            ADUsers = @{
                $std10d = New-DiscoveryOwnerADUser -SamAccountName $std10d -EmailAddress "$std10d@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[disc] Custom thresholds: 60d above WarnThreshold 50 -- Warned'
                Assert-ResultField  `$result.Results '$upn10d' 'ActionTaken' 'Notify' '[disc] Custom thresholds: ActionTaken = Notify'
"@)
        }
    )

)
