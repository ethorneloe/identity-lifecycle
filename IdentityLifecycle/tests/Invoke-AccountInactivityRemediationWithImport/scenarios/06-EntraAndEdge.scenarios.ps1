$Scenarios = @(

    # ------------------------------------------------------------------
    # 06-01: Entra-native account, active sign-in -- Skipped/ActivityDetected
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString()
        $upn = 'cloud.active01@corp.local'
        @{
            Name    = '06-01: Entra-native with recent sign-in -- Skipped/ActivityDetected'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = ''
                    UserPrincipalName     = $upn
                    LastLogonDate         = ''
                    Created               = [datetime]::UtcNow.AddDays(-200).ToString('o')
                    Enabled               = 'True'
                    EntraObjectId         = $oid
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{}
            MgUsers = @{
                $oid.ToLower() = New-ImportMgUser -ObjectId $oid -AccountEnabled $true -LastSignInDaysAgo 30
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-02: Entra-native account, inactive -- Notify/Warning
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString()
        $upn = 'cloud.inactive02@corp.local'
        @{
            Name    = '06-02: Entra-native with 95 days inactive -- Notify/Warning'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = ''
                    UserPrincipalName     = $upn
                    LastLogonDate         = ''
                    Created               = [datetime]::UtcNow.AddDays(-200).ToString('o')
                    Enabled               = 'True'
                    EntraObjectId         = $oid
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{}
            MgUsers = @{
                $oid.ToLower() = New-ImportMgUser -ObjectId $oid -AccountEnabled $true -LastSignInDaysAgo 95
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1 (NoOwnerFound -- Entra-native has no AD owner)'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 'NoOwner = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Skipped'      'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'NoOwnerFound' 'SkipReason = NoOwnerFound'
                Assert-ActionNotFired 'Notify' '$upn' 'No Notify (no owner)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-03: AD account with EntraObjectId -- Entra sign-in more recent than AD logon
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid03'; $upn = 'admin.hybrid03@corp.local'; $std = 'hybrid03'
        $oid = [guid]::NewGuid().ToString()
        @{
            Name    = '06-03: AD account with EntraObjectId -- Entra sign-in wins when more recent'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = $sam
                    UserPrincipalName     = $upn
                    LastLogonDate         = [datetime]::UtcNow.AddDays(-110).ToString('o')
                    Created               = [datetime]::UtcNow.AddDays(-300).ToString('o')
                    Enabled               = 'True'
                    EntraObjectId         = $oid
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-110)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            MgUsers = @{
                # Entra sign-in = 40 days ago (more recent than AD 110 days) -- account is fresh
                $oid.ToLower() = New-ImportMgUser -ObjectId $oid -AccountEnabled $true -LastSignInDaysAgo 40
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1 (Entra sign-in is more recent)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable (Entra sign-in fresh)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-04: AD account with EntraObjectId -- AD logon more recent than Entra
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid04'; $upn = 'admin.hybrid04@corp.local'; $std = 'hybrid04'
        $oid = [guid]::NewGuid().ToString()
        @{
            Name    = '06-04: AD account with EntraObjectId -- live AD logon wins when most recent'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = $sam
                    UserPrincipalName     = $upn
                    LastLogonDate         = [datetime]::UtcNow.AddDays(-200).ToString('o')
                    Created               = [datetime]::UtcNow.AddDays(-400).ToString('o')
                    Enabled               = 'True'
                    EntraObjectId         = $oid
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{
                # Live AD last logon = 40 days ago (fresh, overrides stale export value)
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-40)) `
                    -WhenCreatedDaysAgo 400 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            MgUsers = @{
                # Entra sign-in = 180 days ago (older)
                $oid.ToLower() = New-ImportMgUser -ObjectId $oid -AccountEnabled $true -LastSignInDaysAgo 180
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1 (live AD logon is most recent)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-05: Custom thresholds respected
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.custom05'; $upn = 'admin.custom05@corp.local'; $std = 'custom05'
        @{
            Name             = '06-05: Custom thresholds -- WarnThreshold=30, account at 35 days -- Warn'
            WarnThreshold    = 30
            DisableThreshold = 60
            DeleteThreshold  = 90
            Accounts         = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 35
            )
            ADUsers          = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-35)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (custom WarnThreshold=30)'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Notify' 'ActionTaken = Notify'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-06: Accounts with only no-UPN rows -- recorded as Skipped/NoUPN, no errors
    # (PowerShell cannot bind an empty @() to a mandatory [object[]] param,
    #  so we pass one row without a UPN to exercise the NoUPN skip path.)
    # ------------------------------------------------------------------
    $(
        @{
            Name     = '06-06: Accounts with only no-UPN rows -- Skipped/NoUPN, no error'
            Accounts = @([pscustomobject]@{ SamAccountName = ''; UserPrincipalName = '' })
            ADUsers  = @{}
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Total'   1 'Total = 1'
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'Errors'  0 'Errors = 0'
                Assert-True `$result.Success 'Success = true (no errors)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-08: NotificationRecipientOverride -- mail goes to override, real owner still in result
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.over08'; $upn = 'admin.over08@corp.local'; $std = 'over08'
        $override = 'test-inbox@corp.local'
        @{
            Name    = '06-08: NotificationRecipientOverride -- mail redirected, real owner recorded'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName      = $sam
                    UserPrincipalName   = $upn
                    LastLogonDate       = [datetime]::UtcNow.AddDays(-95).ToString('o')
                    Created             = [datetime]::UtcNow.AddDays(-300).ToString('o')
                    Enabled             = 'True'
                    EntraObjectId       = ''
                    entraLastSignInAEST = ''
                    Description         = ''
                }
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" `
                    -Enabled $true -EmailAddress 'real-owner@corp.local'
            }
            NotificationRecipientOverride = $override
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-Equal `$result.Results[0].NotificationRecipient 'real-owner@corp.local' 'Real owner recorded in result'
                Assert-Equal (`$ctx.Actions | Where-Object { `$_.Action -eq 'Notify' } | Select-Object -First 1).Recipient '$override' 'Mail sent to override address'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-07: Account with SamAccountName but no OnPremisesSyncEnabled/Source -- takes AD path
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.default07'; $upn = 'admin.default07@corp.local'; $std = 'default07'
        @{
            Name    = '06-07: SamAccountName present, OnPremisesSyncEnabled and Source absent -- AD path taken'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = $sam
                    UserPrincipalName     = $upn
                    LastLogonDate         = [datetime]::UtcNow.AddDays(-95).ToString('o')
                    Created               = [datetime]::UtcNow.AddDays(-300).ToString('o')
                    Enabled               = 'True'
                    EntraObjectId         = ''
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (AD path taken -- SamAccountName present)'
"@)
        }
    )

)
