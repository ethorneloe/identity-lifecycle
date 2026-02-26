$Scenarios = @(

    # ------------------------------------------------------------------
    # 06-01: Return object has all expected top-level fields [import]
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.retobj01i'; $upn = 'admin.retobj01i@corp.local'; $std = 'retobj01i'
        @{
            Name     = '06-01: [Import] Return object has Summary, Results, Success, Error, Unprocessed fields'
            Why      = 'The return contract is the interface callers depend on -- all fields must always be present, even when unused, so downstream scripts do not need defensive null checks.'
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
                Assert-NotNull `$result         '[import] Return value is non-null'
                Assert-NotNull `$result.Summary '[import] Summary field present'
                Assert-NotNull `$result.Results '[import] Results field present'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Success'))     '[import] Success property exists'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Error'))       '[import] Error property exists'
                Assert-True (`$null -ne (Get-Member -InputObject `$result -Name 'Unprocessed')) '[import] Unprocessed property exists'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-03: Summary fields correctly tallied [discovery]
    # ------------------------------------------------------------------
    $(
        $samW = 'admin.sum03wd'; $upnW = 'admin.sum03wd@corp.local'; $stdW = 'sum03wd'
        $samD = 'admin.sum03dd'; $upnD = 'admin.sum03dd@corp.local'; $stdD = 'sum03dd'
        $samS = 'admin.sum03sd'; $upnS = 'admin.sum03sd@corp.local'
        @{
            Name          = '06-03: [Discovery] Summary fields correct for mixed batch (warn, disable, skip)'
            Why           = 'The summary counters are the primary output operators act on -- each outcome type must be tallied accurately across a mixed batch.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $samW -UPN $upnW -LastLogonDaysAgo 95  -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samS -UPN $upnS -LastLogonDaysAgo 30  -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $stdW = New-DiscoveryOwnerADUser -SamAccountName $stdW -EmailAddress "$stdW@corp.local"
                $stdD = New-DiscoveryOwnerADUser -SamAccountName $stdD -EmailAddress "$stdD@corp.local"
                # sum03sd strips to 'sum03sd' not in map -- but 30d < WarnThreshold -- ActivityDetected first
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Total'    3 '[disc] Total = 3'
                Assert-SummaryField `$result.Summary 'Warned'   1 '[disc] Warned = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[disc] Disabled = 1'
                Assert-SummaryField `$result.Summary 'Skipped'  1 '[disc] Skipped = 1 (30d activity)'
                Assert-SummaryField `$result.Summary 'Errors'   0 '[disc] Errors = 0'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-05: WhatIf -- Results populated, no actions fired [import]
    # ------------------------------------------------------------------
    $(
        $samW = 'admin.wi05wi'; $upnW = 'admin.wi05wi@corp.local'; $stdW = 'wi05wi'
        $samD = 'admin.wi05di'; $upnD = 'admin.wi05di@corp.local'; $stdD = 'wi05di'
        @{
            Name     = '06-05: [Import] WhatIf -- Results populated, no actions fired'
            Why      = 'WhatIf is the safe pre-flight check -- result entries must be fully populated so operators can review the planned actions, but no mocked functions must be called.'
            WhatIf   = $true
            Accounts = @(
                New-ImportTestAccount -SamAccountName $samW -UPN $upnW -InactiveDaysAgo 95
                New-ImportTestAccount -SamAccountName $samD -UPN $upnD -InactiveDaysAgo 120
            )
            ADUsers  = @{
                $samW = New-ImportADUser -SamAccountName $samW -UPN $upnW `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95))  -WhenCreatedDaysAgo 300 -Enabled $true
                $stdW = New-ImportADUser -SamAccountName $stdW -UPN "$stdW@corp.local" -Enabled $true
                $samD = New-ImportADUser -SamAccountName $samD -UPN $upnD `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdD = New-ImportADUser -SamAccountName $stdD -UPN "$stdD@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True  `$result.Success                    '[import] Success = true under WhatIf'
                Assert-Null  `$result.Error                      '[import] No top-level error under WhatIf'
                Assert-Count `$result.Results 2                  '[import] Both accounts produce a result entry'
                Assert-ResultField `$result.Results '$upnW' 'ActionTaken' 'Notify'    '[import] upnW ActionTaken = Notify'
                Assert-ResultField `$result.Results '$upnW' 'Status'      'Completed' '[import] upnW Status = Completed'
                Assert-ResultField `$result.Results '$upnD' 'ActionTaken' 'Disable'   '[import] upnD ActionTaken = Disable'
                Assert-ResultField `$result.Results '$upnD' 'Status'      'Completed' '[import] upnD Status = Completed'
                Assert-ActionNotFired 'Notify'  `$null '[import] Send-GraphMail not called under WhatIf'
                Assert-ActionNotFired 'Disable' `$null '[import] Disable-InactiveAccount not called under WhatIf'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-07: Unprocessed is empty when all accounts Completed [import]
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.unp07i'; $upn = 'admin.unp07i@corp.local'; $std = 'unp07i'
        @{
            Name     = '06-07: [Import] Unprocessed is empty when all accounts Completed'
            Why      = 'Unprocessed must be empty after a clean run -- a non-empty list would cause unnecessary retries of already-completed accounts.'
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
                Assert-Count @(`$result.Unprocessed) 0 '[import] Unprocessed is empty when all accounts Completed'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-09: Unprocessed contains error accounts in import-contract shape [import]
    # ------------------------------------------------------------------
    $(
        $samOk  = 'admin.unp08oki';  $upnOk  = 'admin.unp08oki@corp.local';  $stdOk  = 'unp08oki'
        $samErr = 'admin.unp08erri'; $upnErr = 'admin.unp08erri@corp.local'; $stdErr = 'unp08erri'
        @{
            Name        = '06-09: [Import] Unprocessed contains error accounts in import-contract shape'
            Why         = 'Error accounts must appear in Unprocessed with all import-contract fields present so they can be fed directly into a retry run without transformation.'
            DisableFail = @($upnErr)
            Accounts    = @(
                New-ImportTestAccount -SamAccountName $samOk  -UPN $upnOk  -InactiveDaysAgo 120
                New-ImportTestAccount -SamAccountName $samErr -UPN $upnErr -InactiveDaysAgo 120
            )
            ADUsers     = @{
                $samOk  = New-ImportADUser -SamAccountName $samOk  -UPN $upnOk  `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdOk  = New-ImportADUser -SamAccountName $stdOk  -UPN "$stdOk@corp.local"  -Enabled $true
                $samErr = New-ImportADUser -SamAccountName $samErr -UPN $upnErr `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdErr = New-ImportADUser -SamAccountName $stdErr -UPN "$stdErr@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-Count @(`$result.Unprocessed) 1 '[import] Unprocessed has one entry (the error account)'
                `$u = `$result.Unprocessed[0]
                Assert-Equal `$u.UserPrincipalName '$upnErr' '[import] Unprocessed[0].UserPrincipalName = upnErr'
                Assert-Equal `$u.SamAccountName   '$samErr' '[import] Unprocessed[0].SamAccountName = samErr'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Enabled'))             '[import] Unprocessed row has Enabled field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'LastLogonDate'))       '[import] Unprocessed row has LastLogonDate field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Created'))             '[import] Unprocessed row has Created field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'EntraObjectId'))       '[import] Unprocessed row has EntraObjectId field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'entraLastSignInAEST')) '[import] Unprocessed row has entraLastSignInAEST field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Description'))         '[import] Unprocessed row has Description field'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-10: Unprocessed from discovery is in import-contract shape [discovery]
    # ------------------------------------------------------------------
    $(
        $samOk  = 'admin.unp08okd';  $upnOk  = 'admin.unp08okd@corp.local';  $stdOk  = 'unp08okd'
        $samErr = 'admin.unp08errd'; $upnErr = 'admin.unp08errd@corp.local'; $stdErr = 'unp08errd'
        @{
            Name          = '06-10: [Discovery] Unprocessed contains error accounts in import-contract shape'
            Why           = 'Discovery mode maps its own field names (UPN, LastLogonAD, etc.) to the import contract when building Unprocessed -- this verifies the mapping is correct so a discovery Unprocessed can be fed to an import retry.'
            DisableFail   = @($upnErr)
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $samOk  -UPN $upnOk  -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samErr -UPN $upnErr -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $stdOk  = New-DiscoveryOwnerADUser -SamAccountName $stdOk  -EmailAddress "$stdOk@corp.local"
                $stdErr = New-DiscoveryOwnerADUser -SamAccountName $stdErr -EmailAddress "$stdErr@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-Count @(`$result.Unprocessed) 1 '[disc] Unprocessed has one entry (the error account)'
                `$u = `$result.Unprocessed[0]
                Assert-Equal `$u.UserPrincipalName '$upnErr' '[disc] Unprocessed[0].UserPrincipalName = upnErr'
                Assert-Equal `$u.SamAccountName   '$samErr' '[disc] Unprocessed[0].SamAccountName = samErr'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Enabled'))             '[disc] Unprocessed row has Enabled field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'LastLogonDate'))       '[disc] Unprocessed row has LastLogonDate field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Created'))             '[disc] Unprocessed row has Created field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'EntraObjectId'))       '[disc] Unprocessed row has EntraObjectId field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'entraLastSignInAEST')) '[disc] Unprocessed row has entraLastSignInAEST field'
                Assert-True (`$null -ne (Get-Member -InputObject `$u -Name 'Description'))         '[disc] Unprocessed row has Description field'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-11: Unprocessed re-run -- import Unprocessed fed back into import mode
    # ------------------------------------------------------------------
    $(
        $samOk  = 'admin.rerun11oki';  $upnOk  = 'admin.rerun11oki@corp.local';  $stdOk  = 'rerun11oki'
        $samErr = 'admin.rerun11erri'; $upnErr = 'admin.rerun11erri@corp.local'; $stdErr = 'rerun11erri'
        $adUsersMap = @{
            $samOk  = New-ImportADUser -SamAccountName $samOk  -UPN $upnOk  `
                -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
            $stdOk  = New-ImportADUser -SamAccountName $stdOk  -UPN "$stdOk@corp.local"  -Enabled $true
            $samErr = New-ImportADUser -SamAccountName $samErr -UPN $upnErr `
                -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
            $stdErr = New-ImportADUser -SamAccountName $stdErr -UPN "$stdErr@corp.local" -Enabled $true
        }
        @{
            Name        = '06-11: [Import--Import re-run] Unprocessed re-run -- succeeds on second attempt'
            Why         = 'The entire point of Unprocessed is to enable retry without re-running the full sweep -- confirms a failed account completes when fed back in after the transient fault is cleared.'
            DisableFail = @($upnErr)
            Accounts    = @(
                New-ImportTestAccount -SamAccountName $samOk  -UPN $upnOk  -InactiveDaysAgo 120
                New-ImportTestAccount -SamAccountName $samErr -UPN $upnErr -InactiveDaysAgo 120
            )
            ADUsers     = $adUsersMap
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result1, `$ctx)

                # --- Run 1 sanity ---
                Assert-Count @(`$result1.Unprocessed) 1 '[run1] Unprocessed has 1 entry after disable failure'
                Assert-Equal `$result1.Unprocessed[0].UserPrincipalName '$upnErr' '[run1] Unprocessed[0] is the failed account'

                # --- Prepare run 2: clear the failure, reset actions ---
                `$ctx.DisableFail = @()
                `$ctx.Actions     = [System.Collections.Generic.List[pscustomobject]]::new()

                `$result2 = Invoke-ImportOnce -Accounts `$result1.Unprocessed

                # --- Run 2 assertions ---
                Assert-True  `$result2.Success                          '[run2] Success = true'
                Assert-Null  `$result2.Error                            '[run2] No top-level error'
                Assert-Count @(`$result2.Results) 1                     '[run2] Results has 1 entry'
                Assert-ResultField `$result2.Results '$upnErr' 'Status' 'Completed' '[run2] previously-failed account now Completed'
                Assert-Count @(`$result2.Unprocessed) 0                 '[run2] Unprocessed is empty after successful re-run'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 06-12: Unprocessed re-run -- discovery Unprocessed fed into import mode
    # ------------------------------------------------------------------
    $(
        $samOk  = 'admin.rerun12okd';  $upnOk  = 'admin.rerun12okd@corp.local';  $stdOk  = 'rerun12okd'
        $samErr = 'admin.rerun12errd'; $upnErr = 'admin.rerun12errd@corp.local'; $stdErr = 'rerun12errd'
        $liveDate   = [datetime]::UtcNow.AddDays(-120)
        $adUsersMap = @{
            $stdOk  = New-DiscoveryOwnerADUser -SamAccountName $stdOk  -EmailAddress "$stdOk@corp.local"
            $stdErr = New-DiscoveryOwnerADUser -SamAccountName $stdErr -EmailAddress "$stdErr@corp.local"
        }
        $adUsersMap[$samOk] = [pscustomobject]@{
            SamAccountName       = $samOk
            UserPrincipalName    = $upnOk
            Enabled              = $true
            LastLogonDate        = $liveDate
            whenCreated          = [datetime]::UtcNow.AddDays(-300)
            extensionAttribute14 = ''
            Description          = ''
            EmailAddress         = $upnOk
        }
        $adUsersMap[$samErr] = [pscustomobject]@{
            SamAccountName       = $samErr
            UserPrincipalName    = $upnErr
            Enabled              = $true
            LastLogonDate        = $liveDate
            whenCreated          = [datetime]::UtcNow.AddDays(-300)
            extensionAttribute14 = ''
            Description          = ''
            EmailAddress         = $upnErr
        }
        @{
            Name          = '06-12: [Discovery--Import re-run] Discovery Unprocessed fed into import mode -- succeeds'
            Why           = 'Confirms cross-mode retry: a discovery run produces Unprocessed rows in import-contract shape that can be passed directly to an import-mode retry without any manual field mapping.'
            DisableFail   = @($upnErr)
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $samOk  -UPN $upnOk  -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samErr -UPN $upnErr -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers = $adUsersMap
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result1, `$ctx)

                # --- Run 1 sanity (discovery) ---
                Assert-Count @(`$result1.Unprocessed) 1 '[disc-run1] Unprocessed has 1 entry after disable failure'
                Assert-Equal `$result1.Unprocessed[0].UserPrincipalName '$upnErr' '[disc-run1] Unprocessed[0] is the failed account'

                # --- Prepare run 2 (import) ---
                `$ctx.DisableFail = @()
                `$ctx.Actions     = [System.Collections.Generic.List[pscustomobject]]::new()

                `$result2 = Invoke-ImportOnce -Accounts `$result1.Unprocessed

                # --- Run 2 assertions ---
                Assert-True  `$result2.Success                          '[import-run2] Success = true'
                Assert-Null  `$result2.Error                            '[import-run2] No top-level error'
                Assert-Count @(`$result2.Results) 1                     '[import-run2] Results has 1 entry'
                Assert-ResultField `$result2.Results '$upnErr' 'Status' 'Completed' '[import-run2] previously-failed account now Completed'
                Assert-Count @(`$result2.Unprocessed) 0                 '[import-run2] Unprocessed is empty after re-run'
"@)
        }
    )

)
