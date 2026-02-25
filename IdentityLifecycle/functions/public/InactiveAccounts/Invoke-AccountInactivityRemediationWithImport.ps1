function Invoke-AccountInactivityRemediationWithImport {
    <#
    .SYNOPSIS
        Import-driven stateless sweep that evaluates a pre-identified list of inactive
        privileged accounts against absolute inactivity thresholds and takes the required
        action in a single pass.

    .DESCRIPTION
        Accepts a pre-built account list (e.g. from a dashboard export or the Unprocessed
        output of Invoke-AccountInactivityRemediation) and is entirely stateless: given the
        list, it computes how long each account has been inactive and takes the
        highest-severity action that applies.

        Threshold model (all thresholds are absolute inactivity durations):

            WarnThreshold    (default 90)  -- send Warning notification, no account change
            DisableThreshold (default 120) -- disable account, send Disabled notification
            DeleteThreshold  (default 180) -- delete account, send Deletion notification

        An account inactive for 150 days will be disabled + notified in a single run
        even if it was never warned previously.

        PREREQUISITES
        The following modules must be available and will be imported automatically:
            - ActiveDirectory (RSAT)
            - Microsoft.Graph.Authentication
            - Microsoft.Graph.Users
            - Microsoft.Graph.Identity.SignIns
        If any module cannot be imported the function terminates immediately.

        GRAPH SESSION
        Unless -UseExistingGraphSession is set (or the Certificate parameter set is used),
        the function connects to Graph at the start and disconnects in finally. Use
        -UseExistingGraphSession to supply your own pre-established session (e.g. in tests
        or when the caller already holds a Graph connection with the required scopes).

        LIVE CHECK
        Before acting on any account the function re-queries the live directory.
        Routing is determined by field presence, not by OnPremisesSyncEnabled or Source:
            - SamAccountName present: re-queried via Get-ADUser for live enabled state,
              last logon, and extensionAttribute14. If EntraObjectId is also present the
              Entra sign-in timestamp is fetched as well.
            - SamAccountName absent, EntraObjectId present: Entra-native account, re-queried
              via Get-MgUser for live sign-in and enabled state.
        Accounts where activity has been detected since the export are silently skipped.
        Accounts already disabled since the export are silently skipped.

        OWNER RESOLUTION
        For all accounts, owner is resolved in this order:
            1. Prefix strip: remove leading prefix and separator from SamAccountName and
               verify the resulting SAM exists in AD (primary -- naming convention is
               the authoritative ownership contract). For Entra-native accounts (no SAM
               in the input row), SamAccountName is $null so this strategy is skipped.
            2. Extension attribute: parse 'owner=<sam>' from semicolon-delimited key=value
               pairs (fallback for accounts that don't follow the naming convention).
               extensionAttribute14 is used as it tends to be spare in most environments;
               swap it in Get-ADAccountOwner for whichever attribute your org uses.
               Only available for AD-routed accounts; Entra-native accounts have no
               extension attribute data.
            3. Entra sponsor: when both AD strategies fail and the account has an
               EntraObjectId, the Entra sponsor relationship is queried via
               Get-MgUserSponsor. The first sponsor's Mail address (or UPN) is used as
               the notification recipient. This is the only resolution path for
               cloud-native accounts that have no AD owner.
        If no strategy resolves a recipient, the account is skipped with Status='Skipped'
        and SkipReason='NoOwnerFound'. No notification or action is taken. These accounts
        appear in the output for a human to investigate before the next run.

        OUTPUT
        The function never throws. A consistent output object is always returned with
        Success, Error, Summary, and Results always populated. Summary and Results are built
        in the finally block from whatever was collected before any exception, so partial
        results are preserved even on a mid-batch failure. Success=$false and Error are set
        when an unexpected exception aborts the run. The caller should always check Success
        and Error to determine what happened.

    .PARAMETER Accounts
        Array of account objects from a dashboard export (or Import-Csv). Expected fields:
            UserPrincipalName   - primary key; rows with no value are silently discarded
            SamAccountName      - used for AD lookup and owner resolution
            Enabled             - export-time enabled state; detects disable-since-export
            LastLogonDate       - AD last logon at export time; overridden by live query
            Created             - account creation date; baseline when no logon data exists
            EntraObjectId       - required for Entra-native accounts; optional for AD
                                  accounts where Entra sign-in data is also needed
            entraLastSignInAEST - Entra sign-in at export time; overridden by live query
            Description         - passed to action functions
        All values are re-validated against the live directory before any action is taken.

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
        # Certificate auth, import CSV, preview with -WhatIf
        $accounts = Import-Csv 'C:\Reports\InactivePrivAccounts.csv'
        Invoke-AccountInactivityRemediationWithImport `
            -Accounts              $accounts `
            -Sender                'iam-automation@corp.local' `
            -ClientId              $appId `
            -TenantId              $tenantId `
            -CertificateThumbprint $thumb `
            -WhatIf

    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Accounts,

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
        Summary     = $null
        Results     = @()
        Unprocessed = @()
        Success     = $false
        Error       = $null
    }
    $resultList = [System.Collections.Generic.List[pscustomobject]]::new()

    $today = [datetime]::UtcNow.Date

    # ------------------------------------------------------------------
    # Helper: build a result entry for the Results array.
    #
    # Rationale for using a helper rather than inline objects:
    #   - Called ~10 times, but most callers only care about 2-3 fields.
    #     Defaults handle the remaining 10+ fields silently.
    #   - Default Status='Error' encodes the unhappy-path rule. Error paths just
    #     pass what's different; they cannot accidentally emit a Completed entry
    #     by omission.
    #   - Timestamp is stamped once here, after the work is done, not duplicated
    #     at each call site.
    #   - Adding or renaming a field is a single-file change.
    # ------------------------------------------------------------------
    function script:New-ResultEntry {
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

    # ------------------------------------------------------------------
    # Helper: coerce string 'True'/'False'/'1'/'0' or native bool to bool.
    # Returns $null when value is absent or unrecognised.
    # ------------------------------------------------------------------
    function script:ConvertTo-Bool {
        param([object] $Value)
        if ($null -eq $Value -or $Value -eq '') { return $null }
        if ($Value -is [bool]) { return $Value }
        switch ($Value.ToString().Trim()) {
            'True' { return $true }
            '1' { return $true }
            'False' { return $false }
            '0' { return $false }
        }
        return $null
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
        # Process each account.
        # --------------------------------------------------------------
        foreach ($inputRow in $Accounts) {

            $upn = $inputRow.UserPrincipalName
            $sam = $inputRow.SamAccountName

            if (-not $upn) {
                Write-Warning "Skipping row with no UserPrincipalName (SAM: $sam)"
                continue
            }

            Write-Verbose "Processing: $upn"

            # ----------------------------------------------------------
            # LIVE CHECK -- re-query live directory for enabled state,
            # latest logon, and extensionAttribute14. Routing is by field
            # presence: SamAccountName → AD path; EntraObjectId only → Entra.
            # ----------------------------------------------------------
            $liveEnabled         = $null
            $liveLastLogon       = $null
            $liveLastSignIn      = $null
            $liveExtAttr14       = $null
            $entraObjectId       = $inputRow.EntraObjectId

            if ($sam) {
                # AD account (may also have an Entra object ID for sign-in data)
                try {
                    $adUser        = Get-ADUser -Identity $sam `
                        -Properties LastLogonDate, Enabled, extensionAttribute14 -ErrorAction Stop
                    $liveEnabled   = $adUser.Enabled
                    $liveLastLogon = $adUser.LastLogonDate
                    $liveExtAttr14 = $adUser.extensionAttribute14
                }
                catch {
                    $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam `
                        -Status 'Error' -ErrorMessage "AD lookup failed: $_"))

                    continue
                }

                if ($entraObjectId) {
                    try {
                        $liveLastSignIn = Resolve-EntraSignIn (Get-MgUser -UserId $entraObjectId `
                            -Property 'Id,SignInActivity' -ErrorAction Stop)
                    }
                    catch { Write-Verbose "Entra sign-in lookup failed for '$upn': $_" }
                }
            }
            else {
                # Entra-native account -- no SAM, must have an EntraObjectId
                if (-not $entraObjectId) {
                    $resultList.Add((New-ResultEntry -UPN $upn `
                        -Status 'Error' -ErrorMessage 'Account has no SamAccountName or EntraObjectId.'))

                    continue
                }
                try {
                    $mgUser         = Get-MgUser -UserId $entraObjectId `
                        -Property 'Id,AccountEnabled,SignInActivity' -ErrorAction Stop
                    $liveEnabled    = $mgUser.AccountEnabled
                    $liveLastSignIn = Resolve-EntraSignIn $mgUser
                }
                catch {
                    $resultList.Add((New-ResultEntry -UPN $upn `
                        -Status 'Error' -ErrorMessage "Entra lookup failed: $_"))

                    continue
                }
            }

            # Disabled since export → already actioned elsewhere, skip
            if ($liveEnabled -eq $false -and (ConvertTo-Bool $inputRow.Enabled) -eq $true) {
                $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam `
                    -Status 'Skipped' -SkipReason 'DisabledSinceExport'))
                continue
            }

            # ----------------------------------------------------------
            # Compute InactiveDays from live data only.
            # $liveLastLogon and $liveLastSignIn come from the live check
            # above. Created from the input row is the last resort for
            # accounts that exist but have never logged on.
            # ----------------------------------------------------------
            # Created comes from the CSV export as a string, so it must be parsed into a
            # DateTime before use. We use this as a fallback in the event of no last logon
            # data being available.
            $createdFallback = $null
            try { if ($inputRow.Created) { $createdFallback = [datetime]$inputRow.Created } } catch {}

            # $availableSignInTimestamps = non-null sign-in timestamps from all directories;
            # the most recent wins. Falls back to WhenCreated when both are null.
            $availableSignInTimestamps = @($liveLastLogon, $liveLastSignIn) | Where-Object { $_ }
            $lastActivity              = if ($availableSignInTimestamps) { ($availableSignInTimestamps | Sort-Object -Descending | Select-Object -First 1) } else { $createdFallback }

            if (-not $lastActivity) {
                $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam -Status 'Error' `
                    -ErrorMessage 'Cannot determine last activity: no LastLogonDate, LastSignInEntra, or WhenCreated.'))
                continue
            }

            # How many complete days since $lastActivity -- used for all threshold comparisons below.
            $inactiveDays = [int][Math]::Floor(($today - $lastActivity.Date).TotalDays)

            # Activity detected since export → skip silently
            if ($inactiveDays -lt $WarnThreshold) {
                $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                    -Status 'Skipped' -SkipReason 'ActivityDetected'))
                continue
            }

            # ----------------------------------------------------------
            # OWNER RESOLUTION
            # Strategies are tried in order; the first that yields a
            # notification recipient wins.
            #
            # 1. Prefix strip (primary -- naming convention is authoritative):
            #    strip the leading prefix and separator from SamAccountName
            #    and verify the result exists in AD. Skipped when $sam is $null
            #    (Entra-native accounts have no SamAccountName in the input row).
            #
            # 2. Extension attribute: parse 'owner=<sam>' from semicolon-delimited
            #    key=value pairs in extensionAttribute14 (or whichever attribute
            #    your org uses -- swap it in Get-ADAccountOwner). Only available
            #    for AD-routed accounts.
            #
            # 3. Entra sponsor: when AD-based strategies both fail and the account
            #    has an EntraObjectId, the Entra sponsor relationship is queried
            #    via Get-MgUserSponsor. The first sponsor's Mail address is used
            #    as the notification recipient (falling back to UserPrincipalName).
            #    This is the only resolution path available for cloud-native
            #    Entra accounts that have no AD owner.
            #
            # If no strategy resolves a recipient, the account is skipped:
            # a human must assign an owner before the next run.
            # ----------------------------------------------------------
            $ownerResult = Get-ADAccountOwner -SamAccountName $sam -ExtAttr14 $liveExtAttr14

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
                    $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                        -Status 'Skipped' -SkipReason 'NoEmailFound'))
                    continue
                }
            }
            elseif ($entraObjectId) {
                # No AD owner -- try Entra sponsor as a last resort
                try {
                    $sponsors = @(Get-MgUserSponsor -UserId $entraObjectId -Property 'mail,userPrincipalName' -ErrorAction Stop)
                    if ($sponsors.Count -gt 0) {
                        $sponsor = $sponsors[0]
                        $sponsorEmail = if ($sponsor.Mail) { $sponsor.Mail } else { $sponsor.UserPrincipalName }
                        if ($sponsorEmail) { $notifyRecipient = $sponsorEmail }
                    }
                }
                catch { Write-Verbose "Entra sponsor lookup failed for '$upn': $_" }

                if (-not $notifyRecipient) {
                    $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                        -Status 'Skipped' -SkipReason 'NoOwnerFound'))
                    continue
                }
            }
            else {
                # No AD owner and no EntraObjectId to try sponsor lookup
                $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                    -Status 'Skipped' -SkipReason 'NoOwnerFound'))
                continue
            }

            # ----------------------------------------------------------
            # THRESHOLD EVALUATION
            # ----------------------------------------------------------
            $actionTaken = 'None'
            $notificationStage = $null

            if ($inactiveDays -ge $DeleteThreshold) {
                $actionTaken = if ($EnableDeletion) { 'Delete' } else { 'Disable' }
                $notificationStage = 'Deletion'
            }
            elseif ($inactiveDays -ge $DisableThreshold) {
                $actionTaken = 'Disable'
                $notificationStage = 'Disabled'
            }
            else {
                $actionTaken = 'Notify'
                $notificationStage = 'Warning'
            }

            # Working account object for action functions
            $workingAccount = [pscustomobject]@{
                UPN            = $upn
                SamAccountName = $sam
                Source         = if ($sam) { 'AD' } else { 'Entra' }
                ObjectId       = $inputRow.ObjectId
                EntraObjectId  = $entraObjectId
                LastActivity   = $lastActivity
                Description    = $inputRow.Description
            }

            # ----------------------------------------------------------
            # NOTIFICATION
            # ----------------------------------------------------------
            # Human-readable date for the notification email body, e.g. "21 Feb 2026".
            $lastActivityDisplay = if ($lastActivity) {
                $lastActivity.ToString('dd MMM yyyy')
            }
            else { 'not recorded' }

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
            # Disable step -- liveEnabled=$false means the work is already done.
            # They still receive a notification and produce a Completed entry.
            # (Accounts disabled since export are caught earlier as DisabledSinceExport
            # and never reach this point.)
            # ----------------------------------------------------------
            $actionError = $null

            if ($actionTaken -eq 'Disable' -or ($actionTaken -eq 'Delete' -and -not $EnableDeletion)) {
                if ($liveEnabled -ne $false) {
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

            $resultList.Add((New-ResultEntry `
                -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                -ActionTaken $actionTaken -NotificationStage $notificationStage `
                -NotificationSent $notifySent -NotificationRecipient $notifyRecipient `
                -Status $entryStatus -ErrorMessage $actionError))
        }

        $output.Success = $true
    }
    catch {
        if (-not $output.Error) { $output.Error = $_.Exception.Message }
        Write-Warning "Invoke-AccountInactivityRemediationWithImport failed: $($output.Error)"
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

        Write-Host ("Invoke-AccountInactivityRemediationWithImport complete: {0} warned, {1} disabled, {2} deleted, " +
            "{3} skipped, {4} errors, {5} with no resolved owner.") -f `
            $summary.Warned, $summary.Disabled, $summary.Deleted,
            $summary.Skipped, $summary.Errors, $summary.NoOwner

        $output.Summary = $summary
        $output.Results = $resultList.ToArray()

        # Unprocessed: input rows for accounts not resolved to Completed or Skipped.
        # Includes accounts that errored and accounts the loop never reached due to a
        # mid-batch exception. Shape matches the import contract so the list can be
        # passed directly to -Accounts on a re-run without any transformation.
        $resolvedUpns = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($resultList |
                Where-Object { $_.Status -eq 'Completed' -or $_.Status -eq 'Skipped' } |
                ForEach-Object { $_.UPN }),
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $output.Unprocessed = @(
            $Accounts | Where-Object { $_.UserPrincipalName -and
                -not $resolvedUpns.Contains($_.UserPrincipalName) } |
            ForEach-Object {
                [pscustomobject]@{
                    UserPrincipalName   = $_.UserPrincipalName
                    SamAccountName      = $_.SamAccountName
                    Enabled             = $_.Enabled
                    LastLogonDate       = $_.LastLogonDate
                    Created             = $_.Created
                    EntraObjectId       = $_.EntraObjectId
                    entraLastSignInAEST = $_.entraLastSignInAEST
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
