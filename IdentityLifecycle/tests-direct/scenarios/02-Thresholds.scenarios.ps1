$Scenarios = @(

    # ------------------------------------------------------------------
    # 02-01: 90 days (exactly at WarnThreshold) -- Notify/Warning
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.warn01'; $upn = 'admin.warn01@corp.local'; $std = 'warn01'
        @{
            Name     = '02-01: 90 days inactive (exactly at WarnThreshold) -- Notify/Warning'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 90 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned'   1 'Warned = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed' 'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Notify'    'ActionTaken = Notify'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Warning'   'NotificationStage = Warning'
                Assert-ActionFired  'Notify' '$upn' 'Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'Disable not fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-02: 89 days (below WarnThreshold) -- Skipped/ActivityDetected
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.active02'; $upn = 'admin.active02@corp.local'
        @{
            Name     = '02-02: 89 days inactive (below WarnThreshold) -- Skipped/ActivityDetected'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 89 -WhenCreatedDaysAgo 300
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'Warned'  0 'Warned = 0'
                Assert-ResultField  `$result.Results '$upn' 'Status'     'Skipped'          'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-03: 120 days (at DisableThreshold) -- Disable/Disabled
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.disable03'; $upn = 'admin.disable03@corp.local'; $std = 'disable03'
        @{
            Name     = '02-03: 120 days inactive (at DisableThreshold) -- Disable/Disabled'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-SummaryField `$result.Summary 'Warned'   0 'Warned = 0'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed' 'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Disable'   'ActionTaken = Disable'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Disabled'  'NotificationStage = Disabled'
                Assert-ActionFired  'Notify'  '$upn' 'Notify fired'
                Assert-ActionFired  'Disable' '$upn' 'Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-04: 150 days (between thresholds) -- Disable/Disabled
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.dis04'; $upn = 'admin.dis04@corp.local'; $std = 'dis04'
        @{
            Name     = '02-04: 150 days inactive (between thresholds) -- Disable/Disabled stage'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 150 -WhenCreatedDaysAgo 400
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Disable'  'ActionTaken = Disable'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Disabled' 'NotificationStage = Disabled'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed' 'Status = Completed'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-05: 180 days, EnableDeletion OFF -- Disable with Deletion notification
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.del05a'; $upn = 'admin.del05a@corp.local'; $std = 'del05a'
        @{
            Name     = '02-05: 180 days inactive, EnableDeletion OFF -- Disable with Deletion notification'
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 180 -WhenCreatedDaysAgo 500
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1 (EnableDeletion off)'
                Assert-SummaryField `$result.Summary 'Deleted'  0 'Deleted = 0'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Disable'  'ActionTaken = Disable'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Deletion' 'NotificationStage = Deletion'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed' 'Status = Completed'
                Assert-ActionFired  'Notify'  '$upn' 'Notify fired'
                Assert-ActionFired  'Disable' '$upn' 'Disable fired'
                Assert-ActionNotFired 'Remove' '$upn' 'Remove NOT fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-06: 180 days, EnableDeletion ON -- Remove/Deletion
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.del06b'; $upn = 'admin.del06b@corp.local'; $std = 'del06b'
        @{
            Name           = '02-06: 180 days inactive, EnableDeletion ON -- Remove with Deletion notification'
            EnableDeletion = $true
            ADAccountList  = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 180 -WhenCreatedDaysAgo 500
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Deleted'  1 'Deleted = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken'       'Delete'   'ActionTaken = Delete'
                Assert-ResultField  `$result.Results '$upn' 'NotificationStage' 'Deletion' 'NotificationStage = Deletion'
                Assert-ResultField  `$result.Results '$upn' 'Status'            'Completed' 'Status = Completed'
                Assert-ActionFired  'Notify'  '$upn' 'Notify fired'
                Assert-ActionFired  'Remove'  '$upn' 'Remove fired'
                Assert-ActionNotFired 'Disable' '$upn' 'Disable NOT fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-07: No LastLogonAD -- falls back to Created for InactiveDays
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.nologon07'; $upn = 'admin.nologon07@corp.local'; $std = 'nologon07'
        @{
            Name     = '02-07: No LastLogonAD -- falls back to Created for InactiveDays'
            ADAccountList = @(
                # LastLogonDaysAgo -1 = never logged on; Created 95 days ago
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo -1 -WhenCreatedDaysAgo 95
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (Created 95 days ago >= WarnThreshold)'
                Assert-ResultField  `$result.Results '$upn' 'Status'      'Completed' 'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Notify'    'ActionTaken = Notify'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-08: No activity data at all -- Error
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.nodata08'; $upn = 'admin.nodata08@corp.local'
        @{
            Name     = '02-08: No activity data whatsoever -- Error (cannot determine last activity)'
            ADAccountList = @(
                # LastLogonDaysAgo -1 and Created forced to null by setting WhenCreatedDaysAgo=0 then overriding
                [pscustomobject]@{
                    SamAccountName       = $sam
                    UPN                  = $upn
                    ObjectId             = [guid]::NewGuid().ToString()
                    Enabled              = $true
                    LastLogonAD          = $null
                    Created              = $null
                    LastSignInEntra      = $null
                    ExtensionAttribute14 = ''
                    Description          = ''
                }
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 'Errors = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Error' 'Status = Error'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 02-09: Custom thresholds (WarnThreshold=30) -- account at 35 days triggers Warning
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.custom09'; $upn = 'admin.custom09@corp.local'; $std = 'custom09'
        @{
            Name           = '02-09: Custom thresholds -- WarnThreshold=30, account at 35 days -- Warn'
            WarnThreshold  = 30
            ADAccountList  = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 35 -WhenCreatedDaysAgo 200
            )
            ADUsers  = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'ActionTaken' 'Notify' 'ActionTaken = Notify'
"@)
        }
    )

)
