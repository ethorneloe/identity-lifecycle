function Set-DirectMocks {
    <#
    .SYNOPSIS
        Installs mock functions into the IdentityLifecycle module scope for testing
        Invoke-DirectInactiveAccountSweep.

    .DESCRIPTION
        Inject mocks via & (Get-Module ...) { } so they land in the module's script:
        scope where the orchestrator can call them. Global: overrides do NOT reach
        inside a module loaded with Import-Module.

        A single $MockContext hashtable is shared by reference. Scenario code mutates
        keys between calls; no re-install needed.

        $MockContext keys:
            ADAccountList   - pscustomobject[] returned by Get-PrefixedADAccounts
                              (objects shaped like New-DirectADAccount output)
            EntraAccountList - pscustomobject[] returned by Get-PrefixedEntraAccounts
                              (objects shaped like New-DirectEntraAccount output)
            ADUsers         - hashtable of SamAccountName (lower) -> fake ADUser object
                              Used for owner resolution and owner email lookup (Get-ADUser)
            Actions         - List[pscustomobject] of captured action records
                              { Action, UPN, Stage, Recipient }
            NotifyFail      - string[] of UPNs for which Send-GraphMail throws
            DisableFail     - string[] of UPNs for which Disable-InactiveAccount fails
            RemoveFail      - string[] of UPNs for which Remove-InactiveAccount fails
            ConnectFail     - $true to make Connect-MgGraph throw (tests fatal setup failure)

        Functions that run for real (not mocked):
            Get-ADAccountOwner               - exercised via mocked Get-ADUser
            New-InactiveAccountLifecycleMessage - exercised
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable] $MockContext
    )

    $module = Get-Module IdentityLifecycle
    if ($null -eq $module) {
        throw 'IdentityLifecycle module is not loaded. Run Import-Module before calling Set-DirectMocks.'
    }

    $module.SessionState.PSVariable.Set('DirectMockCtx', $MockContext)

    & $module {

        # -------------------------------------------------------------------
        # Connect-MgGraph / Disconnect-MgGraph mocks
        # -------------------------------------------------------------------
        function script:Connect-MgGraph {
            param($ClientId, $TenantId, $CertificateThumbprint, $Scopes, [switch]$NoWelcome, $ErrorAction)
            $ctx = $script:DirectMockCtx
            if ($ctx.ConnectFail) {
                throw 'Mock: Connect-MgGraph forced failure'
            }
        }

        function script:Disconnect-MgGraph {
            param([switch]$ErrorAction)
        }

        # -------------------------------------------------------------------
        # Get-PrefixedADAccounts mock
        # Returns the full ADAccountList regardless of prefix/search base.
        # Tests control what accounts exist by populating ADAccountList.
        # -------------------------------------------------------------------
        function script:Get-PrefixedADAccounts {
            param($Prefixes, $SearchBase)
            $ctx = $script:DirectMockCtx
            if ($ctx.ADAccountListFail) {
                throw 'Mock: Get-PrefixedADAccounts forced failure'
            }
            return @($ctx.ADAccountList)
        }

        # -------------------------------------------------------------------
        # Get-PrefixedEntraAccounts mock
        # Returns the full EntraAccountList regardless of prefix.
        # -------------------------------------------------------------------
        function script:Get-PrefixedEntraAccounts {
            param($Prefixes)
            $ctx = $script:DirectMockCtx
            return @($ctx.EntraAccountList)
        }

        # -------------------------------------------------------------------
        # Get-ADUser mock
        # Used for owner resolution (Get-ADAccountOwner calls -Identity and -Filter)
        # and owner email lookup. Keyed by SamAccountName (lower-cased).
        # -------------------------------------------------------------------
        function script:Get-ADUser {
            param(
                $Identity,
                [string]   $Filter,
                [string[]] $Properties,
                $SearchBase,
                $ErrorAction
            )
            $ctx = $script:DirectMockCtx

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
        # Send-GraphMail mock
        # -------------------------------------------------------------------
        function script:Send-GraphMail {
            param(
                [Alias('Sender')] $From,
                $ToRecipients,
                $Subject,
                $Body,
                $BodyType,
                $ErrorAction
            )
            $ctx = $script:DirectMockCtx

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
            $ctx  = $script:DirectMockCtx
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
            $ctx  = $script:DirectMockCtx
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
