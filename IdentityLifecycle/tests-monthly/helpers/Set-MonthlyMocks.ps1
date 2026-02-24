function Set-MonthlyMocks {
    <#
    .SYNOPSIS
        Installs mock functions into the IdentityLifecycle module scope for testing
        Invoke-MonthlyInactiveAccountSweep.

    .DESCRIPTION
        Inject mocks via & (Get-Module ...) { } so they land in the module's script:
        scope where the orchestrator can call them. Global: overrides do NOT reach
        inside a module loaded with Import-Module.

        A single $MockContext hashtable is shared by reference. Scenario code mutates
        keys between calls; no re-install needed.

        $MockContext keys:
            ADUsers       - hashtable of SamAccountName (lower) -> fake ADUser object
                            Used for ALL Get-ADUser calls (live check + owner + email)
            MgUsers       - hashtable of EntraObjectId (lower) -> fake MgUser object
            Actions       - List[pscustomobject] of captured action records
                            { Action, UPN, Stage, Recipient }
            NotifyFail    - string[] of UPNs for which Send-GraphMail throws
            DisableFail   - string[] of UPNs for which Disable-InactiveAccount fails
            RemoveFail    - string[] of UPNs for which Remove-InactiveAccount fails
            ConnectFail   - $true to make Connect-MgGraph throw (tests fatal setup failure)

        Functions that run for real (not mocked):
            Resolve-EntraSignIn   - sign-in max logic exercised
            ConvertTo-Bool        - inline helper, exercised
            Get-ADAccountOwner    - public function, exercised via mocked Get-ADUser
            New-InactiveAccountLifecycleMessage - public function, exercised
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable] $MockContext
    )

    $module = Get-Module IdentityLifecycle
    if ($null -eq $module) {
        throw 'IdentityLifecycle module is not loaded. Run Import-Module before calling Set-MonthlyMocks.'
    }

    $module.SessionState.PSVariable.Set('MonthlyMockCtx', $MockContext)

    & $module {

        # -------------------------------------------------------------------
        # Connect-MgGraph / Disconnect-MgGraph mocks
        # -------------------------------------------------------------------
        function script:Connect-MgGraph {
            param($ClientId, $TenantId, $CertificateThumbprint, $Scopes, [switch]$NoWelcome, $ErrorAction)
            $ctx = $script:MonthlyMockCtx
            if ($ctx.ConnectFail) {
                throw 'Mock: Connect-MgGraph forced failure'
            }
        }

        function script:Disconnect-MgGraph {
            param([switch]$ErrorAction)
        }

        # -------------------------------------------------------------------
        # Get-ADUser mock
        # Handles both -Identity <sam> and -Filter "SamAccountName -eq '<sam>'"
        # (used for live check AND owner verification AND owner email lookup)
        # -------------------------------------------------------------------
        function script:Get-ADUser {
            param(
                $Identity,
                [string]   $Filter,
                [string[]] $Properties,
                $SearchBase,
                $ErrorAction
            )
            $ctx = $script:MonthlyMockCtx

            if ($Identity) {
                $key = $Identity.ToString().ToLower()
                $obj = $ctx.ADUsers[$key]
                if ($null -eq $obj) {
                    # Simulate account not found
                    throw "Mock: Get-ADUser '$Identity' not found"
                }
                return $obj
            }

            if ($Filter) {
                # Expect filters of the form: SamAccountName -eq '<sam>'
                if ($Filter -match "SamAccountName\s+-eq\s+'([^']+)'") {
                    $key = $Matches[1].ToLower()
                    $obj = $ctx.ADUsers[$key]
                    if ($null -eq $obj) { return $null }
                    return $obj
                }
                return $null
            }

            return $null
        }

        # -------------------------------------------------------------------
        # Get-MgUser mock
        # Keyed by EntraObjectId (lowercased)
        # -------------------------------------------------------------------
        function script:Get-MgUser {
            param(
                $UserId,
                [string[]] $Property,
                $ErrorAction
            )
            $ctx = $script:MonthlyMockCtx
            $key = $UserId.ToString().ToLower()
            $obj = $ctx.MgUsers[$key]
            if ($null -eq $obj) {
                throw "Mock: Get-MgUser '$UserId' not found"
            }
            return $obj
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
            $ctx = $script:MonthlyMockCtx

            # Derive UPN from subject (contains account UPN after '--')
            $upn = ''
            if ($Subject -match '--\s*(.+)$') { $upn = $Matches[1].Trim() }

            $recipient = if ($ToRecipients) { @($ToRecipients)[0] } else { '' }
            $fail      = $ctx.NotifyFail -contains $upn

            $ctx.Actions.Add([pscustomobject]@{
                Action    = 'Notify'
                UPN       = $upn
                Stage     = $null      # stage not in GraphMail call; captured via Subject
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
            $ctx = $script:MonthlyMockCtx
            $upn = if ($Account.UPN) { $Account.UPN } else { $Account.SamAccountName }
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
            $ctx = $script:MonthlyMockCtx
            $upn = if ($Account.UPN) { $Account.UPN } else { $Account.SamAccountName }
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
