function Disable-InactiveAccount {
    <#
    .SYNOPSIS
        Disables an inactive account in Active Directory, Entra ID, or both,
        depending on the account source.

    .DESCRIPTION
        For AD accounts, Disable-ADAccount is called against the ObjectId (ObjectGUID).
        For Entra-native accounts, Update-MgUser is called to set AccountEnabled to $false.
        For synced AD accounts, only the AD disable is performed -- Entra will reflect the
        change on the next sync cycle.

        This function does not update the state table. The orchestrator is responsible
        for calling Set-InactiveAccountStateRow after a successful disable so that all
        state writes happen in one consistent place.

    .PARAMETER Account
        A working set account object from Get-PrefixedAccounts.

    .OUTPUTS
        [pscustomobject] with fields:
            Success - bool
            Message - description of what was done or what failed

    .EXAMPLE
        $result = Disable-InactiveAccount -Account $account
        if ($result.Success) {
            Set-InactiveAccountStateRow -Upn $account.UserPrincipalName -Stage 'Disabled' ...
        }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Account
    )

    $target = if ($null -ne $Account.UserPrincipalName) { $Account.UserPrincipalName } else { $Account.SamAccountName }

    try {
        if ($Account.Source -eq 'AD') {

            if ($PSCmdlet.ShouldProcess($target, "Disable AD account")) {
                Disable-ADAccount -Identity $Account.SamAccountName -ErrorAction Stop
            }

            return [pscustomobject]@{
                Success = $true
                Message = "AD account disabled: $target"
            }
        }

        if ($Account.Source -eq 'Entra') {

            if ($PSCmdlet.ShouldProcess($target, "Disable Entra account")) {
                Update-MgUser -UserId $Account.EntraObjectId -AccountEnabled $false -ErrorAction Stop
            }

            return [pscustomobject]@{
                Success = $true
                Message = "Entra account disabled: $target"
            }
        }

        return [pscustomobject]@{
            Success = $false
            Message = "Unknown source '$($Account.Source)' for account: $target"
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Message = "Failed to disable account '$target'. Error: $_"
        }
    }
}
