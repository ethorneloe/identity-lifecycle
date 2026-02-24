$Scenarios = @(

    # ------------------------------------------------------------------
    # 01-01: Account with 30 days inactive -- below WarnThreshold (90) -- Skipped/ActivityDetected
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.active01'; $upn = 'admin.active01@corp.local'; $std = 'active01'
        @{
            Name    = '01-01: AD account 30 days inactive -- below threshold -- Skipped/ActivityDetected'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 30
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-30)) `
                    -WhenCreatedDaysAgo 200 -Enabled $true
                $std = New-ImportADUser -SamAccountName $std -UPN "$std@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'Warned'  0 'Warned = 0'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0'
                Assert-SummaryField `$result.Summary 'Errors'  0 'Errors = 0'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Skipped' 'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'ActivityDetected' 'SkipReason = ActivityDetected'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-02: Account disabled in AD since export -- Skipped/DisabledSinceExport
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.disabled02'; $upn = 'admin.disabled02@corp.local'
        @{
            Name    = '01-02: Account disabled in AD since export -- Skipped/DisabledSinceExport'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 150 `
                    -AccountEnabled $true   # export said enabled
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-150)) `
                    -WhenCreatedDaysAgo 300 -Enabled $false   # now disabled live
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'Disabled' 0 'Disabled = 0'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Skipped'             'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'DisabledSinceExport' 'SkipReason = DisabledSinceExport'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-03: AD lookup fails -- Error recorded
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.missing03'; $upn = 'admin.missing03@corp.local'
        @{
            Name    = '01-03: AD lookup fails (account not in mock) -- Error recorded'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 150
            )
            ADUsers = @{}   # empty -- Get-ADUser will throw
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 'Errors = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Error' 'Status = Error'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-04: Row with no UPN -- silently skipped (no result entry)
    # ------------------------------------------------------------------
    $(
        @{
            Name    = '01-04: Input row with no UPN -- silently skipped'
            Accounts = @(
                [pscustomobject]@{ SamAccountName = 'admin.noupn'; UserPrincipalName = '' }
            )
            ADUsers = @{}
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Total' 0 'Total = 0 (no result entry for no-UPN row)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-05: Entra-native account disabled since export -- Skipped/DisabledSinceExport
    # ------------------------------------------------------------------
    $(
        $oid = [guid]::NewGuid().ToString(); $upn = 'cloud.user05@corp.local'
        @{
            Name    = '01-05: Entra-native disabled since export -- Skipped/DisabledSinceExport'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = ''
                    UserPrincipalName     = $upn
                    LastLogonDate         = ''
                    Created               = [datetime]::UtcNow.AddDays(-300).ToString('o')
                    Enabled               = 'True'
                    EntraObjectId         = $oid
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{}
            MgUsers = @{
                $oid.ToLower() = New-ImportMgUser -ObjectId $oid -AccountEnabled $false -LastSignInDaysAgo 150
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'DisabledSinceExport' 'SkipReason = DisabledSinceExport'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 01-06: Account with no SamAccountName and no EntraObjectId -- Error
    # ------------------------------------------------------------------
    $(
        $upn = 'cloud.noid06@corp.local'
        @{
            Name    = '01-06: No SamAccountName and no EntraObjectId -- Error recorded'
            Accounts = @(
                [pscustomobject]@{
                    SamAccountName        = ''
                    UserPrincipalName     = $upn
                    LastLogonDate         = ''
                    Created               = ''
                    Enabled               = 'True'
                    EntraObjectId         = ''
                    entraLastSignInAEST   = ''
                    Description           = ''
                }
            )
            ADUsers = @{}
            MgUsers = @{}
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Errors' 1 'Errors = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status' 'Error' 'Status = Error'
"@)
        }
    )

)
