$Scenarios = @(

    # ------------------------------------------------------------------
    # 01-01: AD account 30 days inactive -- below WarnThreshold -- Skipped
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.active01'; $upn = 'admin.active01@corp.local'; $std = 'active01'
        @{
            Name     = '01-01: AD account 30 days inactive -- below threshold -- Skipped/ActivityDetected'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 30 -WhenCreatedDaysAgo 200
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped'  1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'Warned'   0 'Warned = 0'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0'
                Assert-SummaryField `$result.Summary 'Errors'   0 'Errors = 0'
                Assert-ResultField  `$result.Results '$upn' 'Status'     'Skipped'          'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-02: AD account already disabled at DisableThreshold
    # The disable call is skipped (already disabled) but the account is
    # still evaluated and completed -- Disable-InactiveAccount not called.
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.disabled02'; $upn = 'admin.disabled02@corp.local'; $std = 'disabled02'
        @{
            Name     = '01-02: AD account already disabled at threshold -- Completed, Disable not called'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300 -Enabled $false
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1 (already disabled counts as completed)'
                Assert-ResultField  `$result.Results '$upn' 'Status'      'Completed' 'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Disable'   'ActionTaken = Disable'
                Assert-ActionFired    'Notify'  '$upn' 'Notify still fired'
                Assert-ActionNotFired 'Disable' '$upn' 'Disable-InactiveAccount NOT called (already disabled)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-03: Get-PrefixedADAccounts fails -- fatal error before any
    # processing; Results empty, Summary present with all zeros.
    # ------------------------------------------------------------------
    $(
        @{
            Name                 = '01-03: Get-PrefixedADAccounts fails -- fatal error, Results empty, Summary present'
            ADAccountListFail    = $true
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-False  `$result.Success 'Success = false'
                Assert-NotNull `$result.Error  'Error is set'
                Assert-Empty  `$result.Results 'Results is empty'
                Assert-NotNull `$result.Summary 'Summary is present (always built in finally)'
                Assert-SummaryField `$result.Summary 'Total' 0 'Total = 0'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-04: Empty discovery -- zero accounts, Success=$true
    # ------------------------------------------------------------------
    $(
        @{
            Name     = '01-04: No accounts discovered -- zero results, Success=$true'
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True   `$result.Success       'Success = true'
                Assert-Null   `$result.Error         'Error is null'
                Assert-NotNull `$result.Summary      'Summary present'
                Assert-SummaryField `$result.Summary 'Total' 0 'Total = 0'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-05: AD account already disabled at DeleteThreshold, EnableDeletion ON
    # Already disabled → disable step skipped; delete step fires.
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.del05'; $upn = 'admin.del05@corp.local'; $std = 'del05'
        @{
            Name              = '01-05: AD account already disabled at DeleteThreshold, EnableDeletion ON -- Deleted'
            EnableDeletion    = $true
            ADAccountList     = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 180 -WhenCreatedDaysAgo 500 -Enabled $false
            )
            ADUsers           = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Deleted' 1 'Deleted = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'      'Completed' 'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Delete'    'ActionTaken = Delete'
                Assert-ActionFired    'Remove'  '$upn' 'Remove fired'
                Assert-ActionNotFired 'Disable' '$upn' 'Disable-InactiveAccount not called (already disabled)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-06: AD + cloud-native Entra in same batch -- both processed
    # ------------------------------------------------------------------
    $(
        $samAD  = 'admin.mixed06a'; $upnAD  = 'admin.mixed06a@corp.local'; $stdAD  = 'mixed06a'
        $oidEN  = [guid]::NewGuid().ToString(); $upnEN = 'cloud.mixed06b@corp.local'
        @{
            Name     = '01-06: Mixed AD + Entra-native batch -- both accounts processed'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $samAD -UPN $upnAD -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            EntraAccountList = @(
                New-DirectEntraAccount -EntraObjectId $oidEN -UPN $upnEN -LastSignInDaysAgo 95
            )
            ADUsers  = @{
                $stdAD = New-DirectOwnerADUser -SamAccountName $stdAD -EmailAddress "$stdAD@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Total'  2 'Total = 2'
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (AD account with owner)'
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1 (Entra-native, no owner)'
                Assert-ResultField  `$result.Results '$upnAD' 'Status' 'Completed' 'AD account completed'
                Assert-ResultField  `$result.Results '$upnEN' 'Status' 'Skipped'   'Entra-native skipped (no owner)'
"@)
        }
    )

)
