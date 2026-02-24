$Scenarios = @(

    # ------------------------------------------------------------------
    # 05-01: Return object has all expected top-level fields
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.retobj01'; $upn = 'admin.retobj01@corp.local'; $std = 'retobj01'
        @{
            Name     = '05-01: Return object has Summary, Results, Success, Error fields'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $std = New-RemediationOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-NotNull `$result         'Return value is non-null'
                Assert-NotNull `$result.Summary 'Summary field present'
                Assert-NotNull `$result.Results 'Results field present'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Success'))     'Success property exists'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Error'))       'Error property exists'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Unprocessed')) 'Unprocessed property exists'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-02: Failed accounts recorded in Results with Status=Error
    # ------------------------------------------------------------------
    $(
        $sam1 = 'admin.ok02a';   $upn1 = 'admin.ok02a@corp.local';   $std1 = 'ok02a'
        $sam2 = 'admin.fail02b'; $upn2 = 'admin.fail02b@corp.local'; $std2 = 'fail02b'
        @{
            Name        = '05-02: Failed accounts recorded in Results with Status=Error'
            DisableFail = @($upn2)
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam1 -UPN $upn1 -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $sam2 -UPN $upn2 -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers     = @{
                $std1 = New-RemediationOwnerADUser -SamAccountName $std1 -EmailAddress "$std1@corp.local"
                $std2 = New-RemediationOwnerADUser -SamAccountName $std2 -EmailAddress "$std2@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                `$errors = @(`$result.Results | Where-Object { `$_.Status -eq 'Error' })
                Assert-Count `$errors 1 'One error entry in Results'
                Assert-Equal `$errors[0].UPN '$upn2' 'Error entry UPN = upn2'
                Assert-SummaryField `$result.Summary 'Errors' 1 'Summary.Errors = 1'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-03: Summary fields correctly tallied across a mixed batch
    # ------------------------------------------------------------------
    $(
        $samW = 'admin.sum03w'; $upnW = 'admin.sum03w@corp.local'; $stdW = 'sum03w'
        $samD = 'admin.sum03d'; $upnD = 'admin.sum03d@corp.local'; $stdD = 'sum03d'
        $samS = 'admin.sum03s'; $upnS = 'admin.sum03s@corp.local'
        @{
            Name     = '05-03: Summary fields correct for mixed batch (warn, disable, skip)'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $samW -UPN $upnW -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samS -UPN $upnS -LastLogonDaysAgo 30  -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $stdW = New-RemediationOwnerADUser -SamAccountName $stdW -EmailAddress "$stdW@corp.local"
                $stdD = New-RemediationOwnerADUser -SamAccountName $stdD -EmailAddress "$stdD@corp.local"
                # sum03s strips to 'sum03s' -- not in mock, so owner not found → NoOwnerFound skip
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Total'    3 'Total = 3'
                Assert-SummaryField `$result.Summary 'Warned'   1 'Warned = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-SummaryField `$result.Summary 'Skipped'  1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'Errors'   0 'Errors = 0'
                Assert-SummaryField `$result.Summary 'Deleted'  0 'Deleted = 0'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-04: Large mixed batch -- all outcome types in a single run
    #
    # 7 accounts processed:
    #   upnW   -- 95 days,  owner found  → Warned   (Completed)
    #   upnD   -- 120 days, owner found  → Disabled (Completed)
    #   upnDel -- 180 days, owner found, EnableDeletion ON → Deleted (Completed)
    #   upnE   -- 120 days, owner found, disable mock fails → Error
    #   upnA   -- 30 days,  (below threshold) → Skipped/ActivityDetected
    #   upnN   -- 120 days, no owner found → Skipped/NoOwnerFound
    #   upnC   -- 200 days, already disabled, EnableDeletion ON → Deleted (Completed)
    # ------------------------------------------------------------------
    $(
        $samW   = 'admin.big04w';   $upnW   = 'admin.big04w@corp.local';   $stdW   = 'big04w'
        $samD   = 'admin.big04d';   $upnD   = 'admin.big04d@corp.local';   $stdD   = 'big04d'
        $samDel = 'admin.big04del'; $upnDel = 'admin.big04del@corp.local'; $stdDel = 'big04del'
        $samE   = 'admin.big04e';   $upnE   = 'admin.big04e@corp.local';   $stdE   = 'big04e'
        $samA   = 'admin.big04a';   $upnA   = 'admin.big04a@corp.local'
        $samN   = 'admin.big04n';   $upnN   = 'admin.big04n@corp.local'
        $samC   = 'admin.big04c';   $upnC   = 'admin.big04c@corp.local';   $stdC   = 'big04c'
        @{
            Name           = '05-04: Large mixed batch -- warn, disable, delete, error, skip(active), skip(no owner), delete(already disabled)'
            EnableDeletion = $true
            DisableFail    = @($upnE)
            ADAccountList  = @(
                New-RemediationADAccount -SamAccountName $samW   -UPN $upnW   -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samD   -UPN $upnD   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samDel -UPN $upnDel -LastLogonDaysAgo 180 -WhenCreatedDaysAgo 500
                New-RemediationADAccount -SamAccountName $samE   -UPN $upnE   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samA   -UPN $upnA   -LastLogonDaysAgo 30  -WhenCreatedDaysAgo 200
                New-RemediationADAccount -SamAccountName $samN   -UPN $upnN   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samC   -UPN $upnC   -LastLogonDaysAgo 200 -WhenCreatedDaysAgo 500 -Enabled $false
            )
            ADUsers        = @{
                $stdW   = New-RemediationOwnerADUser -SamAccountName $stdW   -EmailAddress "$stdW@corp.local"
                $stdD   = New-RemediationOwnerADUser -SamAccountName $stdD   -EmailAddress "$stdD@corp.local"
                $stdDel = New-RemediationOwnerADUser -SamAccountName $stdDel -EmailAddress "$stdDel@corp.local"
                $stdE   = New-RemediationOwnerADUser -SamAccountName $stdE   -EmailAddress "$stdE@corp.local"
                $stdC   = New-RemediationOwnerADUser -SamAccountName $stdC   -EmailAddress "$stdC@corp.local"
                # big04a and big04n not in ADUsers: big04a is below threshold so owner never looked up;
                # big04n strips to 'big04n' -- not in mock → NoOwnerFound
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True   `$result.Success       'Success = true (all accounts processed, errors recorded per-entry)'
                Assert-Null   `$result.Error         'Top-level Error = null'
                Assert-SummaryField `$result.Summary 'Total'    7 'Total = 7'
                Assert-SummaryField `$result.Summary 'Warned'   1 'Warned = 1 (upnW)'
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1 (upnD)'
                Assert-SummaryField `$result.Summary 'Deleted'  2 'Deleted = 2 (upnDel + upnC already-disabled)'
                Assert-SummaryField `$result.Summary 'Errors'   1 'Errors = 1 (upnE disable failed)'
                Assert-SummaryField `$result.Summary 'Skipped'  2 'Skipped = 2 (upnA activity + upnN no owner)'
                Assert-SummaryField `$result.Summary 'NoOwner'  1 'NoOwner = 1 (upnN)'
                Assert-ResultField  `$result.Results '$upnW'   'Status'     'Completed' 'upnW = Completed'
                Assert-ResultField  `$result.Results '$upnW'   'ActionTaken' 'Notify'   'upnW = Notify'
                Assert-ResultField  `$result.Results '$upnD'   'Status'     'Completed' 'upnD = Completed'
                Assert-ResultField  `$result.Results '$upnD'   'ActionTaken' 'Disable'  'upnD = Disable'
                Assert-ResultField  `$result.Results '$upnDel' 'Status'     'Completed' 'upnDel = Completed'
                Assert-ResultField  `$result.Results '$upnDel' 'ActionTaken' 'Delete'   'upnDel = Delete'
                Assert-ResultField  `$result.Results '$upnE'   'Status'     'Error'     'upnE = Error'
                Assert-ResultField  `$result.Results '$upnA'   'Status'     'Skipped'   'upnA = Skipped'
                Assert-ResultField  `$result.Results '$upnA'   'SkipReason' 'ActivityDetected' 'upnA = ActivityDetected'
                Assert-ResultField  `$result.Results '$upnN'   'Status'     'Skipped'   'upnN = Skipped'
                Assert-ResultField  `$result.Results '$upnN'   'SkipReason' 'NoOwnerFound' 'upnN = NoOwnerFound'
                Assert-ResultField  `$result.Results '$upnC'   'Status'     'Completed' 'upnC = Completed'
                Assert-ResultField  `$result.Results '$upnC'   'ActionTaken' 'Delete'   'upnC = Delete'
                Assert-ActionNotFired 'Disable' '$upnC' 'Disable not called for already-disabled upnC'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-05: -WhatIf produces fully populated Results with no actions fired
    #
    # Two accounts (warn + disable) run with -WhatIf. Results should be
    # fully populated with the expected ActionTaken values and Status=Completed,
    # but no Notify or Disable action should have fired against the mocks.
    # ------------------------------------------------------------------
    $(
        $samW = 'admin.wi05w'; $upnW = 'admin.wi05w@corp.local'; $stdW = 'wi05w'
        $samD = 'admin.wi05d'; $upnD = 'admin.wi05d@corp.local'; $stdD = 'wi05d'
        @{
            Name   = '05-05: -WhatIf -- Results populated, no actions fired'
            WhatIf = $true
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $samW -UPN $upnW -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $stdW = New-RemediationOwnerADUser -SamAccountName $stdW -EmailAddress "$stdW@corp.local"
                $stdD = New-RemediationOwnerADUser -SamAccountName $stdD -EmailAddress "$stdD@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True  `$result.Success                   'Success = true under WhatIf'
                Assert-Null  `$result.Error                     'No top-level error under WhatIf'
                Assert-Count `$result.Results 2                 'Both accounts produce a result entry'
                Assert-ResultField `$result.Results '$upnW' 'ActionTaken' 'Notify'   'upnW ActionTaken = Notify'
                Assert-ResultField `$result.Results '$upnW' 'Status'      'Completed' 'upnW Status = Completed'
                Assert-ResultField `$result.Results '$upnD' 'ActionTaken' 'Disable'  'upnD ActionTaken = Disable'
                Assert-ResultField `$result.Results '$upnD' 'Status'      'Completed' 'upnD Status = Completed'
                Assert-ActionNotFired 'Notify'  `$null 'Send-GraphMail not called under WhatIf'
                Assert-ActionNotFired 'Disable' `$null 'Disable-InactiveAccount not called under WhatIf'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-06: Unprocessed is empty when all accounts complete successfully
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.unp06a'; $upn = 'admin.unp06a@corp.local'; $std = 'unp06a'
        @{
            Name     = '05-06: Unprocessed is empty when all accounts Completed'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $std = New-RemediationOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Unprocessed')) 'Unprocessed property exists'
                Assert-Count @(`$result.Unprocessed) 0 'Unprocessed is empty when all accounts Completed'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-07: Unprocessed contains error accounts in import-contract shape
    #
    # Two accounts: one succeeds (Completed), one fails the disable action
    # (Error). The failed account should appear in Unprocessed with all
    # eight import-contract fields present and UPN/SAM matching.
    # ------------------------------------------------------------------
    $(
        $samOk  = 'admin.unp07ok';  $upnOk  = 'admin.unp07ok@corp.local';  $stdOk  = 'unp07ok'
        $samErr = 'admin.unp07err'; $upnErr = 'admin.unp07err@corp.local'; $stdErr = 'unp07err'
        @{
            Name        = '05-07: Unprocessed contains error accounts in import-contract shape'
            DisableFail = @($upnErr)
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $samOk  -UPN $upnOk  -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samErr -UPN $upnErr -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers     = @{
                $stdOk  = New-RemediationOwnerADUser -SamAccountName $stdOk  -EmailAddress "$stdOk@corp.local"
                $stdErr = New-RemediationOwnerADUser -SamAccountName $stdErr -EmailAddress "$stdErr@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-Count @(`$result.Unprocessed) 1 'Unprocessed has one entry (the error account)'
                `$u = `$result.Unprocessed[0]
                Assert-Equal `$u.UserPrincipalName '$upnErr' 'Unprocessed[0].UserPrincipalName = upnErr'
                Assert-Equal `$u.SamAccountName   '$samErr' 'Unprocessed[0].SamAccountName = samErr'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Enabled'))             'Unprocessed row has Enabled field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'LastLogonDate'))       'Unprocessed row has LastLogonDate field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Created'))             'Unprocessed row has Created field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'EntraObjectId'))       'Unprocessed row has EntraObjectId field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'entraLastSignInAEST')) 'Unprocessed row has entraLastSignInAEST field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Description'))         'Unprocessed row has Description field'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-08: Unprocessed re-run -- feeding result.Unprocessed into the
    #        import function succeeds on the second attempt
    #
    # Run 1 (direct sweep): two accounts, one fails the disable action.
    #        result1.Unprocessed contains the failed account in import-
    #        contract shape.
    # Run 2 (import sweep): clear DisableFail, feed result1.Unprocessed
    #        directly to Invoke-AccountInactivityRemediationWithImport.
    #        result2 should have 1 Completed, 0 Unprocessed.
    # ------------------------------------------------------------------
    $(
        $samOk  = 'admin.rerun08ok';  $upnOk  = 'admin.rerun08ok@corp.local';  $stdOk  = 'rerun08ok'
        $samErr = 'admin.rerun08err'; $upnErr = 'admin.rerun08err@corp.local'; $stdErr = 'rerun08err'
        $adUsersMap = @{
            $stdOk  = New-RemediationOwnerADUser -SamAccountName $stdOk  -EmailAddress "$stdOk@corp.local"
            $stdErr = New-RemediationOwnerADUser -SamAccountName $stdErr -EmailAddress "$stdErr@corp.local"
        }
        # Also need live-check ADUser entries for the import function's Get-ADUser call.
        # New-MonthlyADUser produces the right shape (SamAccountName, LastLogonDate, Enabled, etc.).
        # Live-check entries for the import function's Get-ADUser call.
        # New-RemediationOwnerADUser produces the right shape; supply a real LastLogonDate
        # so the import function's inactivity calculation lands at ~120 days.
        $liveDate = [datetime]::UtcNow.AddDays(-120)
        foreach ($entry in @(
            [pscustomobject]@{ Sam = $samOk;  UPN = $upnOk  }
            [pscustomobject]@{ Sam = $samErr; UPN = $upnErr }
        )) {
            $adUsersMap[$entry.Sam] = [pscustomobject]@{
                SamAccountName       = $entry.Sam
                UserPrincipalName    = $entry.UPN
                Enabled              = $true
                LastLogonDate        = $liveDate
                whenCreated          = [datetime]::UtcNow.AddDays(-300)
                extensionAttribute14 = ''
                Description          = ''
                EmailAddress         = $entry.UPN
            }
        }
        @{
            Name        = '05-08: Unprocessed re-run -- direct sweep Unprocessed fed into import sweep succeeds'
            DisableFail = @($upnErr)
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $samOk  -UPN $upnOk  -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-RemediationADAccount -SamAccountName $samErr -UPN $upnErr -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers     = $adUsersMap
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result1, `$ctx)

                # --- Run 1 sanity ---
                Assert-Count @(`$result1.Unprocessed) 1 '[run1] Unprocessed has 1 entry after disable failure'
                Assert-Equal `$result1.Unprocessed[0].UserPrincipalName '$upnErr' '[run1] Unprocessed[0] is the failed account'

                # --- Prepare run 2: clear the failure, reset actions ---
                # Set-DirectMocks installed Disable-InactiveAccount last; it reads DirectMockCtx.
                # Clearing DisableFail here is sufficient for both the direct and import calls.
                `$ctx.DisableFail = @()
                `$ctx.Actions     = [System.Collections.Generic.List[pscustomobject]]::new()

                `$result2 = Invoke-AccountInactivityRemediationWithImport ``
                    -Accounts          `$result1.Unprocessed ``
                    -Sender            'iam-automation@corp.local' ``
                    -SkipModuleImport ``
                    -UseExistingGraphSession ``
                    -Confirm:`$false ``
                    -WarningAction SilentlyContinue

                # --- Run 2 assertions ---
                Assert-True  `$result2.Success                          '[run2] Success = true'
                Assert-Null  `$result2.Error                            '[run2] No top-level error'
                Assert-Count @(`$result2.Results) 1                     '[run2] Results has 1 entry'
                Assert-ResultField `$result2.Results '$upnErr' 'Status' 'Completed' '[run2] previously-failed account now Completed'
                Assert-Count @(`$result2.Unprocessed) 0                 '[run2] Unprocessed is empty after successful re-run'
"@)
        }
    )

)
