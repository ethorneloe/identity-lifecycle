function Remove-InactiveAccount {
    <#
    .SYNOPSIS
        Removes an inactive account from Entra ID or AD.

    .DESCRIPTION
        The deletion strategy differs by account source:

        Entra-native accounts (Source = 'Entra'):
            Remove-MgUser is called directly. The account moves to the Entra recycle bin
            and is permanently purged after 30 days unless manually restored. If immediate
            permanent deletion is required, a second call to Remove-MgDirectoryDeletedItem
            can be added.

        AD accounts (Source = 'AD'):
            Implementation pending. The current stub throws an exception so the
            orchestrator records an error and does not write a Deletion state row.
            Replace the stub with your organisation's AD offboarding workflow.

    .PARAMETER Account
        A working set account object passed by the orchestrator.

    .OUTPUTS
        [pscustomobject] with fields:
            Success - bool
            Message - description of what was done or what failed

    .EXAMPLE
        $result = Remove-InactiveAccount -Account $account
        if (-not $result.Success) { Write-Warning $result.Message }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Account
    )

    $target = if ($null -ne $Account.UserPrincipalName) { $Account.UserPrincipalName } else { $Account.SamAccountName }

    try {

        # --- Entra-native: direct deletion via Graph ---
        if ($Account.Source -eq 'Entra') {

            if ($PSCmdlet.ShouldProcess($target, "Delete Entra account")) {
                Remove-MgUser -UserId $Account.EntraObjectId -ErrorAction Stop
            }

            return [pscustomobject]@{
                Success = $true
                Message = "Entra account deleted (moved to recycle bin): $target"
            }
        }

        # --- AD account: implementation pending ---
        # AD deletion typically requires raising a request through an identity
        # governance tool (e.g. MIM, SailPoint) rather than calling Remove-ADUser
        # directly, to preserve audit trails and enforce approval workflows.
        # Replace the block below with your organisation's AD offboarding process.
        if ($Account.Source -eq 'AD') {

            if ($PSCmdlet.ShouldProcess($target, "Delete AD account")) {
                throw "AD account deletion is not yet implemented for: $target"
            }

            return [pscustomobject]@{
                Success = $true
                Message = "AD account deletion submitted: $target"
            }
        }

        return [pscustomobject]@{
            Success = $false
            Message = "Unknown account source '$($Account.Source)' for: $target"
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Message = "Failed to process deletion for '$target'. Error: $_"
        }
    }
}
