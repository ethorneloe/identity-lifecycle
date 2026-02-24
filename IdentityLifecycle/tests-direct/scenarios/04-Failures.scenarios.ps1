$Scenarios = @(

    # ------------------------------------------------------------------
    # 04-01: Send-GraphMail throws -- fatal, loop aborts, no Disable fired
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.mailfail01'; $upn = 'admin.mailfail01@corp.local'; $std = 'mailfail01'
        @{
            Name       = '04-01: Notify fails -- fatal error, Disable not fired'
            NotifyFail = @($upn)
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers    = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-False  `$result.Success 'Success = false on notify failure'
                Assert-True  (`$result.Error -match 'Send-GraphMail') 'Error mentions Send-GraphMail'
                Assert-ActionNotFired 'Disable' '$upn' 'Disable NOT fired (loop aborted)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-02: Send-GraphMail fails mid-batch -- prior account already actioned
    # ------------------------------------------------------------------
    $(
        $sam1 = 'admin.ok02a';       $upn1 = 'admin.ok02a@corp.local';       $std1 = 'ok02a'
        $sam2 = 'admin.mailfail02b'; $upn2 = 'admin.mailfail02b@corp.local'; $std2 = 'mailfail02b'
        @{
            Name       = '04-02: Notify fails mid-batch -- loop aborts, upn1 already actioned'
            NotifyFail = @($upn2)
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam1 -UPN $upn1 -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
                New-DirectADAccount -SamAccountName $sam2 -UPN $upn2 -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers    = @{
                $std1 = New-DirectOwnerADUser -SamAccountName $std1 -EmailAddress "$std1@corp.local"
                $std2 = New-DirectOwnerADUser -SamAccountName $std2 -EmailAddress "$std2@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-False  `$result.Success 'Success = false on notify failure'
                Assert-True  (`$result.Error -match 'Send-GraphMail') 'Error mentions Send-GraphMail'
                Assert-ActionFired    'Disable' '$upn1' 'Disable fired for upn1 before failure'
                Assert-ActionNotFired 'Disable' '$upn2' 'Disable NOT fired for upn2 (loop aborted)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-03: Disable-InactiveAccount fails -- Error recorded, loop continues
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.disfail03'; $upn = 'admin.disfail03@corp.local'; $std = 'disfail03'
        @{
            Name        = '04-03: Disable-InactiveAccount fails -- Error recorded'
            DisableFail = @($upn)
            ADAccountList = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers     = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors'   1 'Errors = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0 (not completed)'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Error' 'Status = Error'
                `$entry = @(`$result.Results | Where-Object { `$_.UPN -eq '$upn' }) | Select-Object -First 1
                Assert-NotNull `$entry.Error 'Error field is set'
                Assert-ActionFired 'Notify'  '$upn' 'Notify still fired'
                Assert-ActionFired 'Disable' '$upn' 'Disable was attempted'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-04: Remove-InactiveAccount fails -- Error recorded, loop continues
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.remfail04'; $upn = 'admin.remfail04@corp.local'; $std = 'remfail04'
        @{
            Name           = '04-04: Remove-InactiveAccount fails -- Error recorded'
            RemoveFail     = @($upn)
            EnableDeletion = $true
            ADAccountList  = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 180 -WhenCreatedDaysAgo 400
            )
            ADUsers        = @{
                $std = New-DirectOwnerADUser -SamAccountName $std -EmailAddress "$std@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Deleted' 0 'Deleted = 0 (failure)'
                Assert-SummaryField `$result.Summary 'Errors'  1 'Errors = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Error' 'Status = Error'
                Assert-ActionFired  'Remove' '$upn' 'Remove was attempted'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-05: Mixed batch: one succeeds, one disable fails -- both counted
    # ------------------------------------------------------------------
    $(
        $sam1 = 'admin.ok05a';   $upn1 = 'admin.ok05a@corp.local';   $std1 = 'ok05a'
        $sam2 = 'admin.fail05b'; $upn2 = 'admin.fail05b@corp.local'; $std2 = 'fail05b'
        @{
            Name        = '04-05: Mixed batch -- one success, one disable failure -- both counted'
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
                Assert-SummaryField `$result.Summary 'Total'    2 'Total = 2'
                Assert-SummaryField `$result.Summary 'Disabled' 1 'Disabled = 1'
                Assert-SummaryField `$result.Summary 'Errors'   1 'Errors = 1'
                Assert-ResultField  `$result.Results '$upn1' 'Status' 'Completed' 'upn1 Status = Completed'
                Assert-ResultField  `$result.Results '$upn2' 'Status' 'Error'     'upn2 Status = Error'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-06: Connect-MgGraph fails -- fatal error before any processing;
    # Results empty, Summary present with all zeros.
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.conn06'; $upn = 'admin.conn06@corp.local'
        @{
            Name                    = '04-06: Connect-MgGraph fails -- fatal error, Results empty'
            ConnectFail             = $true
            UseExistingGraphSession = $false
            ADAccountList           = @(
                New-DirectADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-False  `$result.Success 'Success = false on connect failure'
                Assert-NotNull `$result.Error  'Error is set'
                Assert-True  (`$result.Error -match 'Connect-MgGraph') 'Error mentions Connect-MgGraph'
                Assert-NotNull `$result.Summary 'Summary is present (always built in finally)'
                Assert-SummaryField `$result.Summary 'Total' 0 'Total = 0 (never processed)'
                Assert-Empty `$result.Results  'Results is empty (never processed)'
                Assert-ActionNotFired 'Notify' '$upn' 'No actions fired'
"@)
        }
    )

)
