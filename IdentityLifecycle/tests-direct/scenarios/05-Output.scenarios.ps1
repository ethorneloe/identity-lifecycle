$Scenarios = @(

    # ------------------------------------------------------------------
    # 05-01: Return object has all expected top-level fields
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.retobj01'; $upn = 'admin.retobj01@corp.local'; $std = 'retobj01'
        @{
            Name     = '05-01: Return object has Summary, Results, Success, Error fields'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-NotNull `$result         'Return value is non-null'
                Assert-NotNull `$result.Summary 'Summary field present'
                Assert-NotNull `$result.Results 'Results field present'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Success')) 'Success property exists'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Error'))   'Error property exists'
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
                New-DirectADAccount -SamAccountName $sam1 -UPN $upn1 -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $sam2 -UPN $upn2 -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers     = @{
                $std1 = New-DirectOwnerADUser -SamAccountName $std1 -EmailAddress "$std1@corp.local"
                $std2 = New-DirectOwnerADUser -SamAccountName $std2 -EmailAddress "$std2@corp.local"
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
                New-DirectADAccount -SamAccountName $samW -UPN $upnW -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $samS -UPN $upnS -LastLogonDaysAgo 30  -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $stdW = New-DirectOwnerADUser -SamAccountName $stdW -EmailAddress "$stdW@corp.local"
                $stdD = New-DirectOwnerADUser -SamAccountName $stdD -EmailAddress "$stdD@corp.local"
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
                New-DirectADAccount -SamAccountName $samW   -UPN $upnW   -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $samD   -UPN $upnD   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $samDel -UPN $upnDel -LastLogonDaysAgo 180 -WhenCreatedDaysAgo 500
                New-DirectADAccount -SamAccountName $samE   -UPN $upnE   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $samA   -UPN $upnA   -LastLogonDaysAgo 30  -WhenCreatedDaysAgo 200
                New-DirectADAccount -SamAccountName $samN   -UPN $upnN   -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $samC   -UPN $upnC   -LastLogonDaysAgo 200 -WhenCreatedDaysAgo 500 -Enabled $false
            )
            ADUsers        = @{
                $stdW   = New-DirectOwnerADUser -SamAccountName $stdW   -EmailAddress "$stdW@corp.local"
                $stdD   = New-DirectOwnerADUser -SamAccountName $stdD   -EmailAddress "$stdD@corp.local"
                $stdDel = New-DirectOwnerADUser -SamAccountName $stdDel -EmailAddress "$stdDel@corp.local"
                $stdE   = New-DirectOwnerADUser -SamAccountName $stdE   -EmailAddress "$stdE@corp.local"
                $stdC   = New-DirectOwnerADUser -SamAccountName $stdC   -EmailAddress "$stdC@corp.local"
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
                New-DirectADAccount -SamAccountName $samW -UPN $upnW -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $stdW = New-DirectOwnerADUser -SamAccountName $stdW -EmailAddress "$stdW@corp.local"
                $stdD = New-DirectOwnerADUser -SamAccountName $stdD -EmailAddress "$stdD@corp.local"
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
    )

)
