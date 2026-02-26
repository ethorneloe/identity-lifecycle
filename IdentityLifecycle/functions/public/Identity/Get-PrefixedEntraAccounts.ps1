function Get-PrefixedEntraAccounts {
    <#
    .SYNOPSIS
        Queries Microsoft Entra ID (via Microsoft Graph) for accounts matching one or
        more UPN prefixes and returns a normalised list of account objects.

    .DESCRIPTION
        Microsoft Graph does not support OR across startsWith predicates in a single
        filter expression, so this function issues one query per prefix and deduplicates
        results by object ID before returning.

        OnPremisesSyncEnabled is included so the merge layer (Get-PrefixedAccounts) can
        distinguish cloud-native accounts from AD-synced accounts. Synced accounts are
        authoritative in AD and will be merged there; this function returns all accounts
        and lets the caller decide what to do with each.

        SignInActivity is requested explicitly as it is not returned by default and
        requires the AuditLog.Read.All or Reports.Read.All permission.

    .PARAMETER Prefixes
        One or more UPN prefixes, e.g. @('admin','priv').

    .OUTPUTS
        [pscustomobject] with fields: EntraObjectId, UserPrincipalName, Enabled,
        OnPremisesSyncEnabled, entraLastSignInAEST, Created.

    .EXAMPLE
        $entraAccounts = Get-PrefixedEntraAccounts -Prefixes @('admin','priv')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Prefixes
    )

    $entraById = @{}

    foreach ($prefix in $Prefixes) {
        Write-Verbose "Querying Entra for prefix '$prefix'..."

        $results = Get-MgUser `
            -Filter "startsWith(userPrincipalName,'$prefix')" `
            -Property 'Id,UserPrincipalName,AccountEnabled,OnPremisesSyncEnabled,SignInActivity,CreatedDateTime' `
            -All `
            -ErrorAction Stop

        foreach ($user in $results) {
            $entraById[$user.Id] = $user
        }
    }

    Write-Verbose "Entra accounts found: $($entraById.Count) (including synced)"

    foreach ($user in $entraById.Values) {
        [pscustomobject]@{
            EntraObjectId         = $user.Id
            UserPrincipalName     = $user.UserPrincipalName
            Enabled               = $user.AccountEnabled
            OnPremisesSyncEnabled = [bool]$user.OnPremisesSyncEnabled
            entraLastSignInAEST   = Resolve-EntraSignIn $user
            Created               = $user.CreatedDateTime
        }
    }
}
