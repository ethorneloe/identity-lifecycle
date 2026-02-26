# ---------------------------------------------------------------------------
# Import-mode helpers
# Used by scenarios that call Invoke-ImportOnce (pre-built account list input)
# ---------------------------------------------------------------------------

function New-ImportTestAccount {
    <#
    .SYNOPSIS
        Creates a CSV-shaped input row for import-mode tests.

    .PARAMETER SamAccountName
        AD SAM account name.

    .PARAMETER UPN
        User principal name (primary key in import mode).

    .PARAMETER InactiveDaysAgo
        How many days ago the last logon was. Defaults to 0 (active today).

    .PARAMETER WhenCreatedDaysAgo
        Account creation age in days. Defaults to InactiveDaysAgo + 30.
        Written to the Created field; used as a last-resort InactiveDays
        baseline when there is no logon or sign-in data at all.

    .PARAMETER AccountEnabled
        Whether the export says the account is enabled. Default $true.

    .PARAMETER EntraObjectId
        GUID string for Entra-native accounts or AD accounts enriched with Entra sign-in.

    .PARAMETER LastSignInEntra
        Optional Entra last sign-in datetime string (maps to entraLastSignInAEST export field).

    .PARAMETER Description
        Optional AD Description field.
    #>
    param(
        [string] $SamAccountName = '',

        [Parameter(Mandatory)]
        [string] $UPN,

        [int]    $InactiveDaysAgo    = 0,
        [int]    $WhenCreatedDaysAgo = -1,   # -1 = auto
        [bool]   $AccountEnabled     = $true,
        [string] $EntraObjectId      = '',
        [string] $LastSignInEntra    = '',
        [string] $Description        = ''
    )

    if ($WhenCreatedDaysAgo -lt 0) {
        $WhenCreatedDaysAgo = $InactiveDaysAgo + 30
    }

    $lastLogon = if ($InactiveDaysAgo -gt 0) {
        [datetime]::UtcNow.AddDays(-$InactiveDaysAgo).ToString('o')
    } else { '' }

    [pscustomobject]@{
        SamAccountName      = $SamAccountName
        UserPrincipalName   = $UPN
        LastLogonDate       = $lastLogon
        Created             = [datetime]::UtcNow.AddDays(-$WhenCreatedDaysAgo).ToString('o')
        Enabled             = $AccountEnabled.ToString()
        EntraObjectId       = $EntraObjectId
        entraLastSignInAEST = $LastSignInEntra
        Description         = $Description
    }
}

function New-ImportADUser {
    <#
    .SYNOPSIS
        Creates a fake ADUser object for the Get-ADUser mock in import-mode tests.

    .PARAMETER SamAccountName
        SAM; used as the hashtable key in $MockContext.ADUsers.

    .PARAMETER UPN
        UserPrincipalName / EmailAddress (used as owner email when resolved by identity).

    .PARAMETER LastLogonDate
        Live AD last logon. Null = never logged on.

    .PARAMETER WhenCreatedDaysAgo
        Account creation age in days.

    .PARAMETER Enabled
        Whether the account is enabled in AD right now. Default $true.

    .PARAMETER ExtensionAttribute14
        Raw string value of extensionAttribute14 (semicolon-delimited key=value pairs).

    .PARAMETER Description
        AD Description field.

    .PARAMETER EmailAddress
        Email address returned when the mock is queried for owner email lookup.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $SamAccountName,

        [string]             $UPN                  = '',
        [nullable[datetime]] $LastLogonDate         = $null,
        [int]                $WhenCreatedDaysAgo    = 400,
        [bool]               $Enabled               = $true,
        [string]             $ExtensionAttribute14  = '',
        [string]             $Description           = '',
        [string]             $EmailAddress          = ''
    )

    [pscustomobject]@{
        SamAccountName       = $SamAccountName
        UserPrincipalName    = $UPN
        Enabled              = $Enabled
        LastLogonDate        = $LastLogonDate
        whenCreated          = [datetime]::UtcNow.AddDays(-$WhenCreatedDaysAgo)
        extensionAttribute14 = $ExtensionAttribute14
        Description          = $Description
        EmailAddress         = if ($EmailAddress) { $EmailAddress } else { $UPN }
    }
}

