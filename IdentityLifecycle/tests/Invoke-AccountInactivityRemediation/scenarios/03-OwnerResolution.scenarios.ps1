$Scenarios = @(

    # ------------------------------------------------------------------
    # 03-01: Owner resolved via prefix-strip (primary strategy)
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.prefown01'; $upn = 'admin.prefown01@corp.local'
        $ownerSam = 'prefown01'; $ownerEmail = 'prefown01@corp.local'
        @{
            Name     = '03-01: Owner resolved via prefix-strip (primary strategy)'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                $ownerSam = New-RemediationOwnerADUser -SamAccountName $ownerSam -EmailAddress $ownerEmail
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'    'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$ownerEmail'  'Recipient = prefix-strip owner'
                Assert-ActionFired  'Notify' '$upn' 'Notify fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-02: Owner resolved via extensionAttribute14 (no recognised prefix)
    # ------------------------------------------------------------------
    $(
        $sam = 'shared.infra02'; $upn = 'shared.infra02@corp.local'
        $ownerSam = 'infra02owner'; $ownerEmail = 'infra02owner@corp.local'
        @{
            Name     = '03-02: No prefix match -- owner resolved via extensionAttribute14 fallback'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 `
                    -WhenCreatedDaysAgo 300 -ExtensionAttribute14 "dept=OPS;owner=$ownerSam"
            )
            ADUsers  = @{
                $ownerSam = New-RemediationOwnerADUser -SamAccountName $ownerSam -EmailAddress $ownerEmail
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'   'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$ownerEmail' 'Recipient = EA14 owner'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-03: EA14 owner SAM not in AD -- prefix-strip fallback succeeds
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.ea14bad03'; $upn = 'admin.ea14bad03@corp.local'
        $ownerSam = 'ea14bad03'; $ownerEmail = 'ea14bad03@corp.local'
        @{
            Name     = '03-03: EA14 owner SAM not in AD -- prefix-strip fallback succeeds'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 `
                    -WhenCreatedDaysAgo 300 -ExtensionAttribute14 'owner=ghost.user'
            )
            ADUsers  = @{
                $ownerSam = New-RemediationOwnerADUser -SamAccountName $ownerSam -EmailAddress $ownerEmail
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (fallback to prefix-strip)'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'   'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$ownerEmail' 'Recipient = prefix-strip owner'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-04: No owner resolvable -- Skipped/NoOwnerFound
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.noown04'; $upn = 'admin.noown04@corp.local'
        @{
            Name     = '03-04: No owner resolvable -- Skipped/NoOwnerFound'
            ADAccountList = @(
                # Strips to 'noown04' -- not in ADUsers mock; no EA14
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{}   # no owner SAM in mock
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 'NoOwner = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'     'Skipped'      'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'NoOwnerFound' 'SkipReason = NoOwnerFound'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-05: Prefix-strip wins over EA14 when both resolve
    # ------------------------------------------------------------------
    $(
        $sam = 'admin.ea14pri05'; $upn = 'admin.ea14pri05@corp.local'
        $ea14Sam = 'ea14owner05'; $ea14Email = 'ea14owner05@corp.local'
        $prefixSam = 'ea14pri05'; $prefixEmail = 'ea14pri05@corp.local'
        @{
            Name     = '03-05: Prefix-strip takes priority over EA14 when both resolve'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 `
                    -WhenCreatedDaysAgo 300 -ExtensionAttribute14 "dept=Finance;owner=$ea14Sam"
            )
            ADUsers  = @{
                $ea14Sam   = New-RemediationOwnerADUser -SamAccountName $ea14Sam   -EmailAddress $ea14Email
                $prefixSam = New-RemediationOwnerADUser -SamAccountName $prefixSam -EmailAddress $prefixEmail
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$prefixEmail' 'Recipient = prefix-strip (not EA14)'
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
            Name     = '03-06: Owner resolved but EmailAddress empty -- Skipped/NoEmailFound'
            ADAccountList = @(
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 -WhenCreatedDaysAgo 300
            )
            ADUsers  = @{
                # Owner SAM resolves via prefix-strip but has no email address set
                $ownerSam = New-RemediationOwnerADUser -SamAccountName $ownerSam -EmailAddress ''
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
            Name     = '03-07: AD account -- AD owner strategies fail, Entra sponsor resolves'
            ADAccountList = @(
                # No recognised prefix → prefix-strip yields no match
                # EntraObjectId set so sponsor lookup can run
                New-RemediationADAccount -SamAccountName $sam -UPN $upn -LastLogonDaysAgo 95 `
                    -WhenCreatedDaysAgo 300
            )
            # Give the AD account an EntraObjectId by overriding the object after creation
            # The working-set builder assigns EntraObjectId from the synced Entra match.
            # Simpler: add a matching synced Entra account so the merger wires the OID in.
            EntraAccountList = @(
                New-RemediationEntraAccount -EntraObjectId $entraId -UPN $upn `
                    -AccountEnabled $true -LastSignInDaysAgo 95 -OnPremisesSyncEnabled $true
            )
            ADUsers        = @{}    # no owner SAM → prefix-strip and EA14 both fail
            MgUserSponsors = @{
                $entraId = @(
                    [pscustomobject]@{ Mail = $sponsorEmail; UserPrincipalName = 'sponsor07-upn@corp.local' }
                )
            }
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Warned' 1 'Warned = 1 (sponsor resolved)'
                Assert-ResultField  `$result.Results '$upn' 'Status'                'Completed'     'Status = Completed'
                Assert-ResultField  `$result.Results '$upn' 'NotificationRecipient' '$sponsorEmail' 'Recipient = Entra sponsor Mail'
                Assert-ActionFired  'Notify' '$upn' 'Notify fired'
"@)
        }
    ),

    # ------------------------------------------------------------------
    # 03-08: Entra-native account (no SAM) -- sponsor resolves via UPN fallback
    # ------------------------------------------------------------------
    $(
        $upn = 'adm.cloudonly08@corp.local'
        $entraId = 'oid-sponsor-entra-08'
        $sponsorUpn = 'sponsorupn08@corp.local'
        @{
            Name     = '03-08: Entra-native account (no SAM) -- sponsor resolves via UPN'
            ADAccountList    = @()
            EntraAccountList = @(
                # Cloud-native (OnPremisesSyncEnabled=$false) -- no AD counterpart
                New-RemediationEntraAccount -EntraObjectId $entraId -UPN $upn `
                    -AccountEnabled $true -LastSignInDaysAgo 95 -OnPremisesSyncEnabled $false `
                    -CreatedDateTimeDaysAgo 400
            )
            ADUsers        = @{}
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
            Name     = '03-09: Entra-native account -- no Entra sponsor set, NoOwnerFound'
            ADAccountList    = @()
            EntraAccountList = @(
                New-RemediationEntraAccount -EntraObjectId $entraId -UPN $upn `
                    -AccountEnabled $true -LastSignInDaysAgo 95 -OnPremisesSyncEnabled $false `
                    -CreatedDateTimeDaysAgo 400
            )
            ADUsers        = @{}
            MgUserSponsors = @{}   # no entry for this ID → mock returns empty array
            AssertAfterRun = [scriptblock]::Create(@"
                param(`$result, `$ctx)
                Assert-SummaryField `$result.Summary 'Skipped' 1 'Skipped = 1'
                Assert-SummaryField `$result.Summary 'NoOwner' 1 'NoOwner = 1'
                Assert-ResultField  `$result.Results '$upn' 'Status'     'Skipped'      'Status = Skipped'
                Assert-ResultField  `$result.Results '$upn' 'SkipReason' 'NoOwnerFound' 'SkipReason = NoOwnerFound'
                Assert-ActionNotFired 'Notify'  '$upn' 'No Notify fired'
                Assert-ActionNotFired 'Disable' '$upn' 'No Disable fired'
"@)
        }
    )

)
