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
            NotifyFail       - string[] of UPNs for which Send-GraphMail throws
            DisableFail      - string[] of UPNs for which Disable-InactiveAccount fails
            RemoveFail       - string[] of UPNs for which Remove-InactiveAccount fails
            ConnectFail      - $true to make Connect-MgGraph throw
            ADAccountListFail - $true to make Get-PrefixedADAccounts throw

        Functions that run for real (not mocked):
            Get-ADAccountOwner               - exercised via mocked Get-ADUser
            New-InactiveAccountLifecycleMessage - exercised
            Resolve-EntraSignIn              - sign-in max logic exercised (import mode)
            ConvertTo-Bool                   - inline helper, exercised (import mode)
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
                Action    = 'Notify'
                UPN       = $upn
                Stage     = $null
                Recipient = $recipient
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
            $upn  = if ($Account.UPN) { $Account.UPN } else { $Account.SamAccountName }
            $fail = $ctx.DisableFail -contains $upn

            $ctx.Actions.Add([pscustomobject]@{
                Action    = 'Disable'
                UPN       = $upn
                Stage     = $null
                Recipient = $null
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
            $upn  = if ($Account.UPN) { $Account.UPN } else { $Account.SamAccountName }
            $fail = $ctx.RemoveFail -contains $upn

            $ctx.Actions.Add([pscustomobject]@{
                Action    = 'Remove'
                UPN       = $upn
                Stage     = $null
                Recipient = $null
            })

            return [pscustomobject]@{
                Success = (-not $fail)
                Message = if ($fail) { 'Mock: forced remove failure' } else { "Mock: removed $upn" }
            }
        }

    }
}