function New-ImportMgUser {
    <#
    .SYNOPSIS
        Creates a fake MgUser object for the Get-MgUser mock in import-mode tests.

    .PARAMETER ObjectId
        Used as the hashtable key in $MockContext.MgUsers.

    .PARAMETER AccountEnabled
        Live Entra enabled state. Default $true.

    .PARAMETER LastSignInDaysAgo
        Days since last interactive sign-in. 0 = today. -1 = never.

    .PARAMETER CreatedDateTimeDaysAgo
        Account creation age in days.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $ObjectId,

        [bool]   $AccountEnabled         = $true,
        [int]    $LastSignInDaysAgo      = -1,   # -1 = never / no data
        [int]    $CreatedDateTimeDaysAgo = 400
    )

    $signInActivity = if ($LastSignInDaysAgo -ge 0) {
        [pscustomobject]@{
            LastSignInDateTime               = [datetime]::UtcNow.AddDays(-$LastSignInDaysAgo)
            LastNonInteractiveSignInDateTime = $null
        }
    } else {
        [pscustomobject]@{
            LastSignInDateTime               = $null
            LastNonInteractiveSignInDateTime = $null
        }
    }

    [pscustomobject]@{
        Id              = $ObjectId
        AccountEnabled  = $AccountEnabled
        SignInActivity  = $signInActivity
        CreatedDateTime = [datetime]::UtcNow.AddDays(-$CreatedDateTimeDaysAgo)
    }
}

# ---------------------------------------------------------------------------
# Discovery-mode helpers
# Used by scenarios that call Invoke-DiscoveryOnce (live AD/Entra discovery)
# ---------------------------------------------------------------------------

function New-DiscoveryADAccount {
    <#
    .SYNOPSIS
        Creates a fake object matching Get-PrefixedADAccounts output for discovery-mode tests.

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

        [int]    $LastLogonDaysAgo     = -1,    # -1 = never
        [int]    $WhenCreatedDaysAgo   = 400,
        [bool]   $Enabled              = $true,
        [string] $ExtensionAttribute14 = '',
        [string] $Description          = ''
    )

    [pscustomobject]@{
        SamAccountName       = $SamAccountName
        UserPrincipalName    = $UPN
        EntraObjectId        = [guid]::NewGuid().ToString()
        Enabled              = $Enabled
        LastLogonDate        = if ($LastLogonDaysAgo -ge 0) { [datetime]::UtcNow.AddDays(-$LastLogonDaysAgo) } else { $null }
        Created              = [datetime]::UtcNow.AddDays(-$WhenCreatedDaysAgo)
        ExtensionAttribute14 = $ExtensionAttribute14
        Description          = $Description
    }
}

function New-DiscoveryEntraAccount {
    <#
    .SYNOPSIS
        Creates a fake object matching Get-PrefixedEntraAccounts output for discovery-mode tests.

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

        [bool]   $AccountEnabled          = $true,
        [int]    $LastSignInDaysAgo       = -1,    # -1 = never
        [bool]   $OnPremisesSyncEnabled   = $false,
        [int]    $CreatedDateTimeDaysAgo  = 400
    )

    [pscustomobject]@{
        EntraObjectId         = $EntraObjectId
        UserPrincipalName     = $UPN
        Enabled               = $AccountEnabled
        OnPremisesSyncEnabled = $OnPremisesSyncEnabled
        entraLastSignInAEST   = if ($LastSignInDaysAgo -ge 0) { [datetime]::UtcNow.AddDays(-$LastSignInDaysAgo) } else { $null }
        Created               = [datetime]::UtcNow.AddDays(-$CreatedDateTimeDaysAgo)
    }
}

function New-DiscoveryOwnerADUser {
    <#
    .SYNOPSIS
        Creates a fake ADUser object for the Get-ADUser mock used during owner resolution
        in discovery-mode tests.

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
