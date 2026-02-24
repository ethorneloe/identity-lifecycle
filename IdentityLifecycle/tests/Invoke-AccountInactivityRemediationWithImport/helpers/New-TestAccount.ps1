function New-ImportTestAccount {
    <#
    .SYNOPSIS
        Creates a CSV-shaped input row for Invoke-AccountInactivityRemediationWithImport tests.

    .PARAMETER SamAccountName
        AD SAM account name.

    .PARAMETER UPN
        User principal name (primary key in the WithImport sweep).

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
        [Parameter(Mandatory)]
        [string] $SamAccountName,

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
        Creates a fake ADUser object for the Get-ADUser mock in WithImport sweep tests.

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

        [string]         $UPN                 = '',
        [nullable[datetime]] $LastLogonDate   = $null,
        [int]            $WhenCreatedDaysAgo  = 400,
        [bool]           $Enabled             = $true,
        [string]         $ExtensionAttribute14 = '',
        [string]         $Description         = '',
        [string]         $EmailAddress        = ''
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
        Creates a fake MgUser object for the Get-MgUser mock in WithImport sweep tests.

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

        [bool]   $AccountEnabled          = $true,
        [int]    $LastSignInDaysAgo       = -1,   # -1 = never / no data
        [int]    $CreatedDateTimeDaysAgo  = 400
    )

    $signInActivity = if ($LastSignInDaysAgo -ge 0) {
        [pscustomobject]@{
            LastSignInDateTime              = [datetime]::UtcNow.AddDays(-$LastSignInDaysAgo)
            LastNonInteractiveSignInDateTime = $null
        }
    } else {
        [pscustomobject]@{
            LastSignInDateTime              = $null
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
