$Scenarios = @(

    # ------------------------------------------------------------------
    # 01-01: Account below WarnThreshold -- Skipped/ActivityDetected
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.act01'; $upn = 'admin.act01@corp.local'; $std = 'act01'
        @{
            Name          = '01-01: [Discovery] Account below WarnThreshold -- Skipped/ActivityDetected'
            Why           = 'Confirms active accounts are never touched, regardless of how they were discovered.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 30 -WhenCreatedDaysAgo 200
            )
            ADUsers = @{
                $std = New-DiscoveryOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[disc] Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' '[disc] SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-02: Already-disabled account at delete threshold -- Delete fires
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.dis02'; $upn = 'admin.dis02@corp.local'; $std = 'dis02'
        @{
            Name           = '01-02: [Discovery] Already-disabled account at delete threshold -- Deleted'
            Why            = 'An account disabled by a previous sweep should proceed straight to deletion when EnableDeletion is on -- no redundant Disable call.'
            EnableDeletion = $true
            ADAccountList  = @(
                New-DiscoveryADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 200 -WhenCreatedDaysAgo 500 -Enabled $false
            )
            ADUsers = @{
                $std = New-DiscoveryOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Deleted' 1 '[disc] Deleted = 1'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Delete' '[disc] ActionTaken = Delete'
                Assert-ActionNotFired 'Disable' '$upn' '[disc] Disable not called for already-disabled account'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-03: Get-PrefixedADAccounts fails -- function returns Success=false
    # ------------------------------------------------------------------
    @{
        Name              = '01-03: [Discovery] Get-PrefixedADAccounts failure -- Success=false, Error set'
        Why               = 'A failure during account discovery is unrecoverable for that run -- the function must surface it clearly rather than silently processing zero accounts.'
        ADAccountListFail = $true
        AssertAfterRun    = [scriptblock]::Create(@"
            param(`$result, `$ctx)
            Assert-False `$result.Success '[disc] Success = false on discovery failure'
            Assert-NotNull `$result.Error '[disc] Error field populated on discovery failure'
"@)
    },

    # ------------------------------------------------------------------
    # 01-04: Empty discovery (no accounts found) -- Success=true, empty Results
    # ------------------------------------------------------------------
    @{
        Name           = '01-04: [Discovery] Empty discovery -- Success=true, Results empty'
        Why            = 'Zero accounts is a valid outcome (e.g. all prefixed accounts removed); the function must not error or produce phantom results.'
        ADAccountList  = @()
        EntraAccountList = @()
        AssertAfterRun = [scriptblock]::Create(@"
            param(`$result, `$ctx)
            Assert-True  `$result.Success              '[disc] Success = true for empty discovery'
            Assert-Count `$result.Results 0            '[disc] Results empty for empty discovery'
            Assert-Null  `$result.Error                '[disc] No error for empty discovery'
"@)
    },

    # ------------------------------------------------------------------
    # 01-05: Mixed AD + Entra-native batch in discovery mode
    # ------------------------------------------------------------------
    $(
        $samA = 'admin.mix05a'; $upnA = 'admin.mix05a@corp.local'; $stdA = 'mix05a'
        $samB = 'admin.mix05b'; $upnB = 'admin.mix05b@corp.local'
        $oidC = [guid]::NewGuid().ToString(); $upnC = 'cloud.mix05c@corp.local'
        @{
            Name          = '01-05: [Discovery] Mixed AD+Entra batch -- AD with owner, AD no owner, Entra-native'
            Why           = 'Verifies the three account types (AD with owner, AD without owner, cloud-native) are all processed in a single batch with independent outcomes.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $samA -UPN $upnA -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                # mix05b strips to 'mix05b' -- not in ADUsers -- NoOwnerFound
                New-DiscoveryADAccount -SamAccountName $samB -UPN $upnB -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oidC -UPN $upnC -LastSignInDaysAgo 95
            )
            ADUsers = @{
                $stdA = New-DiscoveryOwnerADUser -SamAccountName $stdA -EmailAddress "$stdA@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Total'    3 '[disc] Total = 3'
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[disc] Disabled = 1 (mix05a)'
                Assert-SummaryField `$result.Summary 'Skipped'  2 '[disc] Skipped = 2 (mix05b NoOwner + cloud NoOwner)'
                Assert-SummaryField `$result.Summary 'NoOwner'  2 '[disc] NoOwner = 2'
                Assert-ResultField  `$result.Results '$upnA' 'Status' 'Completed' '[disc] mix05a = Completed'
                Assert-ResultField  `$result.Results '$upnB' 'Status' 'Skipped'   '[disc] mix05b = Skipped'
                Assert-ResultField  `$result.Results '$upnC' 'Status' 'Skipped'   '[disc] cloud = Skipped'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-06: Already-disabled at warn threshold, EnableDeletion off -- Notify only
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.disa06'; $upn = 'admin.disa06@corp.local'; $std = 'disa06'
        @{
            Name          = '01-06: [Discovery] Already-disabled account at warn threshold -- Notify only (no Disable)'
            Why           = 'An account that is already disabled still gets a warning notification but must not receive a redundant Disable action.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300 -Enabled $false
            )
            ADUsers = @{
                $std = New-DiscoveryOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[disc] Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Notify' '[disc] ActionTaken = Notify'
                Assert-ActionNotFired 'Disable' '$upn' '[disc] Disable not called (already disabled)'
"@)
        }
    )

)
