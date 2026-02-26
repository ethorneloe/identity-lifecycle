function Invoke-AccountInactivityRemediation {
    <#
    .SYNOPSIS
        Stateless sweep that discovers inactive privileged accounts directly from AD and
        Entra ID by prefix, then evaluates each against absolute inactivity thresholds
        and takes the required action in a single pass.

    .DESCRIPTION
        Discovers privileged accounts directly from AD and Entra ID at runtime using
        Get-PrefixedADAccounts and Get-PrefixedEntraAccounts, then evaluates each account
        against absolute inactivity thresholds in a single pass:

            WarnThreshold    (default 90)  -- send Warning notification, no account change
            DisableThreshold (default 120) -- disable account, send Disabled notification
            DeleteThreshold  (default 180) -- delete account, send Deletion notification

        AD-synced Entra accounts are merged with their AD counterpart. Cloud-native Entra
        accounts are included as separate entries. Because data comes from the live
        directory, no additional freshness re-query is performed.

        PREREQUISITES
        The following modules must be available and will be imported automatically:
            - ActiveDirectory (RSAT)
            - Microsoft.Graph.Authentication
            - Microsoft.Graph.Users
            - Microsoft.Graph.Identity.SignIns

        GRAPH SESSION
        Connects to Graph at startup and disconnects in finally, unless
        -UseExistingGraphSession is set (caller manages the session lifecycle).

        OWNER RESOLUTION
        Owner is resolved in order:
            1. Prefix strip -- strip the leading prefix from the SAM (or UPN local-part
               for Entra-native accounts) and verify the resulting SAM exists in AD.
            2. Extension attribute -- parse 'owner=<sam>' from semicolon-delimited pairs.
               extensionAttribute14 is used as it tends to be spare; swap it in
               Get-ADAccountOwner for whichever attribute your org uses.
            3. Entra sponsor -- when both AD strategies fail and the account has an
               EntraObjectId, the sponsor relationship is queried via Get-MgUserSponsor.
               The first sponsor's Mail address (or UPN) is used as the recipient.
        If no strategy resolves, the account is skipped with SkipReason='NoOwnerFound'.

        OUTPUT
        Never throws. Success, Error, Summary, and Results are always returned. Partial
        results are preserved on mid-batch failure via the finally block.

    .PARAMETER Prefixes
        One or more SAMAccountName / UPN prefixes to target, e.g. @('admin','priv').
        Passed to both Get-PrefixedADAccounts and Get-PrefixedEntraAccounts.

    .PARAMETER ADSearchBase
        Distinguished name of the OU to scope the AD search, e.g.
        'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au'.

    .PARAMETER MailSender
        Mailbox UPN from which notification emails are sent (the 'From' address).

    .PARAMETER MailClientId
        Application (client) ID of the service principal used by Send-GraphMail.
        This is a separate registration from the Graph read principal.

    .PARAMETER MailTenantId
        Entra tenant ID for the mail service principal.

    .PARAMETER MailCertificateThumbprint
        Thumbprint of the certificate used to authenticate the mail service principal.

    .PARAMETER WarnThreshold
        Minimum inactivity days to trigger a Warning notification. Default: 90.

    .PARAMETER DisableThreshold
        Minimum inactivity days to disable the account and send a Disabled notification.
        Default: 120.

    .PARAMETER DeleteThreshold
        Minimum inactivity days to delete the account and send a Deletion notification.
        Default: 180.

    .PARAMETER EnableDeletion
        When not set, accounts at or above DeleteThreshold are disabled (if not already)
        and a Deletion notification is sent, but Remove-InactiveAccount is not called.
        Set this switch to enable actual account deletion.

    .PARAMETER ClientId
        (Certificate) Azure AD application client ID for certificate-based authentication.

    .PARAMETER TenantId
        (Certificate) The Entra tenant ID.

    .PARAMETER CertificateThumbprint
        (Certificate) Thumbprint of the certificate in the local certificate store.

    .PARAMETER NotificationRecipientOverride
        When set, all notifications are sent to this address instead of the resolved owner.
        Owner resolution still runs and the real owner address is still recorded in
        NotificationRecipient in the output for auditability. Use this during testing to
        confirm mail delivery without notifying real account owners.

    .PARAMETER UseExistingGraphSession
        Skip Graph authentication. Use when the caller has already called Connect-MgGraph
        with the required permissions, or in tests where Graph is mocked.

    .PARAMETER SkipModuleImport
        Skip importing ActiveDirectory and Microsoft.Graph.* modules. Use when the caller
        has already imported them earlier in the script, or in tests where those modules
        are not installed and the cmdlets are mocked instead.

    .OUTPUTS
        [pscustomobject] with Summary, Results, Success, and Error fields.

    .EXAMPLE
        # Certificate auth, discover and sweep all admin/priv accounts
        Invoke-AccountInactivityRemediation `
            -Prefixes                    @('admin','priv') `
            -ADSearchBase                'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au' `
            -MailSender                  'iam-automation@corp.local' `
            -MailClientId                $mailAppId `
            -MailTenantId                $tenantId `
            -MailCertificateThumbprint   $mailThumb `
            -ClientId                    $graphAppId `
            -TenantId                    $tenantId `
            -CertificateThumbprint       $graphThumb `
            -EnableDeletion

    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Prefixes,

        [Parameter(Mandatory)]
        [string] $ADSearchBase,

        [Parameter(Mandatory)]
        [string] $MailSender,

        [Parameter(Mandatory)]
        [string] $MailClientId,

        [Parameter(Mandatory)]
        [string] $MailTenantId,

        [Parameter(Mandatory)]
        [string] $MailCertificateThumbprint,

        [Parameter()]
        [int] $WarnThreshold = 90,

        [Parameter()]
        [int] $DisableThreshold = 120,

        [Parameter()]
        [int] $DeleteThreshold = 180,

        [Parameter()]
        [switch] $EnableDeletion,

        [Parameter(ParameterSetName = 'Certificate', Mandatory)]
        [string] $ClientId,

        [Parameter(ParameterSetName = 'Certificate', Mandatory)]
        [string] $TenantId,

        [Parameter(ParameterSetName = 'Certificate', Mandatory)]
        [string] $CertificateThumbprint,

        [Parameter()]
        [string] $NotificationRecipientOverride,

        [Parameter(ParameterSetName = 'Default')]
        [switch] $UseExistingGraphSession,

        [Parameter()]
        [switch] $SkipModuleImport
    )

    # ------------------------------------------------------------------
    # Output object and result list initialised up front -- both survive
    # into finally so partial results are always returned even when the
    # function aborts mid-batch due to an unexpected exception.
    # ------------------------------------------------------------------
    $output     = [pscustomobject]@{
        Summary     = $null
        Results     = @()
        Unprocessed = @()
        Success     = $false
        Error       = $null
    }
    $resultList = [System.Collections.Generic.List[pscustomobject]]::new()
    $workingSet = [System.Collections.Generic.List[pscustomobject]]::new()

    $today = [datetime]::UtcNow.Date

    # ------------------------------------------------------------------
    # Helper: build a result entry for the Results array.
    #
    # Rationale for using a helper rather than inline objects:
    #   - Called ~8 times, but most callers only care about 2-3 fields.
    #     Defaults handle the remaining 10+ fields silently.
    #   - Default Status='Error' encodes the unhappy-path rule. Error paths
    #     just pass what's different; they cannot accidentally emit a
    #     Completed entry by omission.
    #   - Timestamp is stamped once here, after the work is done, not
    #     duplicated at each call site.
    #   - Adding or renaming a field is a single-file change.
    # ------------------------------------------------------------------
    function script:New-DirectResultEntry {
        param(
            [string]        $UPN,
            [string]        $SamAccountName,
            [nullable[int]] $InactiveDays,
            [string]        $ActionTaken = 'None',
            [string]        $NotificationStage,
            [bool]          $NotificationSent = $false,
            [string]        $NotificationRecipient,
            [string]        $Status = 'Error',
            [string]        $SkipReason,
            [string]        $ErrorMessage
        )
        [pscustomobject]@{
            UPN                   = $UPN
            SamAccountName        = $SamAccountName
            InactiveDays          = $InactiveDays
            ActionTaken           = $ActionTaken
            NotificationStage     = $NotificationStage
            NotificationSent      = $NotificationSent
            NotificationRecipient = $NotificationRecipient
            Status                = $Status
            SkipReason            = $SkipReason
            Error                 = $ErrorMessage
            Timestamp             = [datetime]::UtcNow.ToString('o')
        }
    }

    try {
        # --------------------------------------------------------------
        # 1. Import required modules
        # --------------------------------------------------------------
        if (-not $SkipModuleImport) {
            Import-Module ActiveDirectory                  -ErrorAction Stop
            Import-Module Microsoft.Graph.Authentication   -ErrorAction Stop
            Import-Module Microsoft.Graph.Users            -ErrorAction Stop
            Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop
        }

        # --------------------------------------------------------------
        # 2. Connect to Graph if needed
        # --------------------------------------------------------------
        if (-not $UseExistingGraphSession) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            switch ($PSCmdlet.ParameterSetName) {
                'Certificate' {
                    Connect-MgGraph -ClientId $ClientId `
                        -CertificateThumbprint $CertificateThumbprint `
                        -TenantId $TenantId `
                        -NoWelcome -ErrorAction Stop
                }
                'Default' {
                    Connect-MgGraph -Scopes 'User.Read.All', 'AuditLog.Read.All', 'User.ReadWrite.All' `
                        -NoWelcome -ErrorAction Stop
                }
            }
        }

        # --------------------------------------------------------------
        # 3. Discover accounts from live directories
        # --------------------------------------------------------------
        $adAccounts    = @(Get-PrefixedADAccounts    -Prefixes $Prefixes -SearchBase $ADSearchBase)
        $entraAccounts = @(Get-PrefixedEntraAccounts -Prefixes $Prefixes)

        Write-Verbose "Discovered: $($adAccounts.Count) AD accounts, $($entraAccounts.Count) Entra accounts (including synced)"

        # Index synced Entra accounts by lower-cased UPN so AD rows can find their counterpart
        $syncedByUpn = @{}
        foreach ($u in $entraAccounts | Where-Object { $_.OnPremisesSyncEnabled }) {
            $syncedByUpn[$u.UPN.ToLower()] = $u
        }

        # Build the working set: AD accounts merged with Entra sign-in, then cloud-native Entra
        foreach ($ad in $adAccounts) {
            $entraMatch  = if ($ad.UPN) { $syncedByUpn[$ad.UPN.ToLower()] } else { $null }
            $entraSignIn = if ($entraMatch) { $entraMatch.LastSignInEntra } else { $null }
            $entraOid    = if ($entraMatch) { $entraMatch.EntraObjectId }  else { $null }

            $workingSet.Add([pscustomobject]@{
                SamAccountName       = $ad.SamAccountName
                UPN                  = $ad.UPN
                Source               = 'AD'
                Enabled              = $ad.Enabled
                LastLogonAD          = $ad.LastLogonAD
                LastSignInEntra      = $entraSignIn
                Created              = $ad.Created
                EntraObjectId        = $entraOid
                ExtensionAttribute14 = $ad.ExtensionAttribute14
                Description          = $ad.Description
            })
        }

        foreach ($u in $entraAccounts | Where-Object { -not $_.OnPremisesSyncEnabled }) {
            $workingSet.Add([pscustomobject]@{
                SamAccountName       = $null
                UPN                  = $u.UPN
                Source               = 'Entra'
                Enabled              = $u.AccountEnabled
                LastLogonAD          = $null
                LastSignInEntra      = $u.LastSignInEntra
                Created              = $u.Created
                EntraObjectId        = $u.EntraObjectId
                ExtensionAttribute14 = $null
                Description          = $null
            })
        }

        # --------------------------------------------------------------
        # Process each account
        # --------------------------------------------------------------
        foreach ($account in $workingSet) {

            $upn = $account.UPN
            $sam = $account.SamAccountName

            if (-not $upn) {
                $resultList.Add((New-DirectResultEntry -SamAccountName $sam `
                    -Status 'Skipped' -SkipReason 'NoUPN'))
                continue
            }

            Write-Verbose "Processing: $upn"

            # ----------------------------------------------------------
            # Compute InactiveDays
            # Data comes directly from the live directory query above.
            # Created is the last resort for accounts that have never
            # logged on.
            # ----------------------------------------------------------
            $availableSignInTimestamps = @($account.LastLogonAD, $account.LastSignInEntra) | Where-Object { $_ }
            $lastActivity              = if ($availableSignInTimestamps) {
                ($availableSignInTimestamps | Sort-Object -Descending | Select-Object -First 1)
            } else {
                $account.Created
            }

            if (-not $lastActivity) {
                $resultList.Add((New-DirectResultEntry -UPN $upn -SamAccountName $sam -Status 'Error' `
                    -ErrorMessage 'Cannot determine last activity: no LastLogonDate, LastSignInEntra, or WhenCreated.'))
                continue
            }

            $inactiveDays = [int][Math]::Floor(($today - $lastActivity.Date).TotalDays)

            # Below warn threshold -- account is active enough, skip silently
            if ($inactiveDays -lt $WarnThreshold) {
                $resultList.Add((New-DirectResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                    -Status 'Skipped' -SkipReason 'ActivityDetected'))
                continue
            }

            # ----------------------------------------------------------
            # OWNER RESOLUTION
            # Strategies are tried in order; the first that yields a
            # notification recipient wins.
            #
            # 1. Prefix strip (primary -- naming convention is authoritative):
            #    strip the leading prefix and separator from the SAM (or UPN
            #    local-part for Entra-native accounts) and verify the result
            #    exists in AD. For AD accounts, $sam is the prefixed value
            #    (e.g. 'adm.jsmith'). For Entra-native accounts, $sam is $null
            #    but the UPN local-part carries the same prefixed value
            #    (e.g. 'adm.jsmith@corp.local' → 'adm.jsmith'); both cases
            #    are passed to Get-ADAccountOwner via $upnLocalPart.
            #
            # 2. Extension attribute: parse 'owner=<sam>' from semicolon-delimited
            #    key=value pairs. extensionAttribute14 is used as it tends to be
            #    spare in most environments; swap it in Get-ADAccountOwner for
            #    whichever attribute your org uses. Only available for AD accounts;
            #    Entra-native accounts have no extension attribute data.
            #
            # 3. Entra sponsor: when AD-based strategies both fail and the account
            #    has an EntraObjectId, the Entra sponsor relationship is queried via
            #    Get-MgUserSponsor. The first sponsor's Mail address (or UPN) is used
            #    as the notification recipient. This is the primary resolution path for
            #    cloud-native Entra accounts that have no AD owner counterpart.
            #
            # If no strategy resolves a recipient, the account is skipped.
            # ----------------------------------------------------------
            # Use $sam for AD accounts (canonical value); fall back to UPN local part for
            # Entra-native accounts where $sam is $null and the UPN local part is the only
            # prefixed identifier available.
            $ownerSam = if ($sam) { $sam } else {
                if ($upn -match '^([^@]+)@') { $Matches[1] } else { $null }
            }

            $ownerResult = Get-ADAccountOwner -SamAccountName $ownerSam -ExtAttr14 $account.ExtensionAttribute14

            $notifyRecipient = $null

            if ($ownerResult) {
                # AD-based owner resolved -- look up their email address
                try {
                    $ownerEmail = (Get-ADUser -Identity $ownerResult.SamAccountName `
                            -Properties EmailAddress -ErrorAction Stop).EmailAddress
                    if ($ownerEmail) { $notifyRecipient = $ownerEmail }
                }
                catch { Write-Verbose "Owner email lookup failed for '$($ownerResult.SamAccountName)': $_" }

                if (-not $notifyRecipient) {
                    $resultList.Add((New-DirectResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                        -Status 'Skipped' -SkipReason 'NoEmailFound'))
                    continue
                }
            }
            elseif ($account.EntraObjectId) {
                # No AD owner -- try Entra sponsor as a last resort
                try {
                    $sponsors = @(Get-MgUserSponsor -UserId $account.EntraObjectId -Property 'mail,userPrincipalName' -ErrorAction Stop)
                    if ($sponsors.Count -gt 0) {
                        $sponsor = $sponsors[0]
                        $sponsorEmail = if ($sponsor.Mail) { $sponsor.Mail } else { $sponsor.UserPrincipalName }
                        if ($sponsorEmail) { $notifyRecipient = $sponsorEmail }
                    }
                }
                catch { Write-Verbose "Entra sponsor lookup failed for '$upn': $_" }

                if (-not $notifyRecipient) {
                    $resultList.Add((New-DirectResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                        -Status 'Skipped' -SkipReason 'NoOwnerFound'))
                    continue
                }
            }
            else {
                # No AD owner and no EntraObjectId to try sponsor lookup
                $resultList.Add((New-DirectResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                    -Status 'Skipped' -SkipReason 'NoOwnerFound'))
                continue
            }

            # ----------------------------------------------------------
            # THRESHOLD EVALUATION
            # ----------------------------------------------------------
            $actionTaken       = 'None'
            $notificationStage = $null

            if ($inactiveDays -ge $DeleteThreshold) {
                $actionTaken       = if ($EnableDeletion) { 'Delete' } else { 'Disable' }
                $notificationStage = 'Deletion'
            }
            elseif ($inactiveDays -ge $DisableThreshold) {
                $actionTaken       = 'Disable'
                $notificationStage = 'Disabled'
            }
            else {
                $actionTaken       = 'Notify'
                $notificationStage = 'Warning'
            }

            # Working account object for action functions
            $workingAccount = [pscustomobject]@{
                UPN            = $upn
                SamAccountName = $sam
                Source         = $account.Source
                EntraObjectId  = $account.EntraObjectId
                LastActivity   = $lastActivity
                Description    = $account.Description
            }

            # ----------------------------------------------------------
            # NOTIFICATION
            # ----------------------------------------------------------
            $lastActivityDisplay = $lastActivity.ToString('dd MMM yyyy')

            $notifyContent = New-InactiveAccountLifecycleMessage `
                -Stage               $notificationStage `
                -AccountUPN          $upn `
                -LastActivityDisplay $lastActivityDisplay `
                -InactiveDays        $inactiveDays

            $notifySent = $false
            $effectiveRecipient = if ($NotificationRecipientOverride) { $NotificationRecipientOverride } else { $notifyRecipient }

            if ($PSCmdlet.ShouldProcess($effectiveRecipient, "Send $notificationStage notification for $upn ($inactiveDays days inactive)")) {
                Send-GraphMail `
                    -Sender                  $MailSender `
                    -ClientID                $MailClientId `
                    -Tenant                  $MailTenantId `
                    -CertificateThumbprint   $MailCertificateThumbprint `
                    -ToRecipients            @($effectiveRecipient) `
                    -Subject                 $notifyContent.Subject `
                    -Body                    $notifyContent.Body `
                    -ErrorAction             Stop

                $notifySent = $true
            }
            else {
                $notifySent = $true   # WhatIf: treat as sent
            }

            # ----------------------------------------------------------
            # ACTION
            # Accounts already disabled in AD are silently skipped for the
            # Disable step -- Enabled=$false means the work is already done.
            # They still receive a notification and produce a Completed entry.
            # ----------------------------------------------------------
            $actionError = $null

            if ($actionTaken -eq 'Disable' -or ($actionTaken -eq 'Delete' -and -not $EnableDeletion)) {
                if ($account.Enabled -ne $false) {
                    if ($PSCmdlet.ShouldProcess($upn, "Disable account ($inactiveDays days inactive)")) {
                        $disableResult = Disable-InactiveAccount -Account $workingAccount
                        # Disable-InactiveAccount has its own try/catch and always returns
                        # Success + Message -- it never throws, so $actionError is always reached.
                        if (-not $disableResult.Success) { $actionError = $disableResult.Message }
                    }
                    # WhatIf: no action, no error
                }
                # Already disabled: no action needed, not an error
            }
            elseif ($actionTaken -eq 'Delete') {
                # $actionTaken is only 'Delete' when $EnableDeletion is $true -- that guard
                # is applied at threshold evaluation above, so no second check is needed here.
                if ($PSCmdlet.ShouldProcess($upn, "Delete account ($inactiveDays days inactive)")) {
                    $removeResult = Remove-InactiveAccount -Account $workingAccount
                    # Remove-InactiveAccount has its own try/catch and always returns
                    # Success + Message -- it never throws, so $actionError is always reached.
                    if (-not $removeResult.Success) { $actionError = $removeResult.Message }
                }
                # WhatIf: no action, no error
            }
            # Notify-only: no account change, nothing to track

            $entryStatus = if ($actionError) { 'Error' } else { 'Completed' }

            $resultList.Add((New-DirectResultEntry `
                -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                -ActionTaken $actionTaken -NotificationStage $notificationStage `
                -NotificationSent $notifySent -NotificationRecipient $notifyRecipient `
                -Status $entryStatus -ErrorMessage $actionError))
        }

        $output.Success = $true
    }
    catch {
        if (-not $output.Error) { $output.Error = $_.Exception.Message }
        Write-Warning "Invoke-AccountInactivityRemediation failed: $($output.Error)"
    }
    finally {
        # Build summary and populate output from whatever was collected before
        # any exception -- this ensures partial results are always returned.
        $summary = [pscustomobject]@{
            Total    = $resultList.Count
            Warned   = @($resultList | Where-Object { $_.ActionTaken -eq 'Notify'   -and $_.Status -eq 'Completed' }).Count
            Disabled = @($resultList | Where-Object { $_.ActionTaken -eq 'Disable'  -and $_.Status -eq 'Completed' }).Count
            Deleted  = @($resultList | Where-Object { $_.ActionTaken -eq 'Delete'   -and $_.Status -eq 'Completed' }).Count
            Skipped  = @($resultList | Where-Object { $_.Status -eq 'Skipped' }).Count
            Errors   = @($resultList | Where-Object { $_.Status -eq 'Error' }).Count
            NoOwner  = @($resultList | Where-Object { $_.SkipReason -eq 'NoOwnerFound' }).Count
        }

        Write-Host (("Invoke-AccountInactivityRemediation complete: {0} warned, {1} disabled, {2} deleted, " +
            "{3} skipped, {4} errors, {5} with no resolved owner.") -f
            $summary.Warned, $summary.Disabled, $summary.Deleted,
            $summary.Skipped, $summary.Errors, $summary.NoOwner)

        $output.Summary = $summary
        $output.Results = $resultList.ToArray()

        # Unprocessed: working-set accounts not resolved to Completed or Skipped.
        # Includes accounts that errored and accounts the loop never reached due to a
        # mid-batch exception. Shaped as the import contract so the list can be passed
        # directly to Invoke-AccountInactivityRemediationWithImport on a re-run.
        $resolvedUpns = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($resultList |
                Where-Object { $_.Status -eq 'Completed' -or $_.Status -eq 'Skipped' } |
                ForEach-Object { $_.UPN }),
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $output.Unprocessed = @(
            $workingSet | Where-Object { $_.UPN -and -not $resolvedUpns.Contains($_.UPN) } |
            ForEach-Object {
                [pscustomobject]@{
                    UserPrincipalName   = $_.UPN
                    SamAccountName      = $_.SamAccountName
                    Enabled             = $_.Enabled
                    LastLogonDate       = $_.LastLogonAD
                    Created             = $_.Created
                    EntraObjectId       = $_.EntraObjectId
                    entraLastSignInAEST = $_.LastSignInEntra
                    Description         = $_.Description
                }
            }
        )

        if (-not $UseExistingGraphSession) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        $output
    }
}
