$Scenarios = @(

    # ------------------------------------------------------------------
    # 02-01: No UPN -- row silently discarded, not in Results
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.noupn01'
        @{
            Name     = '02-01: [Import] Row with no UPN silently discarded'
            Why      = 'UPN is the identity key for all downstream actions; a row without one cannot be safely processed and must be skipped with a clear reason.'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName      = $sam
                    UserPrincipalName   = ''
                    LastLogonDate       = ''
                    Created             = [datetime]::UtcNow.AddDays(-200).ToString('o')
                    Enabled             = 'True'
                    EntraObjectId       = ''
                    entraLastSignInAEST = ''
                    Description         = ''
                }
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN '' -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True  `$result.Success                '[import] Success = true with no-UPN row'
                Assert-Count `$result.Results 1              '[import] One result entry (Skipped/NoUPN)'
                Assert-Equal `$result.Results[0].SkipReason 'NoUPN' '[import] SkipReason = NoUPN'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-02: AD live check -- account is active (recent logon) -- ActivityDetected
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.live02'; $upn = 'admin.live02@corp.local'; $std = 'live02'
        @{
            Name     = '02-02: [Import] AD live check -- account is active -- ActivityDetected'
            Why      = 'The CSV export may be hours old; the live AD check prevents acting on an account that has since logged in.'
            Accounts = @(
                # Export says 150 days inactive; live AD says 10 days
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 150
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-10)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[import] Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' '[import] SkipReason = ActivityDetected (live logon 10d)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-03: DisabledSinceExport (AD) -- export=Enabled, live=Disabled -- skip
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.dse03'; $upn = 'admin.dse03@corp.local'
        @{
            Name     = '02-03: [Import] DisabledSinceExport -- export=Enabled, live AD=Disabled'
            Why      = 'An account disabled between export and run should not be processed again -- prevents double-action on accounts another process already handled.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 120 -AccountEnabled $true
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $false
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[import] Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'DisabledSinceExport' '[import] SkipReason = DisabledSinceExport'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-04: DisabledSinceExport (Entra-native) -- export=Enabled, live Entra=Disabled
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString()
        $upn = 'cloud.dse04@corp.local'
        @{
            Name     = '02-04: [Import] DisabledSinceExport -- Entra-native, export=Enabled, live=Disabled'
            Why      = 'Same DisabledSinceExport guard applied to cloud-native accounts -- live Entra state takes precedence over the exported snapshot.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName '' -UPN $upn -InactiveDaysAgo 120 `
                    -AccountEnabled $true -EntraObjectId $oid
            )
            MgUsers  = @{
                $oid = New-ImportMgUser -ObjectId $oid -AccountEnabled $false -LastSignInDaysAgo 120
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[import] Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'DisabledSinceExport' '[import] SkipReason = DisabledSinceExport (Entra)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-05: AD live check fails (Get-ADUser throws) -- Error in Results
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.fail05'; $upn = 'admin.fail05@corp.local'
        @{
            Name     = '02-05: [Import] AD live check failure -- Status=Error'
            Why      = 'A live check failure is recorded per-account so the batch continues and the account lands in Unprocessed for retry.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 120
            )
            # $sam not in ADUsers -- Get-ADUser throws -- Error
            ADUsers  = @{}
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True  `$result.Success '[import] Success = true (errors recorded per-entry)'
                Assert-Count `$result.Results 1 '[import] One result entry'
                Assert-ResultField `$result.Results '$upn' 'Status' 'Error' '[import] Status = Error on live check failure'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-06: No SAM and no EntraObjectId -- Error in Results (cannot do live check)
    # ------------------------------------------------------------------
    $(
        $upn = 'cloud.nosam06@corp.local'
        @{
            Name     = '02-06: [Import] No SAM and no EntraObjectId -- Status=Error'
            Why      = 'Without a SAM or EntraObjectId the live check cannot be performed -- the row must be flagged as an error rather than silently skipped.'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName      = ''
                    UserPrincipalName   = $upn
                    LastLogonDate       = ''
                    Created             = [datetime]::UtcNow.AddDays(-200).ToString('o')
                    Enabled             = 'True'
                    EntraObjectId       = ''
                    entraLastSignInAEST = ''
                    Description         = ''
                }
            )
            ADUsers  = @{}
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-Count `$result.Results 1 '[import] One result entry'
                Assert-ResultField `$result.Results '$upn' 'Status' 'Error' '[import] Status = Error for no SAM + no EntraObjectId'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-07: Import mode -- no live data change, threshold still applied correctly
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.imp07'; $upn = 'admin.imp07@corp.local'; $std = 'imp07'
        @{
            Name     = '02-07: [Import] Account at warn threshold confirmed live -- Warned'
            Why      = 'Validates the full import path end-to-end: live check confirms inactivity, threshold routing fires, notification is sent.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[import] Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Notify'    '[import] ActionTaken = Notify'
                Assert-ResultField  `$result.Results '$upn' 'Status'      'Completed' '[import] Status = Completed'
                Assert-ActionFired 'Notify' '$upn' '[import] Send-GraphMail called for warn'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-08: Import mode -- Entra-native with live sign-in data, inactive -- Warn
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString()
        $upn = 'cloud.entra08@corp.local'
        @{
            Name     = '02-08: [Import] Entra-native inactive -- Warn via sponsor'
            Why      = 'Cloud-native accounts have no AD SAM; this confirms the Entra live-check and sponsor notification path works in import mode.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName '' -UPN $upn -InactiveDaysAgo 95 `
                    -AccountEnabled $true -EntraObjectId $oid
            )
            MgUsers  = @{
                $oid = New-ImportMgUser -ObjectId $oid -AccountEnabled $true -LastSignInDaysAgo 95
            }
            MgUserSponsors = @{
                $oid = @([pscustomobject]@{ Mail = 'sponsor@corp.local'; UserPrincipalName = 'sponsor@corp.local' })
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[import] Warned = 1 (Entra-native)'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Notify'    '[import] ActionTaken = Notify'
                Assert-ResultField  `$result.Results '$upn' 'Status'      'Completed' '[import] Status = Completed'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-09: Import mode WhatIf -- Results populated, no actions fired
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.wi09'; $upn = 'admin.wi09@corp.local'; $std = 'wi09'
        @{
            Name     = '02-09: [Import] WhatIf -- Results populated, no actions fired'
            Why      = 'WhatIf is the safe dry-run gate before a live sweep; results must be fully populated so operators can review the plan without any accounts being touched.'
            WhatIf   = $true
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers  = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True  `$result.Success                   '[import] Success = true under WhatIf'
                Assert-Count `$result.Results 1                 '[import] One result entry under WhatIf'
                Assert-ResultField `$result.Results '$upn' 'Status'      'Completed' '[import] Status = Completed under WhatIf'
                Assert-ResultField `$result.Results '$upn' 'ActionTaken' 'Notify'    '[import] ActionTaken = Notify under WhatIf'
                Assert-ActionNotFired 'Notify' `$null '[import] Send-GraphMail not called under WhatIf'
"@)
        }
    )

)
