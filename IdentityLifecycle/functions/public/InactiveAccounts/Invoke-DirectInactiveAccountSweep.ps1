function Invoke-DirectInactiveAccountSweep {
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
            2. extensionAttribute14 -- parse 'owner=<sam>' from semicolon-delimited pairs.
        If neither resolves, the account is skipped with SkipReason='NoOwnerFound'.

        OUTPUT
        Never throws. Success, Error, Summary, and Results are always returned. Partial
        results are preserved on mid-batch failure via the finally block.

    .PARAMETER Prefixes
        One or more SAMAccountName / UPN prefixes to target, e.g. @('admin','priv').
        Passed to both Get-PrefixedADAccounts and Get-PrefixedEntraAccounts.

    .PARAMETER ADSearchBase
        Distinguished name of the OU to scope the AD search, e.g.
        'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au'.

    .PARAMETER Sender
        Mailbox UPN from which notifications are sent via Send-GraphMail. Requires
        Mail.Send permission for the connected Graph identity.

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

    .PARAMETER UseExistingGraphSession
        Skip Graph authentication. Use when the caller has already called Connect-MgGraph
        with the required permissions, or in tests where Graph is mocked.

    .OUTPUTS
        [pscustomobject] with Summary, Results, Success, and Error fields.

    .EXAMPLE
        # Certificate auth, discover and sweep all admin/priv accounts
        Invoke-DirectInactiveAccountSweep `
            -Prefixes              @('admin','priv') `
            -ADSearchBase          'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au' `
            -Sender                'iam-automation@corp.local' `
            -ClientId              $appId `
            -TenantId              $tenantId `
            -CertificateThumbprint $thumb `
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
        [string] $Sender,

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
        Summary = $null
        Results = @()
        Success = $false
        Error   = $null
    }
    $resultList = [System.Collections.Generic.List[pscustomobject]]::new()

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
                    Connect-MgGraph -Scopes 'User.Read.All', 'AuditLog.Read.All', 'Mail.Send' `
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
        $workingSet = [System.Collections.Generic.List[pscustomobject]]::new()

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
                Write-Warning "Skipping account with no UPN (SAM: $sam)"
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
            # Prefix-strip is tried first (primary -- naming convention is
            # authoritative). EA14 'owner=<sam>' is the fallback for accounts
            # that don't follow the naming convention. If neither resolves,
            # the account is skipped.
            #
            # For Entra-native accounts (Source = 'Entra'), there is no SamAccountName
            # on the account itself -- it is a cloud-only identity. However, the UPN
            # follows the same prefix convention (e.g. adm.jsmith@corp.local), so the
            # local-part before the '@' is used as the prefix-strip input. If that
            # resolves, it means the person has a standard AD account named 'jsmith'
            # which is the ownership record we want.
            #
            # TODO: If neither strategy resolves an owner for an Entra-native account,
            # a dedicated owner-lookup path for cloud-only identities (e.g. manager
            # attribute via Graph) is not yet implemented.
            # ----------------------------------------------------------
            # Get-ADAccountOwner expects the full prefixed name (e.g. 'adm.jsmith') and
            # strips the prefix internally to derive the standard account candidate
            # (e.g. 'jsmith'), then verifies that SAM exists in AD.
            #
            # For AD accounts, $sam is 'adm.jsmith' -- the prefixed SAM from the directory.
            # For Entra-native accounts, $sam is $null, but the UPN local-part is the same
            # value (e.g. 'adm.jsmith@corp.local' → local-part 'adm.jsmith').
            # In both cases we pass the UPN local-part to keep the logic uniform.
            $upnLocalPart = if ($upn -match '^([^@]+)@') { $Matches[1] } else { $null }

            $ownerResult = Get-ADAccountOwner -SamAccountName $upnLocalPart -ExtAttr14 $account.ExtensionAttribute14

            if (-not $ownerResult) {
                $resultList.Add((New-DirectResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                    -Status 'Skipped' -SkipReason 'NoOwnerFound'))
                continue
            }

            $notifyRecipient = $null
            try {
                $ownerEmail = (Get-ADUser -Identity $ownerResult.SamAccountName `
                        -Properties EmailAddress -ErrorAction Stop).EmailAddress
                if ($ownerEmail) { $notifyRecipient = $ownerEmail }
            }
            catch { Write-Verbose "Owner email lookup failed for '$($ownerResult.SamAccountName)': $_" }

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

            if ($PSCmdlet.ShouldProcess($notifyRecipient, "Send $notificationStage notification for $upn ($inactiveDays days inactive)")) {
                Send-GraphMail `
                    -Sender       $Sender `
                    -ToRecipients @($notifyRecipient) `
                    -Subject      $notifyContent.Subject `
                    -Body         $notifyContent.Body `
                    -ErrorAction  Stop

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
        Write-Warning "Invoke-DirectInactiveAccountSweep failed: $($output.Error)"
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

        Write-Host ("Direct sweep complete: {0} warned, {1} disabled, {2} deleted, " +
            "{3} skipped, {4} errors, {5} with no resolved owner.") -f `
            $summary.Warned, $summary.Disabled, $summary.Deleted,
            $summary.Skipped, $summary.Errors, $summary.NoOwner

        $output.Summary = $summary
        $output.Results = $resultList.ToArray()

        if (-not $UseExistingGraphSession) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        $output
    }
}
