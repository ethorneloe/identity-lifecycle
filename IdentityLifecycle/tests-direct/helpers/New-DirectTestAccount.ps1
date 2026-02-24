function New-DirectADAccount {
    <#
    .SYNOPSIS
        Creates a fake object matching Get-PrefixedADAccounts output for direct sweep tests.

    .DESCRIPTION
        The direct sweep discovers accounts via Get-PrefixedADAccounts, which returns
        a flat list of lightweight objects. This helper builds one such object for use
        in the ADAccountList mock context key.

    .PARAMETER SamAccountName
        SAM; used as both the account identity and the mock lookup key.

    .PARAMETER UPN
        UserPrincipalName.

    .PARAMETER LastLogonDaysAgo
        Days since last AD logon. -1 = never logged on (null).

    .PARAMETER WhenCreatedDaysAgo
        Account creation age in days.

    .PARAMETER Enabled
        Whether the account is enabled in AD. Default $true.

    .PARAMETER ExtensionAttribute14
        Raw semicolon-delimited key=value string, e.g. 'owner=jsmith;dept=IT'.

    .PARAMETER Description
        AD Description field.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $SamAccountName,

        [Parameter(Mandatory)]
        [string] $UPN,

        [int]    $LastLogonDaysAgo      = -1,    # -1 = never
        [int]    $WhenCreatedDaysAgo    = 400,
        [bool]   $Enabled               = $true,
        [string] $ExtensionAttribute14  = '',
        [string] $Description           = ''
    )

    [pscustomobject]@{
        SamAccountName       = $SamAccountName
        UPN                  = $UPN
        ObjectId             = [guid]::NewGuid().ToString()
        Enabled              = $Enabled
        LastLogonAD          = if ($LastLogonDaysAgo -ge 0) { [datetime]::UtcNow.AddDays(-$LastLogonDaysAgo) } else { $null }
        Created              = [datetime]::UtcNow.AddDays(-$WhenCreatedDaysAgo)
        ExtensionAttribute14 = $ExtensionAttribute14
        Description          = $Description
    }
}

function New-DirectEntraAccount {
    <#
    .SYNOPSIS
        Creates a fake object matching Get-PrefixedEntraAccounts output for direct sweep tests.

    .DESCRIPTION
        Represents a cloud-native (non-synced) Entra account as returned by
        Get-PrefixedEntraAccounts. Set OnPremisesSyncEnabled=$true to simulate a
        synced account (it will be merged with its AD counterpart and not added separately).

    .PARAMETER EntraObjectId
        Entra object GUID string.

    .PARAMETER UPN
        UserPrincipalName.

    .PARAMETER AccountEnabled
        Live Entra enabled state. Default $true.

    .PARAMETER LastSignInDaysAgo
        Days since last sign-in. -1 = never signed in (null).

    .PARAMETER OnPremisesSyncEnabled
        $true for synced accounts (merged with AD counterpart); $false for cloud-native.

    .PARAMETER CreatedDateTimeDaysAgo
        Account creation age in days.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $EntraObjectId,

        [Parameter(Mandatory)]
        [string] $UPN,

        [bool]   $AccountEnabled           = $true,
        [int]    $LastSignInDaysAgo        = -1,    # -1 = never
        [bool]   $OnPremisesSyncEnabled    = $false,
        [int]    $CreatedDateTimeDaysAgo   = 400
    )

    [pscustomobject]@{
        EntraObjectId         = $EntraObjectId
        UPN                   = $UPN
        AccountEnabled        = $AccountEnabled
        OnPremisesSyncEnabled = $OnPremisesSyncEnabled
        LastSignInEntra       = if ($LastSignInDaysAgo -ge 0) { [datetime]::UtcNow.AddDays(-$LastSignInDaysAgo) } else { $null }
        Created               = [datetime]::UtcNow.AddDays(-$CreatedDateTimeDaysAgo)
    }
}

function New-DirectOwnerADUser {
    <#
    .SYNOPSIS
        Creates a fake ADUser object for the Get-ADUser mock used during owner resolution.

    .DESCRIPTION
        Owner resolution calls Get-ADUser -Identity <sam> and Get-ADUser -Filter
        "SamAccountName -eq '<sam>'". This helper builds the fake object for those calls.
        Keyed in $MockContext.ADUsers by SamAccountName (lower-cased).

    .PARAMETER SamAccountName
        SAM; used as the hashtable key.

    .PARAMETER EmailAddress
        Email address returned for owner email lookup.

    .PARAMETER Enabled
        AD enabled state.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $SamAccountName,

        [string] $EmailAddress = '',
        [bool]   $Enabled      = $true
    )

    [pscustomobject]@{
        SamAccountName       = $SamAccountName
        UserPrincipalName    = $EmailAddress
        Enabled              = $Enabled
        LastLogonDate        = $null
        whenCreated          = [datetime]::UtcNow.AddDays(-400)
        extensionAttribute14 = ''
        Description          = ''
        EmailAddress         = $EmailAddress
    }
}
