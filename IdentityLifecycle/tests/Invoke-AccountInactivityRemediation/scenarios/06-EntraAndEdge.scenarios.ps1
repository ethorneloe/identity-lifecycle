$Scenarios = @(

    # ------------------------------------------------------------------
    # 06-01: Entra-native with recent sign-in -- Skipped/ActivityDetected
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString(); $upn = 'cloud.active01@corp.local'
        @{
            Name             = '06-01: Entra-native with recent sign-in -- Skipped/ActivityDetected'
            EntraAccountList = @(
                New-RemediationEntraAccount -EntraObjectId $oid -UPN $upn -LastSignInDaysAgo 5
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-02: Entra-native 95 days inactive -- Skipped/NoOwnerFound (no SAM, no owner)
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString(); $upn = 'cloud.inactive02@corp.local'
        @{
            Name             = '06-02: Entra-native 95 days inactive -- Skipped/NoOwnerFound (no SAM)'
            EntraAccountList = @(
                New-RemediationEntraAccount -EntraObjectId $oid -UPN $upn -LastSignInDaysAgo 95
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 'NoOwner = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'NoOwnerFound' 'SkipReason = NoOwnerFound'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-03: AD account synced to Entra -- Entra sign-in used when more recent
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid03'; $upn = 'admin.hybrid03@corp.local'; $std = 'hybrid03'
        $oid = [guid]::NewGuid().ToString()
        @{
            Name     = '06-03: AD account with synced Entra -- Entra sign-in used when more recent'
            ADAccountList = @(
                # AD logon 120 days ago; Entra sign-in 85 days ago (more recent → below WarnThreshold)
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 400
            )
            EntraAccountList = @(
                # Synced account -- same UPN; sign-in 85 days ago
                New-RemediationEntraAccount -EntraObjectId $oid -UPN $upn `
                    -LastSignInDaysAgo 85 -OnPremisesSyncEnabled $true
            )
            ADUsers  = @{
                $std = New-RemediationOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1 (Entra sign-in 85d < WarnThreshold 90d)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-04: AD account synced to Entra -- AD logon used when more recent
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid04'; $upn = 'admin.hybrid04@corp.local'; $std = 'hybrid04'
        $oid = [guid]::NewGuid().ToString()
        @{
            Name     = '06-04: AD account with synced Entra -- AD logon used when more recent'
            ADAccountList = @(
                # AD logon 85 days ago (more recent); Entra sign-in 120 days ago
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 85 -WhenCreatedDaysAgo 400
            )
            EntraAccountList = @(
                New-RemediationEntraAccount -EntraObjectId $oid -UPN $upn `
                    -LastSignInDaysAgo 120 -OnPremisesSyncEnabled $true
            )
            ADUsers  = @{
                $std = New-RemediationOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1 (AD logon 85d < WarnThreshold 90d)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-05: Mixed batch -- AD with owner, AD without owner, Entra-native
    # ------------------------------------------------------------------
    $(
        $samA = 'admin.mix05a'; $upnA = 'admin.mix05a@corp.local'; $stdA = 'mix05a'
        $samB = 'admin.mix05b'; $upnB = 'admin.mix05b@corp.local'
        $oidC = [guid]::NewGuid().ToString(); $upnC = 'cloud.mix05c@corp.local'
        @{
            Name     = '06-05: Mixed batch -- AD with owner, AD no owner, Entra-native'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $samA -UPN $upnA -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                # mix05b strips to 'mix05b' -- not in ADUsers, no owner
                New-RemediationADAccount -SamAccountName $samB -UPN $upnB -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            EntraAccountList = @(
                New-RemediationEntraAccount -EntraObjectId $oidC -UPN $upnC -LastSignInDaysAgo 95
            )
            ADUsers  = @{
                $stdA = New-RemediationOwnerADUser -SamAccountName $stdA -EmailAddress "$stdA@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Total'    3 'Total = 3'
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1 (mix05a)'
                Assert-SummaryField `$result.Summary 'Skipped'  2 'Skipped = 2 (mix05b NoOwner + cloud NoOwner)'
                Assert-SummaryField `$result.Summary 'NoOwner'  2 'NoOwner = 2'
                Assert-ResultField  `$result.Results '$upnA' 'Status' 'Completed' 'mix05a = Completed'
                Assert-ResultField  `$result.Results '$upnB' 'Status' 'Skipped'   'mix05b = Skipped'
                Assert-ResultField  `$result.Results '$upnC' 'Status' 'Skipped'   'cloud = Skipped'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-06: NotificationRecipientOverride -- mail goes to override, real owner still in result
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.over06'; $upn = 'admin.over06@corp.local'; $std = 'over06'
        $override = 'test-inbox@corp.local'
        @{
            Name          = '06-06: NotificationRecipientOverride -- mail redirected, real owner recorded'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $std = New-RemediationOwnerADUser -SamAccountName $std -EmailAddress 'real-owner@corp.local'
            }
            NotificationRecipientOverride = $override
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-Equal `$result.Results[0].NotificationRecipient 'real-owner@corp.local' 'Real owner recorded in result'
                Assert-Equal (`$ctx.Actions | Where-Object { `$_.Action -eq 'Notify' } | Select-Object -First 1).Recipient '$override' 'Mail sent to override address'
"@)
        }
    )

)
