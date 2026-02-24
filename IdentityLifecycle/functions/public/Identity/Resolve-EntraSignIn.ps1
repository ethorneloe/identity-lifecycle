function Resolve-EntraSignIn {
    <#
    .SYNOPSIS
        Returns the most recent sign-in DateTime from a Microsoft Graph user object,
        considering both interactive and non-interactive sign-in activity.

    .DESCRIPTION
        Entra ID tracks sign-in activity in two separate fields on the SignInActivity
        property: LastSignInDateTime (interactive) and LastNonInteractiveSignInDateTime
        (token refreshes, service-to-service, etc.). For inactivity detection we want
        the most recent of the two -- an account that hasn't signed in interactively but
        is still refreshing tokens is still active.

        Returns $null if the user object is null, has no SignInActivity, or both
        timestamps are null. A null return means no sign-in data is available from
        Entra, not that the account has never been used -- callers should also consider
        AD lastLogonTimestamp before concluding the account is inactive.

    .PARAMETER MgUserObj
        A user object returned by Get-MgUser with the SignInActivity property populated.
        Pass $null safely -- the function will return $null without throwing.

    .OUTPUTS
        [datetime] or $null.

    .EXAMPLE
        $lastSeen = Resolve-EntraSignIn -MgUserObj $mgUser
        if (-not $lastSeen) { Write-Verbose "No Entra sign-in data available." }
    #>
    [CmdletBinding()]
    [OutputType([nullable[datetime]])]
    param(
        [Parameter()]
        [object] $MgUserObj
    )

    if (-not $MgUserObj) { return $null }

    $times = @(
        $MgUserObj.SignInActivity.LastSignInDateTime,
        $MgUserObj.SignInActivity.LastNonInteractiveSignInDateTime
    ) | Where-Object { $_ }

    if ($times) { return ($times | Measure-Object -Maximum).Maximum }

    return $null
}
