$Scenarios = @(

    # ------------------------------------------------------------------
    # 05-01: Send-GraphMail fails -- Error in Results [import]
    # ------------------------------------------------------------------
    $(
        $samI = 'admin.mfail01i'; $upnI = 'admin.mfail01i@corp.local'; $stdI = 'mfail01i'
        @{
            Name       = '05-01: [Import] Send-GraphMail failure -- Status=Error, no Disable attempted'
            Why        = 'A mail failure must be recorded per-account and must not cascade -- the batch continues and no further actions (e.g. Disable) are attempted for that account.'
            NotifyFail = @($upnI)
            Accounts   = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 95
            )
            ADUsers    = @{
                $samI = New-ImportADUser -SamAccountName $samI -UPN $upnI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdI = New-ImportADUser -SamAccountName $stdI -UPN "$stdI@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 '[import] Errors = 1 (mail fail)'
                Assert-ResultField  `$result.Results '$upnI' 'Status' 'Error' '[import] Status = Error'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-02: Mail fails mid-batch -- first account OK, second fails [discovery]
    # ------------------------------------------------------------------
    $(
        $samOkD  = 'admin.mok02d';  $upnOkD  = 'admin.mok02d@corp.local';  $stdOkD  = 'mok02d'
        $samBadD = 'admin.mbad02d'; $upnBadD = 'admin.mbad02d@corp.local'; $stdBadD = 'mbad02d'
        @{
            Name          = '05-02: [Discovery] Mail fail mid-batch -- first OK, second Error'
            Why           = 'A failure on one account must not abort the batch -- the first account must complete successfully and the overall Success flag must remain true.'
            NotifyFail    = @($upnBadD)
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $samOkD  -UPN $upnOkD  -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
                New-DiscoveryADAccount -SamAccountName $samBadD -UPN $upnBadD -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{
                $stdOkD  = New-DiscoveryOwnerADUser -SamAccountName $stdOkD  -EmailAddress "$stdOkD@corp.local"
                $stdBadD = New-DiscoveryOwnerADUser -SamAccountName $stdBadD -EmailAddress "$stdBadD@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True  `$result.Success '[disc] Success = true (errors per-entry)'
                Assert-SummaryField `$result.Summary 'Warned'  1 '[disc] Warned = 1'
                Assert-SummaryField `$result.Summary 'Errors'  1 '[disc] Errors = 1'
                Assert-ResultField  `$result.Results '$upnOkD'  'Status' 'Completed' '[disc] first account = Completed'
                Assert-ResultField  `$result.Results '$upnBadD' 'Status' 'Error'     '[disc] second account = Error'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-03: Disable-InactiveAccount fails -- Error [import]
    # ------------------------------------------------------------------
    $(
        $samI = 'admin.dfail03i'; $upnI = 'admin.dfail03i@corp.local'; $stdI = 'dfail03i'
        @{
            Name        = '05-03: [Import] Disable-InactiveAccount failure -- Status=Error'
            Why         = 'A disable failure must be captured per-account with Status=Error so it appears in Unprocessed and can be retried, rather than being silently lost.'
            DisableFail = @($upnI)
            Accounts    = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 120
            )
            ADUsers     = @{
                $samI = New-ImportADUser -SamAccountName $samI -UPN $upnI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdI = New-ImportADUser -SamAccountName $stdI -UPN "$stdI@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 '[import] Errors = 1 (disable fail)'
                Assert-ResultField  `$result.Results '$upnI' 'Status' 'Error' '[import] Status = Error'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-04: Remove-InactiveAccount fails -- Error [import]
    # ------------------------------------------------------------------
    $(
        $samI = 'admin.rfail04i'; $upnI = 'admin.rfail04i@corp.local'; $stdI = 'rfail04i'
        @{
            Name           = '05-04: [Import] Remove-InactiveAccount failure -- Status=Error'
            Why            = 'A delete failure must be captured per-account so the account lands in Unprocessed for retry rather than being considered successfully removed.'
            EnableDeletion = $true
            RemoveFail     = @($upnI)
            Accounts       = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 180 -WhenCreatedDaysAgo 500
            )
            ADUsers        = @{
                $samI = New-ImportADUser -SamAccountName $samI -UPN $upnI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-180)) -WhenCreatedDaysAgo 500 -Enabled $true
                $stdI = New-ImportADUser -SamAccountName $stdI -UPN "$stdI@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 '[import] Errors = 1 (remove fail)'
                Assert-ResultField  `$result.Results '$upnI' 'Status' 'Error' '[import] Status = Error'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-05: Mixed failure batch -- mail fail + disable fail [import]
    # ------------------------------------------------------------------
    $(
        $samWI = 'admin.mixw05i'; $upnWI = 'admin.mixw05i@corp.local'; $stdWI = 'mixw05i'
        $samDI = 'admin.mixd05i'; $upnDI = 'admin.mixd05i@corp.local'; $stdDI = 'mixd05i'
        @{
            Name        = '05-05: [Import] Mixed fail batch -- mail fail (warn) + disable fail'
            Why         = 'Multiple independent failures in a batch must each be recorded separately -- confirms per-account isolation across different failure types in the same run.'
            NotifyFail  = @($upnWI)
            DisableFail = @($upnDI)
            Accounts    = @(
                New-ImportTestAccount -SamAccountName $samWI -UPN $upnWI -InactiveDaysAgo 95
                New-ImportTestAccount -SamAccountName $samDI -UPN $upnDI -InactiveDaysAgo 120
            )
            ADUsers     = @{
                $samWI = New-ImportADUser -SamAccountName $samWI -UPN $upnWI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95))  -WhenCreatedDaysAgo 300 -Enabled $true
                $stdWI = New-ImportADUser -SamAccountName $stdWI -UPN "$stdWI@corp.local" -Enabled $true
                $samDI = New-ImportADUser -SamAccountName $samDI -UPN $upnDI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdDI = New-ImportADUser -SamAccountName $stdDI -UPN "$stdDI@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-True `$result.Success '[import] Success = true (per-entry errors)'
                Assert-SummaryField `$result.Summary 'Errors' 2 '[import] Errors = 2'
                Assert-ResultField  `$result.Results '$upnWI' 'Status' 'Error' '[import] warn account = Error (mail fail)'
                Assert-ResultField  `$result.Results '$upnDI' 'Status' 'Error' '[import] disable account = Error (disable fail)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 05-06: Connect-MgGraph fails -- Success=false, Error set [import]
    # ------------------------------------------------------------------
    $(
        $samI = 'admin.cfg06i'; $upnI = 'admin.cfg06i@corp.local'
        @{
            Name                    = '05-06: [Import] Connect-MgGraph failure -- Success=false'
            Why                     = 'A Graph connection failure is unrecoverable for the entire run -- Success must be false and Error populated so the caller knows no accounts were processed.'
            ConnectFail             = $true
            UseExistingGraphSession = $false
            Accounts                = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 95
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-False   `$result.Success '[import] Success = false on connect failure'
                Assert-NotNull `$result.Error   '[import] Error populated on connect failure'
"@)
        }
    )

)
