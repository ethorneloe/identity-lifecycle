$Scenarios = @(

    # ------------------------------------------------------------------
    # 05-01: Return object has all expected top-level fields
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.retobj01'; $upn = 'admin.retobj01@corp.local'; $std = 'retobj01'
        @{
            Name    = '05-01: Return object has Summary, Results, Success, Error fields'
            Accounts = @(
                New-MonthlyTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers = @{
                $sam = New-MonthlyADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-MonthlyADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-NotNull `$result         'Return value is non-null'
                Assert-NotNull `$result.Summary 'Summary field present'
                Assert-NotNull `$result.Results 'Results field present'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Success')) 'Success property exists'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Error'))   'Error property exists'
                Assert-True (`$null -eq (Get-Member -InputObject `$result -Name 'LogPath')) 'LogPath property absent'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-02: Error entries are recorded in Results when an action fails
    # ------------------------------------------------------------------
    $(
        $sam1 = 'admin.ok02a';   $upn1 = 'admin.ok02a@corp.local';   $std1 = 'ok02a'
        $sam2 = 'admin.fail02b'; $upn2 = 'admin.fail02b@corp.local'; $std2 = 'fail02b'
        @{
            Name        = '05-02: Failed accounts recorded in Results with Status=Error'
            DisableFail = @($upn2)
            Accounts    = @(
                New-MonthlyTestAccount -SamAccountName $sam1 -UPN $upn1 -InactiveDaysAgo 120
                New-MonthlyTestAccount -SamAccountName $sam2 -UPN $upn2 -InactiveDaysAgo 120
            )
            ADUsers     = @{
                $sam1 = New-MonthlyADUser -SamAccountName $sam1 -UPN $upn1 `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std1 = New-MonthlyADUser -SamAccountName $std1 -UPN "$std1@corp.local" -Enabled $true
                $sam2 = New-MonthlyADUser -SamAccountName $sam2 -UPN $upn2 `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $std2 = New-MonthlyADUser -SamAccountName $std2 -UPN "$std2@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                `$errors = @(`$result.Results | Where-Object { `$_.Status -eq 'Error' })
                Assert-Count `$errors 1 'One error entry in Results'
                Assert-Equal `$errors[0].UPN '$upn2' 'Error entry UPN = upn2'
                Assert-Equal `$errors[0].SamAccountName '$sam2' 'Error entry SAM = sam2'
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
            Name    = '05-03: Summary fields correct for mixed batch (warn, disable, skip)'
            Accounts = @(
                New-MonthlyTestAccount -SamAccountName $samW -UPN $upnW -InactiveDaysAgo 95
                New-MonthlyTestAccount -SamAccountName $samD -UPN $upnD -InactiveDaysAgo 120
                New-MonthlyTestAccount -SamAccountName $samS -UPN $upnS -InactiveDaysAgo 30
            )
            ADUsers = @{
                $samW = New-MonthlyADUser -SamAccountName $samW -UPN $upnW `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95))  -WhenCreatedDaysAgo 300 -Enabled $true
                $stdW = New-MonthlyADUser -SamAccountName $stdW -UPN "$stdW@corp.local" -Enabled $true
                $samD = New-MonthlyADUser -SamAccountName $samD -UPN $upnD `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdD = New-MonthlyADUser -SamAccountName $stdD -UPN "$stdD@corp.local" -Enabled $true
                $samS = New-MonthlyADUser -SamAccountName $samS -UPN $upnS `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-30))  -WhenCreatedDaysAgo 300 -Enabled $true
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
    #   upnW   -- 95 days,  owner found → Warned   (Completed)
    #   upnD   -- 120 days, owner found → Disabled (Completed)
    #   upnDel -- 180 days, owner found, EnableDeletion ON → Deleted (Completed)
    #   upnE   -- 120 days, owner found, disable mock fails → Error
    #   upnA   -- 30 days,  (below threshold) → Skipped/ActivityDetected
    #   upnN   -- 120 days, no owner found → Skipped/NoOwnerFound
    #   upnX   -- exported enabled, now disabled in AD → Skipped/DisabledSinceExport
    # ------------------------------------------------------------------
    $(
        $samW   = 'admin.big04w';   $upnW   = 'admin.big04w@corp.local';   $stdW   = 'big04w'
        $samD   = 'admin.big04d';   $upnD   = 'admin.big04d@corp.local';   $stdD   = 'big04d'
        $samDel = 'admin.big04del'; $upnDel = 'admin.big04del@corp.local'; $stdDel = 'big04del'
        $samE   = 'admin.big04e';   $upnE   = 'admin.big04e@corp.local';   $stdE   = 'big04e'
        $samA   = 'admin.big04a';   $upnA   = 'admin.big04a@corp.local'
        $samN   = 'admin.big04n';   $upnN   = 'admin.big04n@corp.local'
        $samX   = 'admin.big04x';   $upnX   = 'admin.big04x@corp.local'
        @{
            Name           = '05-04: Large mixed batch -- warn, disable, delete, error, skip(active), skip(no owner), skip(disabled since export)'
            EnableDeletion = $true
            DisableFail    = @($upnE)
            Accounts       = @(
                New-MonthlyTestAccount -SamAccountName $samW   -UPN $upnW   -InactiveDaysAgo 95
                New-MonthlyTestAccount -SamAccountName $samD   -UPN $upnD   -InactiveDaysAgo 120
                New-MonthlyTestAccount -SamAccountName $samDel -UPN $upnDel -InactiveDaysAgo 180
                New-MonthlyTestAccount -SamAccountName $samE   -UPN $upnE   -InactiveDaysAgo 120
                New-MonthlyTestAccount -SamAccountName $samA   -UPN $upnA   -InactiveDaysAgo 30
                New-MonthlyTestAccount -SamAccountName $samN   -UPN $upnN   -InactiveDaysAgo 120
                New-MonthlyTestAccount -SamAccountName $samX   -UPN $upnX   -InactiveDaysAgo 150 -AccountEnabled $true
            )
            ADUsers        = @{
                $samW   = New-MonthlyADUser -SamAccountName $samW   -UPN $upnW   -LastLogonDate ([datetime]::UtcNow.AddDays(-95))  -WhenCreatedDaysAgo 300 -Enabled $true
                $stdW   = New-MonthlyADUser -SamAccountName $stdW   -UPN "$stdW@corp.local"  -Enabled $true
                $samD   = New-MonthlyADUser -SamAccountName $samD   -UPN $upnD   -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdD   = New-MonthlyADUser -SamAccountName $stdD   -UPN "$stdD@corp.local"  -Enabled $true
                $samDel = New-MonthlyADUser -SamAccountName $samDel -UPN $upnDel -LastLogonDate ([datetime]::UtcNow.AddDays(-180)) -WhenCreatedDaysAgo 500 -Enabled $true
                $stdDel = New-MonthlyADUser -SamAccountName $stdDel -UPN "$stdDel@corp.local" -Enabled $true
                $samE   = New-MonthlyADUser -SamAccountName $samE   -UPN $upnE   -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdE   = New-MonthlyADUser -SamAccountName $stdE   -UPN "$stdE@corp.local"  -Enabled $true
                $samA   = New-MonthlyADUser -SamAccountName $samA   -UPN $upnA   -LastLogonDate ([datetime]::UtcNow.AddDays(-30))  -WhenCreatedDaysAgo 200 -Enabled $true
                $samN   = New-MonthlyADUser -SamAccountName $samN   -UPN $upnN   -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                # big04n strips to 'big04n' -- not in mock → NoOwnerFound
                $samX   = New-MonthlyADUser -SamAccountName $samX   -UPN $upnX   -LastLogonDate ([datetime]::UtcNow.AddDays(-150)) -WhenCreatedDaysAgo 300 -Enabled $false
                # big04x: export said Enabled=true, live AD says Enabled=false → DisabledSinceExport
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True   `$result.Success       'Success = true (all accounts processed, errors recorded per-entry)'
                Assert-Null   `$result.Error         'Top-level Error = null'
                Assert-SummaryField `$result.Summary 'Total'    7 'Total = 7'
                Assert-SummaryField `$result.Summary 'Warned'   1 'Warned = 1 (upnW)'
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1 (upnD)'
                Assert-SummaryField `$result.Summary 'Deleted'  1 'Deleted = 1 (upnDel)'
                Assert-SummaryField `$result.Summary 'Errors'   1 'Errors = 1 (upnE disable failed)'
                Assert-SummaryField `$result.Summary 'Skipped'  3 'Skipped = 3 (upnA activity + upnN no owner + upnX disabled since export)'
                Assert-SummaryField `$result.Summary 'NoOwner'  1 'NoOwner = 1 (upnN)'
                Assert-ResultField  `$result.Results '$upnW'   'Status'      'Completed'       'upnW = Completed'
                Assert-ResultField  `$result.Results '$upnW'   'ActionTaken' 'Notify'          'upnW = Notify'
                Assert-ResultField  `$result.Results '$upnD'   'Status'      'Completed'       'upnD = Completed'
                Assert-ResultField  `$result.Results '$upnD'   'ActionTaken' 'Disable'         'upnD = Disable'
                Assert-ResultField  `$result.Results '$upnDel' 'Status'      'Completed'       'upnDel = Completed'
                Assert-ResultField  `$result.Results '$upnDel' 'ActionTaken' 'Delete'          'upnDel = Delete'
                Assert-ResultField  `$result.Results '$upnE'   'Status'      'Error'           'upnE = Error'
                Assert-ResultField  `$result.Results '$upnA'   'Status'      'Skipped'         'upnA = Skipped'
                Assert-ResultField  `$result.Results '$upnA'   'SkipReason'  'ActivityDetected' 'upnA = ActivityDetected'
                Assert-ResultField  `$result.Results '$upnN'   'Status'      'Skipped'         'upnN = Skipped'
                Assert-ResultField  `$result.Results '$upnN'   'SkipReason'  'NoOwnerFound'    'upnN = NoOwnerFound'
                Assert-ResultField  `$result.Results '$upnX'   'Status'      'Skipped'         'upnX = Skipped'
                Assert-ResultField  `$result.Results '$upnX'   'SkipReason'  'DisabledSinceExport' 'upnX = DisabledSinceExport'
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
            Accounts = @(
                New-MonthlyTestAccount -SamAccountName $samW -UPN $upnW -InactiveDaysAgo 95
                New-MonthlyTestAccount -SamAccountName $samD -UPN $upnD -InactiveDaysAgo 120
            )
            ADUsers = @{
                $samW = New-MonthlyADUser -SamAccountName $samW -UPN $upnW `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95))  -WhenCreatedDaysAgo 300 -Enabled $true
                $stdW = New-MonthlyADUser -SamAccountName $stdW -UPN "$stdW@corp.local" -Enabled $true
                $samD = New-MonthlyADUser -SamAccountName $samD -UPN $upnD `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdD = New-MonthlyADUser -SamAccountName $stdD -UPN "$stdD@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True  `$result.Success                   'Success = true under WhatIf'
                Assert-Null  `$result.Error                     'No top-level error under WhatIf'
                Assert-Count `$result.Results 2                 'Both accounts produce a result entry'
                Assert-ResultField `$result.Results '$upnW' 'ActionTaken' 'Notify'    'upnW ActionTaken = Notify'
                Assert-ResultField `$result.Results '$upnW' 'Status'      'Completed' 'upnW Status = Completed'
                Assert-ResultField `$result.Results '$upnD' 'ActionTaken' 'Disable'   'upnD ActionTaken = Disable'
                Assert-ResultField `$result.Results '$upnD' 'Status'      'Completed' 'upnD Status = Completed'
                Assert-ActionNotFired 'Notify'  `$null 'Send-GraphMail not called under WhatIf'
                Assert-ActionNotFired 'Disable' `$null 'Disable-InactiveAccount not called under WhatIf'
"@)
        }
    )

)
