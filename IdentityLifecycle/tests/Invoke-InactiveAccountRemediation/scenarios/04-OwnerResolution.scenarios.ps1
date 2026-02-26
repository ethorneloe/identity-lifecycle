$Scenarios = @(

    # ------------------------------------------------------------------
    # 04-01: Prefix-strip resolves owner [import]
    # ------------------------------------------------------------------
    $(
        $samI = 'admin.pstrip01i'; $upnI = 'admin.pstrip01i@corp.local'; $stdI = 'pstrip01i'
        @{
            Name     = '04-01: [Import] Prefix-strip owner resolution -- Disable action with correct owner'
            Why      = 'The naming convention (prefix.sam) is the primary ownership contract -- confirms the correct owner is identified and notified.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 120
            )
            ADUsers  = @{
                $samI = New-ImportADUser -SamAccountName $samI -UPN $upnI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdI = New-ImportADUser -SamAccountName $stdI -UPN "$stdI@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[import] Disabled = 1 (prefix-strip)'
                Assert-ResultField  `$result.Results '$upnI' 'Status' 'Completed' '[import] Status = Completed'
                Assert-ResultField  `$result.Results '$upnI' 'NotificationRecipient' '$stdI@corp.local' '[import] NotificationRecipient = owner email'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-02: EA14 resolves owner [discovery]
    # ------------------------------------------------------------------
    $(
        $samD = 'admin.ea02d'; $upnD = 'admin.ea02d@corp.local'; $ownerD = 'ea02downer'
        @{
            Name          = '04-02: [Discovery] EA14 owner resolution -- Disable with EA14 owner'
            Why           = 'extensionAttribute14 is the override mechanism for accounts that do not follow the naming convention -- confirms it takes precedence and resolves correctly.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300 `
                    -ExtensionAttribute14 "dept=IT;owner=$ownerD"
            )
            ADUsers = @{
                $ownerD = New-DiscoveryOwnerADUser -SamAccountName $ownerD -EmailAddress "$ownerD@corp.local"
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[disc] Disabled = 1 (EA14)'
                Assert-ResultField  `$result.Results '$upnD' 'Status' 'Completed' '[disc] Status = Completed'
                Assert-ResultField  `$result.Results '$upnD' 'NotificationRecipient' '$ownerD@corp.local' '[disc] NotificationRecipient = EA14 owner'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-03: EA14 bad candidate -- falls back to prefix-strip [import]
    # ------------------------------------------------------------------
    $(
        $samI = 'admin.eafb03i'; $upnI = 'admin.eafb03i@corp.local'; $stdI = 'eafb03i'
        @{
            Name     = '04-03: [Import] EA14 bad candidate -- falls back to prefix-strip'
            Why      = 'When the EA14 owner value does not exist in AD, the function must fall back to prefix-strip rather than failing -- stale attributes should not block remediation.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 120
            )
            ADUsers  = @{
                $samI = New-ImportADUser -SamAccountName $samI -UPN $upnI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true `
                    -ExtensionAttribute14 'owner=nonexistent.bad'
                $stdI = New-ImportADUser -SamAccountName $stdI -UPN "$stdI@corp.local" -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[import] Disabled = 1 (prefix-strip fallback)'
                Assert-ResultField  `$result.Results '$upnI' 'Status' 'Completed' '[import] Status = Completed (EA14 bad -- fallback to prefix-strip)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-04: No owner found -- Skipped/NoOwnerFound [discovery]
    # ------------------------------------------------------------------
    $(
        $samD = 'admin.noown04d'; $upnD = 'admin.noown04d@corp.local'
        @{
            Name          = '04-04: [Discovery] No owner found -- Skipped/NoOwnerFound'
            Why           = 'Without an owner, no notification can be sent -- the account must be skipped and surfaced in the summary so it can be investigated manually.'
            ADAccountList = @(
                New-DiscoveryADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            ADUsers = @{} # 'noown04d' absent -- NoOwnerFound
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[disc] Skipped = 1'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 '[disc] NoOwner = 1'
                Assert-ResultField  `$result.Results '$upnD' 'SkipReason' 'NoOwnerFound' '[disc] SkipReason = NoOwnerFound'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-05: Owner found but no email address -- Skipped/NoEmailFound [import]
    # ------------------------------------------------------------------
    $(
        $samI = 'admin.noeml05i'; $upnI = 'admin.noeml05i@corp.local'; $stdI = 'noeml05i'
        @{
            Name     = '04-05: [Import] Owner found but no email -- Skipped/NoEmailFound'
            Why      = 'An owner exists in AD but has no email address -- disabling without notification would violate process; the account must be skipped and flagged distinctly from NoOwnerFound.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 120
            )
            ADUsers  = @{
                $samI = New-ImportADUser -SamAccountName $samI -UPN $upnI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                $stdI = New-ImportADUser -SamAccountName $stdI -UPN '' -EmailAddress '' -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[import] Skipped = 1 (no owner email)'
                Assert-ResultField  `$result.Results '$upnI' 'SkipReason' 'NoEmailFound' '[import] SkipReason = NoEmailFound'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-06: AD account with Entra sponsor as owner (import + discovery)
    # EntraObjectId flows differently per mode -- both variants kept.
    # ------------------------------------------------------------------
    $(
        $oidI         = [guid]::NewGuid().ToString()
        $samI         = 'admin.spon06i'; $upnI = 'admin.spon06i@corp.local'
        $sponsorMailI = 'sponsor06i@corp.local'
        @{
            Name     = '04-06: [Import] AD account -- Entra sponsor used when prefix-strip fails'
            Why      = 'When prefix-strip finds no AD owner, the Entra sponsor is the fallback -- confirms the sponsor path works for AD-synced accounts in import mode.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $samI -UPN $upnI -InactiveDaysAgo 120 -EntraObjectId $oidI
            )
            ADUsers  = @{
                $samI = New-ImportADUser -SamAccountName $samI -UPN $upnI `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-120)) -WhenCreatedDaysAgo 300 -Enabled $true
                # stdI absent -- prefix-strip fails -- try sponsor
            }
            MgUsers  = @{
                $oidI = New-ImportMgUser -ObjectId $oidI -AccountEnabled $true -LastSignInDaysAgo 120
            }
            MgUserSponsors = @{
                $oidI = @([pscustomobject]@{ Mail = $sponsorMailI; UserPrincipalName = $sponsorMailI })
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[import] Disabled = 1 (sponsor)'
                Assert-ResultField  `$result.Results '$upnI' 'Status' 'Completed' '[import] Status = Completed'
                Assert-ResultField  `$result.Results '$upnI' 'NotificationRecipient' '$sponsorMailI' '[import] NotificationRecipient = sponsor email'
"@)
        }
    ),

    $(
        $oidD         = [guid]::NewGuid().ToString()
        $samD         = 'admin.spon06d'; $upnD = 'admin.spon06d@corp.local'
        $sponsorMailD = 'sponsor06d@corp.local'
        # A synced Entra entry provides the EntraObjectId to the orchestrator's merge step.
        @{
            Name             = '04-06: [Discovery] AD account -- Entra sponsor used when prefix-strip fails'
            Why              = 'In discovery mode the EntraObjectId comes from the merged Entra entry, not the AD object -- confirms the sponsor path works when the OID is sourced correctly.'
            ADAccountList    = @(
                New-DiscoveryADAccount -SamAccountName $samD -UPN $upnD -LastLogonDaysAgo 120 -WhenCreatedDaysAgo 300
            )
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oidD -UPN $upnD `
                    -OnPremisesSyncEnabled $true -LastSignInDaysAgo 120
            )
            ADUsers          = @{} # 'spon06d' absent -- prefix-strip fails -- try sponsor
            MgUserSponsors   = @{
                $oidD = @([pscustomobject]@{ Mail = $sponsorMailD; UserPrincipalName = $sponsorMailD })
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Disabled' 1 '[disc] Disabled = 1 (sponsor)'
                Assert-ResultField  `$result.Results '$upnD' 'Status' 'Completed' '[disc] Status = Completed'
                Assert-ResultField  `$result.Results '$upnD' 'NotificationRecipient' '$sponsorMailD' '[disc] NotificationRecipient = sponsor email'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-07: Entra-native inactive, sponsor as owner (import + discovery)
    # Cloud-native accounts have no SAM -- sponsor path is the only owner route.
    # ------------------------------------------------------------------
    $(
        $oidI         = [guid]::NewGuid().ToString()
        $upnI         = 'cloud.spon07i@corp.local'
        $sponsorMailI = 'sponsor07i@corp.local'
        @{
            Name     = '04-07: [Import] Entra-native -- owner via sponsor'
            Why      = 'Cloud-native accounts have no SAM so prefix-strip cannot apply -- the Entra sponsor is the only owner route and must work end-to-end.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName '' -UPN $upnI -InactiveDaysAgo 95 `
                    -AccountEnabled $true -EntraObjectId $oidI
            )
            MgUsers  = @{
                $oidI = New-ImportMgUser -ObjectId $oidI -AccountEnabled $true -LastSignInDaysAgo 95
            }
            MgUserSponsors = @{
                $oidI = @([pscustomobject]@{ Mail = $sponsorMailI; UserPrincipalName = $sponsorMailI })
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[import] Warned = 1 (Entra-native via sponsor)'
                Assert-ResultField  `$result.Results '$upnI' 'Status' 'Completed' '[import] Status = Completed'
                Assert-ResultField  `$result.Results '$upnI' 'NotificationRecipient' '$sponsorMailI' '[import] NotificationRecipient = sponsor email'
"@)
        }
    ),

    $(
        $oidD         = [guid]::NewGuid().ToString()
        $upnD         = 'cloud.spon07d@corp.local'
        $sponsorMailD = 'sponsor07d@corp.local'
        @{
            Name             = '04-07: [Discovery] Entra-native -- owner via sponsor'
            Why              = 'Same sponsor-only path exercised in discovery mode, where cloud-native accounts arrive via Get-PrefixedEntraAccounts.'
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oidD -UPN $upnD -LastSignInDaysAgo 95
            )
            MgUserSponsors = @{
                $oidD = @([pscustomobject]@{ Mail = $sponsorMailD; UserPrincipalName = $sponsorMailD })
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 '[disc] Warned = 1 (Entra-native via sponsor)'
                Assert-ResultField  `$result.Results '$upnD' 'Status' 'Completed' '[disc] Status = Completed'
                Assert-ResultField  `$result.Results '$upnD' 'NotificationRecipient' '$sponsorMailD' '[disc] NotificationRecipient = sponsor email'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 04-08: Entra-native, no sponsor -- Skipped/NoOwnerFound (import + discovery)
    # ------------------------------------------------------------------
    $(
        $oidI = [guid]::NewGuid().ToString()
        $upnI = 'cloud.nospon08i@corp.local'
        @{
            Name     = '04-08: [Import] Entra-native -- no sponsor -- NoOwnerFound'
            Why      = 'A cloud-native account with no sponsor has no owner at all -- must be skipped and counted in the NoOwner summary so it can be investigated.'
            Accounts = @(
                New-ImportTestAccount -SamAccountName '' -UPN $upnI -InactiveDaysAgo 95 `
                    -AccountEnabled $true -EntraObjectId $oidI
            )
            MgUsers  = @{
                $oidI = New-ImportMgUser -ObjectId $oidI -AccountEnabled $true -LastSignInDaysAgo 95
            }
            # No MgUserSponsors entry -- empty sponsors
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[import] Skipped = 1 (no sponsor)'
                Assert-ResultField  `$result.Results '$upnI' 'SkipReason' 'NoOwnerFound' '[import] SkipReason = NoOwnerFound'
"@)
        }
    ),

    $(
        $oidD = [guid]::NewGuid().ToString()
        $upnD = 'cloud.nospon08d@corp.local'
        @{
            Name             = '04-08: [Discovery] Entra-native -- no sponsor -- NoOwnerFound'
            Why              = 'Same no-sponsor path in discovery mode -- confirms the NoOwnerFound outcome is consistent regardless of how the account was sourced.'
            EntraAccountList = @(
                New-DiscoveryEntraAccount -EntraObjectId $oidD -UPN $upnD -LastSignInDaysAgo 95
            )
            # No MgUserSponsors entry
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 '[disc] Skipped = 1 (no sponsor)'
                Assert-ResultField  `$result.Results '$upnD' 'SkipReason' 'NoOwnerFound' '[disc] SkipReason = NoOwnerFound'
"@)
        }
    )

)
