function Set-Mocks {
    <#
    .SYNOPSIS
        Installs mock functions into the IdentityLifecycle module scope for testing
        Invoke-InactiveAccountRemediation in both import and discovery modes.

    .DESCRIPTION
        Inject mocks via & (Get-Module ...) { } so they land in the module's script:
        scope where the orchestrator can call them. Global: overrides do NOT reach
        inside a module loaded with Import-Module.

        A single $MockContext hashtable is shared by reference. Scenario code mutates
        keys between calls; no re-install needed.

        $MockContext keys:
            ADAccountList    - pscustomobject[] returned by Get-PrefixedADAccounts
                               (objects shaped like New-DiscoveryADAccount output)
            EntraAccountList - pscustomobject[] returned by Get-PrefixedEntraAccounts
                               (objects shaped like New-DiscoveryEntraAccount output)
            ADUsers          - hashtable of SamAccountName (lower) -> fake ADUser object
                               Used for ALL Get-ADUser calls:
                                 import mode  -- live check + owner resolution + email
                                 discovery mode -- owner resolution + email
            MgUsers          - hashtable of EntraObjectId (lower) -> fake MgUser object
                               Used by import mode live check (Get-MgUser)
            MgUserSponsors   - hashtable of EntraObjectId (lower) -> pscustomobject[]
                               Each sponsor object should have Mail and/or UserPrincipalName.
                               $null or missing key = no sponsors (empty result).
            Actions          - List[pscustomobject] of captured action records
                               { Action, UPN, Stage, Recipient }
            NotifyFail        - string[] of UPNs for which Send-GraphMail throws
            DisableFail       - string[] of UPNs for which Disable-InactiveAccount fails
            RemoveFail        - string[] of UPNs for which Remove-InactiveAccount fails
            ConnectFail       - $true to make Connect-MgGraph throw
            ADAccountListFail - $true to make Get-PrefixedADAccounts throw
            MidBatchAbortOnUPN - string[] of UPNs for which Get-ADAccountOwner throws bare,
                               aborting the foreach loop mid-batch so remaining accounts
                               are never reached (tests the "never reached" Unprocessed path)

        Functions overridden or run for real:
            Get-ADAccountOwner               - OVERRIDDEN in module scope; runs real prefix-strip +
                                               EA14 logic for most accounts; throws bare (escaping
                                               the per-account try/catch) for SAMs listed in
                                               MidBatchAbortOnUPN (tests "never reached" Unprocessed path)
            New-InactiveAccountLifecycleMessage - exercised (runs for real)
            Resolve-EntraSignIn              - sign-in max logic exercised (import mode, runs for real)
            ConvertTo-Bool                   - inline helper, exercised (import mode, runs for real)
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable] $MockContext
    )

    $module = Get-Module IdentityLifecycle
    if ($null -eq $module) {
        throw 'IdentityLifecycle module is not loaded. Run Import-Module before calling Set-Mocks.'
    }

    $module.SessionState.PSVariable.Set('RemediationMockCtx', $MockContext)

    & $module {

        # -------------------------------------------------------------------
        # Connect-MgGraph / Disconnect-MgGraph mocks
        # -------------------------------------------------------------------
        function script:Connect-MgGraph {
            param($ClientId, $TenantId, $CertificateThumbprint, $Scopes, [switch]$NoWelcome, $ErrorAction)
            $ctx = $script:RemediationMockCtx
            if ($ctx.ConnectFail) {
                throw 'Mock: Connect-MgGraph forced failure'
            }
        }

        function script:Disconnect-MgGraph {
            param([string]$ErrorAction)
        }

        # -------------------------------------------------------------------
        # Get-PrefixedADAccounts mock (discovery mode)
        # Returns the full ADAccountList regardless of prefix/search base.
        # -------------------------------------------------------------------
        function script:Get-PrefixedADAccounts {
            param($Prefixes, $SearchBase)
            $ctx = $script:RemediationMockCtx
            if ($ctx.ADAccountListFail) {
                throw 'Mock: Get-PrefixedADAccounts forced failure'
            }
            return @($ctx.ADAccountList)
        }

        # -------------------------------------------------------------------
        # Get-PrefixedEntraAccounts mock (discovery mode)
        # Returns the full EntraAccountList regardless of prefix.
        # -------------------------------------------------------------------
        function script:Get-PrefixedEntraAccounts {
            param($Prefixes)
            $ctx = $script:RemediationMockCtx
            return @($ctx.EntraAccountList)
        }

        # -------------------------------------------------------------------
        # Get-ADUser mock
        # Handles both -Identity <sam> and -Filter "SamAccountName -eq '<sam>'"
        # Used for: import-mode live check, owner resolution, owner email lookup.
        # Keyed by SamAccountName (lower-cased).
        # -------------------------------------------------------------------
        function script:Get-ADUser {
            param(
                $Identity,
                [string]   $Filter,
                [string[]] $Properties,
                $SearchBase,
                $ErrorAction
            )
            $ctx = $script:RemediationMockCtx

            if ($Identity) {
                $key = $Identity.ToString().ToLower()
                $obj = $ctx.ADUsers[$key]
                if ($null -eq $obj) {
                    throw "Mock: Get-ADUser '$Identity' not found"
                }
                return $obj
            }

            if ($Filter) {
                # Expect: SamAccountName -eq '<sam>'
                if ($Filter -match "SamAccountName\s+-eq\s+'([^']+)'") {
                    $key = $Matches[1].ToLower()
                    return $ctx.ADUsers[$key]
                }
                return $null
            }

            return $null
        }

        # -------------------------------------------------------------------
        # Get-MgUser mock (import mode live check)
        # Keyed by EntraObjectId (lowercased).
        # -------------------------------------------------------------------
        function script:Get-MgUser {
            param(
                $UserId,
                [string[]] $Property,
                $ErrorAction
            )
            $ctx = $script:RemediationMockCtx
            $key = $UserId.ToString().ToLower()
            $obj = $ctx.MgUsers[$key]
            if ($null -eq $obj) {
                throw "Mock: Get-MgUser '$UserId' not found"
            }
            return $obj
        }

        # -------------------------------------------------------------------
        # Get-MgUserSponsor mock
        # Keyed by EntraObjectId (lowercased). Returns sponsor objects with
        # Mail and/or UserPrincipalName. Returns empty array when key is absent.
        # -------------------------------------------------------------------
        function script:Get-MgUserSponsor {
            param(
                $UserId,
                [string[]] $Property,
                $ErrorAction
            )
            $ctx     = $script:RemediationMockCtx
            $key     = $UserId.ToString().ToLower()
            $sponsors = $ctx.MgUserSponsors[$key]
            if ($null -eq $sponsors) { return @() }
            return @($sponsors)
        }

        # -------------------------------------------------------------------
        # Send-GraphMail mock
        # -------------------------------------------------------------------
        function script:Send-GraphMail {
            param(
                [Alias('Sender')] $From,
                $ClientID,
                $Tenant,
                $CertificateThumbprint,
                $ToRecipients,
                $Subject,
                $Body,
                $BodyType,
                $ErrorAction
            )
            $ctx = $script:RemediationMockCtx

            $upn = ''
            if ($Subject -match '--\s*(.+)$') { $upn = $Matches[1].Trim() }

            $recipient = if ($ToRecipients) { @($ToRecipients)[0] } else { '' }
            $fail      = $ctx.NotifyFail -contains $upn

            $ctx.Actions.Add([pscustomobject]@{
                Action            = 'Notify'
                UserPrincipalName = $upn
                Stage             = $null
                Recipient         = $recipient
            })

            if ($fail) {
                throw "Mock: Send-GraphMail forced failure for $upn"
            }
        }

        # -------------------------------------------------------------------
        # Disable-InactiveAccount mock
        # -------------------------------------------------------------------
        function script:Disable-InactiveAccount {
            param($Account)
            $ctx  = $script:RemediationMockCtx
            $upn  = if ($Account.UserPrincipalName) { $Account.UserPrincipalName } else { $Account.SamAccountName }
            $fail = $ctx.DisableFail -contains $upn

            $ctx.Actions.Add([pscustomobject]@{
                Action            = 'Disable'
                UserPrincipalName = $upn
                Stage             = $null
                Recipient         = $null
            })

            return [pscustomobject]@{
                Success = (-not $fail)
                Message = if ($fail) { 'Mock: forced disable failure' } else { "Mock: disabled $upn" }
            }
        }

        # -------------------------------------------------------------------
        # Remove-InactiveAccount mock
        # -------------------------------------------------------------------
        function script:Remove-InactiveAccount {
            param($Account)
            $ctx  = $script:RemediationMockCtx
            $upn  = if ($Account.UserPrincipalName) { $Account.UserPrincipalName } else { $Account.SamAccountName }
            $fail = $ctx.RemoveFail -contains $upn

            $ctx.Actions.Add([pscustomobject]@{
                Action            = 'Remove'
                UserPrincipalName = $upn
                Stage             = $null
                Recipient         = $null
            })

            return [pscustomobject]@{
                Success = (-not $fail)
                Message = if ($fail) { 'Mock: forced remove failure' } else { "Mock: removed $upn" }
            }
        }

        # -------------------------------------------------------------------
        # Get-ADAccountOwner override (mid-batch abort simulation)
        # Normally the real implementation runs for all accounts. When
        # MidBatchAbortOnUPN contains the SAM being resolved, this override
        # throws bare (no per-account try/catch wraps this call site in the
        # orchestrator), so the outer catch fires and the foreach loop aborts,
        # leaving any remaining accounts unreached -- testing source 2 of
        # the Unprocessed block (never-reached accounts).
        # For all other SAMs the real prefix-strip + EA14 logic is replicated.
        # -------------------------------------------------------------------
        function script:Get-ADAccountOwner {
            param(
                [string]   $SamAccountName,
                [string]   $ExtAttr14,
                [string[]] $Prefixes = @('admin.', 'priv.')
            )
            $ctx = $script:RemediationMockCtx
            if ($ctx.MidBatchAbortOnUPN -and $ctx.MidBatchAbortOnUPN -contains $SamAccountName) {
                throw "Mock: Get-ADAccountOwner fatal abort for '$SamAccountName'"
            }

            # Real logic: prefix strip (longest-first) then EA14
            # Prefix values include the separator (e.g. 'admin.') so no [._] in regex
            if ($SamAccountName) {
                foreach ($prefix in ($Prefixes | Sort-Object { $_.Length } -Descending)) {
                    if ($SamAccountName -match "^$([regex]::Escape($prefix))(.+)$") {
                        $candidate = $Matches[1]
                        try {
                            if (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction Stop) {
                                return [pscustomobject]@{ SamAccountName = $candidate; ResolvedBy = 'PrefixStrip' }
                            }
                        } catch {}
                        break
                    }
                }
            }
            if ($ExtAttr14) {
                foreach ($pair in ($ExtAttr14 -split ';')) {
                    if ($pair.Trim() -match '(?i)^owner=(.+)$') {
                        $candidate = $Matches[1].Trim()
                        if ($candidate) {
                            try {
                                if (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction Stop) {
                                    return [pscustomobject]@{ SamAccountName = $candidate; ResolvedBy = 'ExtensionAttribute14' }
                                }
                            } catch {}
                        }
                    }
                }
            }
            return $null
        }

    }
}
