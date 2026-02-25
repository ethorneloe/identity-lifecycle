$Scenarios = @(

    # ------------------------------------------------------------------
    # 03-01: Owner resolved via extensionAttribute14 (prefix-strip yields no match)
    # SAM uses no recognised prefix, so prefix-strip is skipped entirely and
    # EA14 'owner=<sam>' provides the fallback resolution.
    # ------------------------------------------------------------------
    $(
        $sam = 'shared.infra01'; $upn = 'shared.infra01@corp.local'
        $ownerSam = 'infra01owner'; $ownerEmail = 'infra01owner@corp.local'
        @{
            Name    = '03-01: No prefix match -- owner resolved via extensionAttribute14 fallback'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true `
                    -ExtensionAttribute14 "dept=IT;owner=$ownerSam;location=HQ"
                $ownerSam = New-ImportADUser -SamAccountName $ownerSam -UPN $ownerEmail `
                    -EmailAddress $ownerEmail -Enabled $true -WhenCreatedDaysAgo 1000
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'   'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$ownerEmail' 'Recipient = EA14 owner email'
                Assert-ActionFired  'Notify' '$upn' 'Notify fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-02: Owner resolved via prefix-strip (no EA14 set)
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.prefown02'; $upn = 'admin.prefown02@corp.local'
        $ownerSam = 'prefown02'; $ownerEmail = 'prefown02@corp.local'
        @{
            Name    = '03-02: Owner resolved via prefix-strip -- notification goes to owner email'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers = @{
                # No EA14 -- owner resolved by stripping 'admin.' from SamAccountName
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                $ownerSam = New-ImportADUser -SamAccountName $ownerSam -UPN $ownerEmail `
                    -EmailAddress $ownerEmail -Enabled $true -WhenCreatedDaysAgo 1000
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'   'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$ownerEmail' 'Recipient = owner email'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-03: EA14 owner SAM not in AD -- falls through to prefix-strip
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.ea14bad03'; $upn = 'admin.ea14bad03@corp.local'
        $ownerSam = 'ea14bad03'; $ownerEmail = 'ea14bad03@corp.local'
        @{
            Name    = '03-03: EA14 owner SAM not in AD -- prefix-strip fallback succeeds'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true `
                    -ExtensionAttribute14 "owner=ghost.user"   # SAM not in mock → EA14 strategy fails
                # Prefix-strip resolves: 'admin.ea14bad03' → 'ea14bad03' → found
                $ownerSam = New-ImportADUser -SamAccountName $ownerSam -UPN $ownerEmail `
                    -EmailAddress $ownerEmail -Enabled $true -WhenCreatedDaysAgo 1000
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (fallback to prefix-strip)'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'   'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$ownerEmail' 'Recipient = prefix-strip owner email'
                Assert-ActionFired  'Notify' '$upn' 'Notify fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-04: Prefix-strip takes priority over EA14 when both resolve
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.ea14pri04'; $upn = 'admin.ea14pri04@corp.local'
        $ea14Sam = 'ea14owner04'; $ea14Email = 'ea14owner04@corp.local'
        $prefixSam = 'ea14pri04'; $prefixEmail = 'ea14pri04@corp.local'
        @{
            Name    = '03-04: Prefix-strip takes priority over EA14 when both resolve'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true `
                    -ExtensionAttribute14 "dept=Finance;owner=$ea14Sam"
                # Both the EA14 owner and the prefix-strip candidate exist in AD
                $ea14Sam   = New-ImportADUser -SamAccountName $ea14Sam -UPN $ea14Email `
                    -EmailAddress $ea14Email -Enabled $true -WhenCreatedDaysAgo 1000
                $prefixSam = New-ImportADUser -SamAccountName $prefixSam -UPN $prefixEmail `
                    -EmailAddress $prefixEmail -Enabled $true -WhenCreatedDaysAgo 1000
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'    'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$prefixEmail' 'Recipient = prefix-strip owner (not EA14)'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-06: Owner SAM resolves but EmailAddress is empty -- Skipped/NoEmailFound
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.noemail06'; $upn = 'admin.noemail06@corp.local'
        $ownerSam = 'noemail06'
        @{
            Name    = '03-06: Owner resolved but EmailAddress empty -- Skipped/NoEmailFound'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95
            )
            ADUsers = @{
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                # Owner SAM resolves via prefix-strip but has no email address set
                $ownerSam = New-ImportADUser -SamAccountName $ownerSam -UPN '' `
                    -EmailAddress '' -Enabled $true -WhenCreatedDaysAgo 1000
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'     'Skipped'      'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'NoEmailFound' 'SkipReason = NoEmailFound'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired (no email)'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-07: AD account -- prefix-strip and EA14 fail, Entra sponsor resolves
    # ------------------------------------------------------------------
    $(
        $sam = 'shared.nosam07'; $upn = 'shared.nosam07@corp.local'
        $entraId = 'oid-sponsor-ad-07'
        $sponsorEmail = 'sponsor07@corp.local'
        @{
            Name    = '03-07: AD account -- AD owner strategies fail, Entra sponsor resolves'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam -UPN $upn -InactiveDaysAgo 95 `
                    -EntraObjectId $entraId
            )
            ADUsers = @{
                # Account live check must succeed; no owner SAM in mock so prefix-strip fails
                $sam = New-ImportADUser -SamAccountName $sam -UPN $upn `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) `
                    -WhenCreatedDaysAgo 300 -Enabled $true
                # No EA14 set; no owner SAM entry
            }
            MgUserSponsors = @{
                $entraId = @(
                    [pscustomobject]@{ Mail = $sponsorEmail; UserPrincipalName = 'sponsor07-upn@corp.local' }
                )
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (sponsor resolved)'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'    'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$sponsorEmail' 'Recipient = Entra sponsor Mail'
                Assert-ActionFired  'Notify' '$upn' 'Notify fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-08: Entra-native account (no SAM) -- sponsor resolves as owner
    # ------------------------------------------------------------------
    $(
        $upn = 'adm.cloudonly08@corp.local'
        $entraId = 'oid-sponsor-entra-08'
        $sponsorUpn = 'sponsorupn08@corp.local'
        @{
            Name    = '03-08: Entra-native account (no SAM) -- sponsor resolves via UPN'
            Accounts = @(
                # No SamAccountName -- Entra-native routing
                [pscustomobject]@{
                    UserPrincipalName   = $upn
                    SamAccountName      = ''
                    LastLogonDate       = ''
                    Created             = [datetime]::UtcNow.AddDays(-400).ToString('o')
                    Enabled             = 'True'
                    EntraObjectId       = $entraId
                    entraLastSignInAEST = ''
                    Description         = ''
                }
            )
            MgUsers = @{
                $entraId = New-ImportMgUser -ObjectId $entraId -AccountEnabled $true `
                    -LastSignInDaysAgo 95
            }
            ADUsers = @{}
            MgUserSponsors = @{
                $entraId = @(
                    # Mail is empty -- orchestrator should fall back to UserPrincipalName
                    [pscustomobject]@{ Mail = ''; UserPrincipalName = $sponsorUpn }
                )
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (sponsor via UPN fallback)'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'  'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$sponsorUpn' 'Recipient = sponsor UPN'
                Assert-ActionFired  'Notify' '$upn' 'Notify fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-09: Entra-native account -- no sponsor set, NoOwnerFound
    # ------------------------------------------------------------------
    $(
        $upn = 'adm.nosponsor09@corp.local'
        $entraId = 'oid-no-sponsor-09'
        @{
            Name    = '03-09: Entra-native account -- no Entra sponsor set, NoOwnerFound'
            Accounts = @(
                [pscustomobject]@{
                    UserPrincipalName   = $upn
                    SamAccountName      = ''
                    LastLogonDate       = ''
                    Created             = [datetime]::UtcNow.AddDays(-400).ToString('o')
                    Enabled             = 'True'
                    EntraObjectId       = $entraId
                    entraLastSignInAEST = ''
                    Description         = ''
                }
            )
            MgUsers = @{
                $entraId = New-ImportMgUser -ObjectId $entraId -AccountEnabled $true `
                    -LastSignInDaysAgo 95
            }
            ADUsers       = @{}
            MgUserSponsors = @{}   # no entry for this ID → mock returns empty array
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 'NoOwner = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'     'Skipped'       'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'NoOwnerFound'  'SkipReason = NoOwnerFound'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-05: Mixed batch -- one with EA14 owner, one with no resolvable owner
    # ------------------------------------------------------------------
    $(
        $sam1 = 'admin.ea14own03a'; $upn1 = 'admin.ea14own03a@corp.local'
        $ownerSam1 = 'ea14own03a'; $ownerEmail1 = 'ea14own03a@corp.local'
        $sam2 = 'admin.noown03b';  $upn2 = 'admin.noown03b@corp.local'
        @{
            Name    = '03-05: Mixed batch -- one with EA14 owner, one with no resolvable owner'
            Accounts = @(
                New-ImportTestAccount -SamAccountName $sam1 -UPN $upn1 -InactiveDaysAgo 95
                New-ImportTestAccount -SamAccountName $sam2 -UPN $upn2 -InactiveDaysAgo 95
            )
            ADUsers = @{
                $sam1 = New-ImportADUser -SamAccountName $sam1 -UPN $upn1 `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true `
                    -ExtensionAttribute14 "owner=$ownerSam1"
                $ownerSam1 = New-ImportADUser -SamAccountName $ownerSam1 -UPN $ownerEmail1 `
                    -EmailAddress $ownerEmail1 -Enabled $true -WhenCreatedDaysAgo 1000
                # sam2 strips to 'noown03b' -- not in mock, so prefix-strip also fails
                $sam2 = New-ImportADUser -SamAccountName $sam2 -UPN $upn2 `
                    -LastLogonDate ([datetime]::UtcNow.AddDays(-95)) -WhenCreatedDaysAgo 300 -Enabled $true
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned'  1 'Warned = 1 (only owner-resolved account notified)'
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1 (NoOwnerFound)'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 'NoOwner = 1'
                Assert-ResultField  `$result.Results '$upn1' 'Status'     'Completed'   'upn1 Status = Completed'
                Assert-ResultField  `$result.Results '$upn2' 'Status'     'Skipped'     'upn2 Status = Skipped'
                Assert-ResultField  `$result.Results '$upn2' 'SkipReason' 'NoOwnerFound' 'upn2 SkipReason = NoOwnerFound'
                Assert-ActionFired    'Notify' '$upn1' 'Notify fired for upn1'
                Assert-ActionNotFired 'Notify' '$upn2' 'No Notify for upn2 (no owner)'
"@)
        }
    )

)
