function Get-PrefixedADAccounts {
    <#
    .SYNOPSIS
        Queries Active Directory for accounts matching one or more SAMAccountName
        prefixes and returns a normalised list of account objects.

    .DESCRIPTION
        Builds a single AD filter covering all requested prefixes and returns a
        flat list of lightweight objects containing only the fields needed by the
        identity merge layer (Get-PrefixedAccounts).

        LastLogonDate is used as the activity signal. This is a replicated
        attribute -- it can lag by up to 14 days by default -- but is sufficient
        for inactivity detection at 90+ day thresholds.

        ObjectGUID is returned as a string to keep the working set type-consistent
        and avoid downstream [Guid] vs [string] comparison issues.

    .PARAMETER Prefixes
        One or more SAMAccountName prefixes, e.g. @('admin','priv').

    .PARAMETER SearchBase
        Distinguished name of the OU to scope the search.

    .OUTPUTS
        [pscustomobject] with fields: SamAccountName, UPN, ObjectId, Enabled, LastLogonAD, Created,
        ExtensionAttribute14, Description.

    .EXAMPLE
        $adAccounts = Get-PrefixedADAccounts -Prefixes @('admin','priv') `
                                             -SearchBase 'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Prefixes,

        [Parameter(Mandatory)]
        [string] $SearchBase
    )

    $adFilter = ($Prefixes | ForEach-Object { "SamAccountName -like '$_*'" }) -join ' -or '

    Write-Verbose "Querying AD with filter: $adFilter"

    $adUsers = @(
        Get-ADUser -Filter $adFilter `
                   -SearchBase $SearchBase `
                   -Properties SamAccountName, UserPrincipalName, Enabled, LastLogonDate, whenCreated, extensionAttribute14, Description `
                   -ErrorAction Stop
    )

    Write-Verbose "AD accounts found: $($adUsers.Count)"

    foreach ($user in $adUsers) {
        [pscustomobject]@{
            SamAccountName       = $user.SamAccountName
            UPN                  = $user.UserPrincipalName
            ObjectId             = $user.ObjectGUID.ToString()
            Enabled              = $user.Enabled
            LastLogonAD          = $user.LastLogonDate
            Created              = $user.whenCreated
            ExtensionAttribute14 = $user.extensionAttribute14
            Description          = $user.Description
        }
    }
}
