$Scenarios = @(

    # ------------------------------------------------------------------
    # 02-01: Exactly at WarnThreshold (90 days) -- Notify / Warning
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.warn01'; $upn = 'admin.warn01@corp.local'; $std = 'warn01'
        @{
            Name    = '02-01: 90 days inactive (exactly at WarnThreshold) -- Notify/Warning'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 90
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-90)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned'  1 'Warned = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Notify'     'ActionTaken = Notify'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Warning'    'NotificationStage = Warning'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed'  'Status = Completed'
                Assert-ActionFired  'Notify'  '$upn' 'Notify action fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-02: One day short of WarnThreshold (89 days) -- Skipped/ActivityDetected
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.belowwarn02'; $upn = 'admin.belowwarn02@corp.local'; $std = 'belowwarn02'
        @{
            Name    = '02-02: 89 days inactive (below WarnThreshold) -- Skipped/ActivityDetected'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 89
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-89)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'Warned'  0 'Warned = 0'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
                Assert-ActionNotFired 'Notify' `$null 'No Notify fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-03: At DisableThreshold (120 days) -- Disable / Disabled stage
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.dis03'; $upn = 'admin.dis03@corp.local'; $std = 'dis03'
        @{
            Name    = '02-03: 120 days inactive (at DisableThreshold) -- Disable/Disabled'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 120
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-SummaryField `$result.Summary 'Warned'   0 'Warned = 0'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Disable'   'ActionTaken = Disable'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Disabled'  'NotificationStage = Disabled'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed' 'Status = Completed'
                Assert-ActionFired  'Notify'  '$upn' 'Notify action fired'
                Assert-ActionFired  'Disable' '$upn' 'Disable action fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-04: Between disable and delete (150 days) -- Disable / Disabled stage
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.mid04'; $upn = 'admin.mid04@corp.local'; $std = 'mid04'
        @{
            Name    = '02-04: 150 days inactive (between thresholds) -- Disable/Disabled stage'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 150
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-150)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Disable'  'ActionTaken = Disable'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Disabled' 'NotificationStage = Disabled'
                Assert-ActionFired  'Disable' '$upn' 'Disable fired'
                Assert-ActionNotFired 'Remove' '$upn' 'No Remove fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-05: At DeleteThreshold (180 days), EnableDeletion OFF
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.del05'; $upn = 'admin.del05@corp.local'; $std = 'del05'
        @{
            Name    = '02-05: 180 days inactive, EnableDeletion OFF -- Disable with Deletion notification'
            EnableDeletion = $false
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 180
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-180)) `
                    -WhenCreatedDaysAgo 400 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-SummaryField `$result.Summary 'Deleted'  0 'Deleted = 0'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Disable'  'ActionTaken = Disable'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Deletion' 'NotificationStage = Deletion'
                Assert-ActionFired  'Notify'  '$upn' 'Notify fired'
                Assert-ActionFired  'Disable' '$upn' 'Disable fired'
                Assert-ActionNotFired 'Remove' '$upn' 'No Remove fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-06: At DeleteThreshold (180 days), EnableDeletion ON -- Remove + Deletion notification
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.del06'; $upn = 'admin.del06@corp.local'; $std = 'del06'
        @{
            Name    = '02-06: 180 days inactive, EnableDeletion ON -- Remove with Deletion notification'
            EnableDeletion = $true
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 180
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-180)) `
                    -WhenCreatedDaysAgo 400 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Deleted'  1 'Deleted = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Delete'    'ActionTaken = Delete'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Deletion'  'NotificationStage = Deletion'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed' 'Status = Completed'
                Assert-ActionFired  'Notify'  '$upn' 'Notify fired'
                Assert-ActionFired  'Remove'  '$upn' 'Remove fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-07: Account already disabled live, at DisableThreshold
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.alreadydis07'; $upn = 'admin.alreadydis07@corp.local'; $std = 'alreadydis07'
        @{
            Name    = '02-07: Already disabled in AD, at DisableThreshold -- success without Disable call'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 120 `
                    -AccountEnabled $false   # export also said disabled
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) `
                    -WhenCreatedDaysAgo 300 -Enabled $false
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Completed' 'Status = Completed'
                Assert-ActionNotFired 'Disable' '$upn' 'Disable-InactiveAccount NOT called (already disabled)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-08: No logon data at all -- falls back to WhenCreated
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.nologon08'; $upn = 'admin.nologon08@corp.local'; $std = 'nologon08'
        @{
            Name    = '02-08: No LastLogonDate -- falls back to WhenCreated for InactiveDays'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = $sam
                    UserPrincipalName     = $upn
                    LastLogonDate         = ''
                    Created               = [datetime]::UtcNow.AddDays(-200).ToString('o')
                    Enabled               = 'True'
                    EntraObjectId         = ''
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate $null -WhenCreatedDaysAgo 200 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Disable' 'ActionTaken = Disable'
                `$entry = @(`$result.Results | Where-Object { `$_.UPN -eq '$upn' }) | Select-Object -First 1
                Assert-True (`$entry.InactiveDays -ge 120) 'InactiveDays >= 120 (based on WhenCreated)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-09: No activity data at all -- Error
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.nodata09'; $upn = 'admin.nodata09@corp.local'
        @{
            Name    = '02-09: No activity data whatsoever -- Error (cannot determine last activity)'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = $sam
                    UserPrincipalName     = $upn
                    LastLogonDate         = ''
                    Created               = ''
                    Enabled               = 'True'
                    EntraObjectId         = ''
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{
                $sam = [pscustomobject]@{
                    SamAccountName       = $sam
                    Enabled              = $true
                    LastLogonDate        = $null
                    whenCreated          = $null
                    extensionAttribute14 = ''
                    Description          = ''
                    EmailAddress         = ''
                }
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 'Errors = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Error' 'Status = Error'
"@)
        }
    )

)
