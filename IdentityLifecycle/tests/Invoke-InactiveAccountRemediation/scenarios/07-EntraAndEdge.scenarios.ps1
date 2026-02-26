$Scenarios = @(

    # ------------------------------------------------------------------
    # 07-01: Entra-native with recent sign-in -- ActivityDetected (discovery)
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString(); $upn = 'cloud.active01@corp.local'
        @{
            Name             = '07-01: [Discovery] Entra-native recent sign-in -- ActivityDetected'
            Why              = 'Cloud-native accounts with recent Entra sign-in must be protected from action -- confirms the sign-in date is checked before any threshold routing.'
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oid -UPN $upn -LastSignInDaysAgo 5
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[disc] Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' '[disc] SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 07-02: Entra-native 95 days inactive, no owner -- NoOwnerFound (discovery)
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString(); $upn = 'cloud.inactive02@corp.local'
        @{
            Name             = '07-02: [Discovery] Entra-native 95d inactive, no owner -- NoOwnerFound'
            Why              = 'An inactive cloud-native account with no sponsor has no notification path -- must be skipped and counted in NoOwner, not silently dropped.'
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oid -UPN $upn -LastSignInDaysAgo 95
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[disc] Skipped = 1'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 '[disc] NoOwner = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'NoOwnerFound' '[disc] SkipReason = NoOwnerFound'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 07-03: AD account synced to Entra -- Entra sign-in more recent -- ActivityDetected (discovery)
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid03'; $upn = 'admin.hybrid03@corp.local'; $std = 'hybrid03'
        $oid = [guid]::NewGuid().ToString()
        @{
            Name     = '07-03: [Discovery] AD+synced Entra -- Entra sign-in more recent -- ActivityDetected'
            Why      = 'For hybrid accounts the most recent activity across both AD and Entra must be used -- a recent Entra sign-in must protect the account even when the AD logon is stale.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 400
            )
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oid -UPN $upn `
                    -LastSignInDaysAgo 85 -OnPremisesSyncEnabled $true
            )
            ADUsers = @{
                $std = New-DiscoveryOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[disc] Skipped = 1 (Entra sign-in 85d < 90d)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' '[disc] SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 07-04: AD account synced to Entra -- AD logon more recent -- ActivityDetected (discovery)
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid04'; $upn = 'admin.hybrid04@corp.local'; $std = 'hybrid04'
        $oid = [guid]::NewGuid().ToString()
        @{
            Name     = '07-04: [Discovery] AD+synced Entra -- AD logon more recent -- ActivityDetected'
            Why      = 'Complement of 07-03 -- a recent AD logon must protect the account even when the Entra sign-in is stale, confirming the max-of-both logic works in both directions.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 85 -WhenCreatedDaysAgo 400
            )
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oid -UPN $upn `
                    -LastSignInDaysAgo 120 -OnPremisesSyncEnabled $true
            )
            ADUsers = @{
                $std = New-DiscoveryOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[disc] Skipped = 1 (AD logon 85d < 90d)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' '[disc] SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 07-05: Entra sign-in more recent in import mode (import)
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid05i'; $upn = 'admin.hybrid05i@corp.local'; $std = 'hybrid05i'
        $oid = [guid]::NewGuid().ToString()
        $entraSignIn = [datetime]::UtcNow.AddDays(-85).ToString('o')
        @{
            Name     = '07-05: [Import] Entra sign-in more recent than AD logon -- ActivityDetected'
            Why      = 'In import mode the Entra sign-in timestamp comes from the CSV export -- confirms it is parsed correctly and used when it is more recent than the live AD logon.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 150 `
                    -EntraObjectId $oid -LastSignInEntra $entraSignIn
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-150)) -WhenCreatedDaysAgo 400 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            MgUsers  = @{
                $oid = New-ImportMgUser -ObjectId $oid -AccountEnabled $true -LastSignInDaysAgo 85
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[import] Skipped = 1 (Entra sign-in 85d < 90d)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' '[import] SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 07-06: AD logon more recent than Entra sign-in in import mode (import)
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.hybrid06i'; $upn = 'admin.hybrid06i@corp.local'; $std = 'hybrid06i'
        $oid = [guid]::NewGuid().ToString()
        $entraSignIn = [datetime]::UtcNow.AddDays(-150).ToString('o')
        @{
            Name     = '07-06: [Import] AD logon more recent than Entra sign-in -- ActivityDetected'
            Why      = 'Complement of 07-05 in import mode -- a recent live AD logon must override the stale exported Entra timestamp and protect the account.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 85 `
                    -EntraObjectId $oid -LastSignInEntra $entraSignIn
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-85)) -WhenCreatedDaysAgo 400 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            MgUsers  = @{
                $oid = New-ImportMgUser -ObjectId $oid -AccountEnabled $true -LastSignInDaysAgo 150
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[import] Skipped = 1 (AD logon 85d < 90d)'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' '[import] SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 07-07: NotificationRecipientOverride -- mail redirected, real owner recorded (import + discovery)
    # ------------------------------------------------------------------
    $(
        $sam      = 'admin.over07i'; $upn = 'admin.over07i@corp.local'; $std = 'over07i'
        $override = 'test-inbox@corp.local'
        @{
            Name                          = '07-07: [Import] NotificationRecipientOverride -- mail redirected, real owner recorded'
            Why                           = 'During testing or piloting, all mail must go to a single inbox while the result record still shows the real owner -- confirms the override applies to delivery only.'
            NotificationRecipientOverride = $override
            Accounts                      = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN 'real-owner@corp.local' `
                    -EmailAddress 'real-owner@corp.local' -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[import] Warned = 1'
                Assert-Equal `$result.Results[0].NotificationRecipient 'real-owner@corp.local' '[import] Real owner recorded in result'
                Assert-Equal (`$ctx.Actions | Where-Object { `$_.Action -eq 'Notify' } | Select-Object -First 1).Recipient '$override' '[import] Mail sent to override address'
"@)
        }
    ),

    $(
        $sam      = 'admin.over08d'; $upn = 'admin.over08d@corp.local'; $std = 'over08d'
        $override = 'test-inbox@corp.local'
        @{
            Name                          = '07-07: [Discovery] NotificationRecipientOverride -- mail redirected, real owner recorded'
            Why                           = 'Same override behaviour exercised in discovery mode -- confirms the parameter is honoured regardless of how accounts were sourced.'
            NotificationRecipientOverride = $override
            ADAccountList                 = @(
                New-DiscoveryADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $std = New-DiscoveryOwnerADUser -SamAccountName $std -EmailAddress 'real-owner@corp.local'
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[disc] Warned = 1'
                Assert-Equal `$result.Results[0].NotificationRecipient 'real-owner@corp.local' '[disc] Real owner recorded in result'
                Assert-Equal (`$ctx.Actions | Where-Object { `$_.Action -eq 'Notify' } | Select-Object -First 1).Recipient '$override' '[disc] Mail sent to override address'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 07-09: Guard fires when neither -Accounts nor -Prefixes/-ADSearchBase supplied
    # ------------------------------------------------------------------
    @{
        Name           = '07-09: Guard fires when no source params supplied'
        Why            = 'Calling the function without specifying either input source is a programming error -- a clear exception must be thrown immediately rather than silently processing zero accounts.'
        AssertAfterRun = [scriptblock]::Create(@"
            param(`$result, `$ctx)
            `$threw = `$false
            try {
                Invoke-InactiveAccountRemediation ``
                    -MailSender 'x' -MailClientId 'x' -MailTenantId 'x' ``
                    -MailCertificateThumbprint 'x' ``
                    -UseExistingGraphSession -SkipModuleImport
            } catch {
                `$threw = `$true
            }
            Assert-True `$threw '[guard] Invoke-InactiveAccountRemediation throws when no source params supplied'
"@)
    },

    # ------------------------------------------------------------------
    # 07-10: Large mixed batch in discovery mode -- all outcome types
    # ------------------------------------------------------------------
    $(
        $samW   = 'admin.big10w';   $upnW   = 'admin.big10w@corp.local';   $stdW   = 'big10w'
        $samD   = 'admin.big10d';   $upnD   = 'admin.big10d@corp.local';   $stdD   = 'big10d'
        $samDel = 'admin.big10del'; $upnDel = 'admin.big10del@corp.local'; $stdDel = 'big10del'
        $samE   = 'admin.big10e';   $upnE   = 'admin.big10e@corp.local';   $stdE   = 'big10e'
        $samA   = 'admin.big10a';   $upnA   = 'admin.big10a@corp.local'
        $samN   = 'admin.big10n';   $upnN   = 'admin.big10n@corp.local'
        $samC   = 'admin.big10c';   $upnC   = 'admin.big10c@corp.local';   $stdC   = 'big10c'
        @{
            Name           = '07-10: [Discovery] Large mixed batch -- warn, disable, delete, error, skip(active), skip(no owner), delete(already-disabled)'
            Why            = 'Integration smoke test: every possible outcome type in a single batch, confirming they are all handled independently and the summary counters are all correct.'
            EnableDeletion = $true
            DisableFail    = @($upnE)
            ADAccountList  = @(
                New-DiscoveryADAccount -SamAccountName $samW   -UPN $upnW   -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samD   -UPN $upnD   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samDel -UPN $upnDel -LastLogonDaysAgo 180 -WhenCreatedDaysAgo 500
                New-DiscoveryADAccount -SamAccountName $samE   -UPN $upnE   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samA   -UPN $upnA   -LastLogonDaysAgo 30  -WhenCreatedDaysAgo 200
                New-DiscoveryADAccount -SamAccountName $samN   -UPN $upnN   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samC   -UPN $upnC   -LastLogonDaysAgo 200 -WhenCreatedDaysAgo 500 -Enabled $false
            )
            ADUsers        = @{
                $stdW   = New-DiscoveryOwnerADUser -SamAccountName $stdW   -EmailAddress "$stdW@corp.local"
                $stdD   = New-DiscoveryOwnerADUser -SamAccountName $stdD   -EmailAddress "$stdD@corp.local"
                $stdDel = New-DiscoveryOwnerADUser -SamAccountName $stdDel -EmailAddress "$stdDel@corp.local"
                $stdE   = New-DiscoveryOwnerADUser -SamAccountName $stdE   -EmailAddress "$stdE@corp.local"
                $stdC   = New-DiscoveryOwnerADUser -SamAccountName $stdC   -EmailAddress "$stdC@corp.local"
                # big10a below threshold (no owner needed); big10n absent -- NoOwnerFound
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True   `$result.Success       '[disc] Success = true'
                Assert-Null   `$result.Error         '[disc] No top-level error'
                Assert-SummaryField `$result.Summary 'Total'    7 '[disc] Total = 7'
                Assert-SummaryField `$result.Summary 'Warned'   1 '[disc] Warned = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[disc] Disabled = 1'
                Assert-SummaryField `$result.Summary 'Deleted'  2 '[disc] Deleted = 2 (del + already-disabled)'
                Assert-SummaryField `$result.Summary 'Errors'   1 '[disc] Errors = 1'
                Assert-SummaryField `$result.Summary 'Skipped'  2 '[disc] Skipped = 2 (activity + no-owner)'
                Assert-ResultField  `$result.Results '$upnW'   'ActionTaken' 'Notify'  '[disc] upnW = Notify'
                Assert-ResultField  `$result.Results '$upnD'   'ActionTaken' 'Disable' '[disc] upnD = Disable'
                Assert-ResultField  `$result.Results '$upnDel' 'ActionTaken' 'Delete'  '[disc] upnDel = Delete'
                Assert-ResultField  `$result.Results '$upnE'   'Status'      'Error'   '[disc] upnE = Error'
                Assert-ResultField  `$result.Results '$upnA'   'SkipReason'  'ActivityDetected' '[disc] upnA = ActivityDetected'
                Assert-ResultField  `$result.Results '$upnN'   'SkipReason'  'NoOwnerFound'     '[disc] upnN = NoOwnerFound'
                Assert-ResultField  `$result.Results '$upnC'   'ActionTaken' 'Delete'  '[disc] upnC = Delete (already-disabled)'
                Assert-ActionNotFired 'Disable' '$upnC' '[disc] Disable not called for already-disabled upnC'
"@)
        }
    )

)
