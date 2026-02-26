function Invoke-InactiveAccountRemediation {
    <#
    .SYNOPSIS
        Stateless sweep that evaluates inactive privileged accounts against absolute
        inactivity thresholds and takes the required action in a single pass.

    .DESCRIPTION
        Supports two account-sourcing modes, selected by the parameters supplied:

        IMPORT MODE (-Accounts supplied)
            Accepts a pre-built account list (e.g. from a dashboard export or the
            Unprocessed output of a previous run). Before acting on any account the
            function re-queries the live directory for current enabled state, last
            logon, and Entra sign-in data. Accounts already disabled since the export,
            or that have become active since the export, are silently skipped.

        DISCOVERY MODE (-Prefixes and -ADSearchBase supplied)
            Discovers privileged accounts directly from AD and Entra ID at runtime
            using Get-PrefixedADAccounts and Get-PrefixedEntraAccounts. AD-synced Entra
            accounts are merged with their AD counterpart. Because data comes from the
            live directory, no additional freshness re-query is performed.

        THRESHOLD MODEL (both modes)
            WarnThreshold    (default 90)  -- send Warning notification, no account change
            DisableThreshold (default 120) -- disable account, send Disabled notification
            DeleteThreshold  (default 180) -- delete account, send Deletion notification
            An account inactive for 150 days is disabled + notified in a single run
            even if it was never warned previously.

        PREREQUISITES
        The following modules must be available and will be imported automatically:
            - ActiveDirectory (RSAT)
            - Microsoft.Graph.Authentication
            - Microsoft.Graph.Users
            - Microsoft.Graph.Identity.SignIns
        If any module cannot be imported the function terminates immediately.

        GRAPH SESSION
        Unless -UseExistingGraphSession is set, the function connects to Graph
        interactively at the start and disconnects in finally.
        Use -UseExistingGraphSession when the caller already holds a Graph connection
        with the required scopes (e.g. in tests or pipeline scenarios).

        OWNER RESOLUTION
        For all accounts, owner is resolved in this order:
            1. Prefix strip: match SamAccountName (or UPN local-part for Entra-native
               accounts) against the supplied -Prefixes followed by a separator (dot or
               underscore); the remainder is the candidate standard SAM
               (e.g. prefix 'ca', SAM 'ca.jsmith' -> 'jsmith'). Verified against AD.
               Primary strategy — naming convention is authoritative.
            2. Extension attribute: parse 'owner=<sam>' from semicolon-delimited
               key=value pairs. extensionAttribute14 is used as it tends to be spare;
               swap it in Get-ADAccountOwner for whichever attribute your org uses.
               Only available for AD accounts; Entra-native accounts have no extension
               attribute data from the directory.
            3. Entra sponsor: when both AD strategies fail and the account has an
               EntraObjectId, the Entra sponsor relationship is queried via
               Get-MgUserSponsor. The first sponsor's Mail address (or UPN) is used
               as the notification recipient. This is the primary resolution path for
               cloud-native accounts that have no AD owner.
        If no strategy resolves a recipient, the account is skipped with
        Status='Skipped' and SkipReason='NoOwnerFound'.

        OUTPUT
        The function never throws. A consistent output object is always returned with
        Success, Error, Summary, Results, and Unprocessed always populated. Summary and
        Results are built in the finally block from whatever was collected before any
        exception, so partial results are preserved even on a mid-batch failure. The
        caller should always check Success and Error to determine what happened.

        Unprocessed contains accounts that errored or were never reached, shaped as the
        import contract. It can be passed directly to -Accounts on a re-run without any
        transformation (cross-mode: discovery Unprocessed → import mode re-run works).

    .PARAMETER Accounts
        (Import mode) Array of account objects from a dashboard export or Import-Csv,
        or the Unprocessed output of a previous run. Expected fields:
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
        Requires -Prefixes. Mutually exclusive with -ADSearchBase.

    .PARAMETER Prefixes
        One or more SAMAccountName / UPN prefixes to target, e.g. @('admin','priv').
        Required in both parameter sets:
          - Discovery mode: passed to Get-PrefixedADAccounts and Get-PrefixedEntraAccounts
            to scope which accounts are discovered.
          - Import mode: used to filter the supplied -Accounts list so only rows whose
            SAM or UPN local-part starts with a recognised prefix are processed. Rows
            that do not match are silently discarded, guarding against mis-routed inputs.

    .PARAMETER ADSearchBase
        (Discovery mode) Distinguished name of the OU to scope the AD search, e.g.
        'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au'. Not used in import mode.

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
        [pscustomobject] with Summary, Results, Unprocessed, Success, and Error fields.

    .EXAMPLE
        # Import mode: preview with -WhatIf (Graph auth is interactive)
        $accounts = Import-Csv 'C:\Reports\InactivePrivAccounts.csv'
        Invoke-InactiveAccountRemediation `
            -Accounts                    $accounts `
            -MailSender                  'iam-automation@corp.local' `
            -MailClientId                $mailAppId `
            -MailTenantId                $tenantId `
            -MailCertificateThumbprint   $mailThumb `
            -WhatIf

    .EXAMPLE
        # Discovery mode: sweep all admin/priv accounts and enable deletion
        Invoke-InactiveAccountRemediation `
            -Prefixes                    @('admin','priv') `
            -ADSearchBase                'OU=PrivilegedAccounts,DC=corp,DC=gov,DC=au' `
            -MailSender                  'iam-automation@corp.local' `
            -MailClientId                $mailAppId `
            -MailTenantId                $tenantId `
            -MailCertificateThumbprint   $mailThumb `
            -EnableDeletion

    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Discovery')]
    [OutputType([pscustomobject])]
    param(
        # --- Import mode ---
        [Parameter(ParameterSetName = 'Import', Mandatory)]
        [object[]] $Accounts,

        # --- Shared: prefix list (Mandatory in both sets) ---
        # In discovery mode: scopes the AD/Entra queries.
        # In import mode:    filters the supplied list to accounts whose SAM or
        #                    UPN local-part starts with one of these prefixes,
        #                    guarding against mis-routed inputs.
        [Parameter(ParameterSetName = 'Import',    Mandatory)]
        [Parameter(ParameterSetName = 'Discovery', Mandatory)]
        [string[]] $Prefixes,

        # --- Discovery mode ---
        [Parameter(ParameterSetName = 'Discovery', Mandatory)]
        [string] $ADSearchBase,

        # --- Mail (always required) ---
        [Parameter(Mandatory)] [string] $MailSender,
        [Parameter(Mandatory)] [string] $MailClientId,
        [Parameter(Mandatory)] [string] $MailTenantId,
        [Parameter(Mandatory)] [string] $MailCertificateThumbprint,

        # --- Thresholds ---
        [int] $WarnThreshold    = 90,
        [int] $DisableThreshold = 120,
        [int] $DeleteThreshold  = 180,

        # --- Behaviour ---
        [switch] $EnableDeletion,
        [string] $NotificationRecipientOverride,

        # --- Session control ---
        [switch] $UseExistingGraphSession,
        [switch] $SkipModuleImport
    )

    $importMode = $PSCmdlet.ParameterSetName -eq 'Import'

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
    $workingList = [System.Collections.Generic.List[pscustomobject]]::new()

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
            [string]        $ErrorMessage,
            [pscustomobject] $InputRow        # import-contract row; set only when owner is known
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
            InputRow              = $InputRow
            Timestamp             = [datetime]::UtcNow.ToString('o')
        }
    }

    # ------------------------------------------------------------------
    # Helper: coerce string 'True'/'False'/'1'/'0' or native bool to bool.
    # Returns $null when value is absent or unrecognised.
    # Used in import mode to compare export-time Enabled against live state.
    # ------------------------------------------------------------------
    function script:ConvertTo-Bool {
        param([object] $Value)
        if ($null -eq $Value -or $Value -eq '') { return $null }
        if ($Value -is [bool]) { return $Value }
        switch ($Value.ToString().Trim()) {
            'True'  { return $true }
            '1'     { return $true }
            'False' { return $false }
            '0'     { return $false }
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
            Connect-MgGraph -Scopes 'User.Read.All', 'AuditLog.Read.All', 'User.ReadWrite.All' `
                -NoWelcome -ErrorAction Stop
        }

        # --------------------------------------------------------------
        # 3. Assemble the working list
        # --------------------------------------------------------------
        if ($importMode) {
            # Import mode: include only rows whose SAM or UserPrincipalName starts with
            # one of the supplied prefixes. Guards against mis-routed inputs;
            # non-matching rows are silently dropped.
            foreach ($row in $Accounts) {
                $matched = $false
                foreach ($prefix in $Prefixes) {
                    if ($row.SamAccountName    -like "$prefix*" -or
                        $row.UserPrincipalName -like "$prefix*") {
                        $matched = $true
                        break
                    }
                }

                if ($matched) {
                    $workingList.Add($row)
                } else {
                    Write-Verbose "Skipping '$($row.UserPrincipalName)' -- does not match any supplied prefix."
                }
            }
        }
        else {
            # Discovery mode: build the working list from live directory queries.
            $adAccounts    = @(Get-PrefixedADAccounts    -Prefixes $Prefixes -SearchBase $ADSearchBase)
            $entraAccounts = @(Get-PrefixedEntraAccounts -Prefixes $Prefixes)

            Write-Verbose "Discovered: $($adAccounts.Count) AD accounts, $($entraAccounts.Count) Entra accounts (including synced)"

            # Index synced Entra accounts by lower-cased UPN so AD rows can find their counterpart
            $syncedByUpn = @{}
            foreach ($u in $entraAccounts | Where-Object { $_.OnPremisesSyncEnabled }) {
                $syncedByUpn[$u.UserPrincipalName.ToLower()] = $u
            }

            # AD accounts merged with any matching synced Entra sign-in data.
            # Field names already match the import contract -- no remapping needed.
            foreach ($ad in $adAccounts) {
                $entraMatch = if ($ad.UserPrincipalName) { $syncedByUpn[$ad.UserPrincipalName.ToLower()] } else { $null }

                $workingList.Add([pscustomobject]@{
                    UserPrincipalName    = $ad.UserPrincipalName
                    SamAccountName       = $ad.SamAccountName
                    Enabled              = $ad.Enabled
                    LastLogonDate        = $ad.LastLogonDate
                    entraLastSignInAEST  = if ($entraMatch) { $entraMatch.entraLastSignInAEST } else { $null }
                    Created              = $ad.Created
                    EntraObjectId        = if ($entraMatch) { $entraMatch.EntraObjectId } else { $null }
                    ExtensionAttribute14 = $ad.ExtensionAttribute14
                    Description          = $ad.Description
                })
            }

            # Cloud-native Entra accounts (not synced from AD)
            foreach ($u in $entraAccounts | Where-Object { -not $_.OnPremisesSyncEnabled }) {
                $workingList.Add([pscustomobject]@{
                    UserPrincipalName    = $u.UserPrincipalName
                    SamAccountName       = $null
                    Enabled              = $u.Enabled
                    LastLogonDate        = $null
                    entraLastSignInAEST  = $u.entraLastSignInAEST
                    Created              = $u.Created
                    EntraObjectId        = $u.EntraObjectId
                    ExtensionAttribute14 = $null
                    Description          = $null
                })
            }
        }

        # --------------------------------------------------------------
        # 4. Process each account
        # --------------------------------------------------------------
        foreach ($row in $workingList) {

            $upn = $row.UserPrincipalName
            $sam = $row.SamAccountName

            # InputRow is $row itself -- working list uses import-contract field names in
            # both modes, so no remapping is needed. Set on result entries only after owner
            # resolution succeeds (see usage below).
            $inputRow = $row

            if (-not $upn) {
                $resultList.Add((New-ResultEntry -SamAccountName $sam `
                    -Status 'Skipped' -SkipReason 'NoUPN'))
                continue
            }

            Write-Verbose "Processing: $upn"

            # ----------------------------------------------------------
            # LIVE CHECK (import mode only)
            # Discovery mode uses the already-live data from the working list.
            # ----------------------------------------------------------
            $enabledCheck  = $null
            $extAttr14     = $null
            $entraObjectId = $row.EntraObjectId

            if ($importMode) {
                $liveLastLogon  = $null
                $liveLastSignIn = $null

                if ($sam) {
                    # AD account (may also have an Entra object ID for sign-in data)
                    try {
                        $adUser        = Get-ADUser -Identity $sam `
                            -Properties LastLogonDate, Enabled, extensionAttribute14 -ErrorAction Stop
                        $enabledCheck  = $adUser.Enabled
                        $liveLastLogon = $adUser.LastLogonDate
                        $extAttr14     = $adUser.extensionAttribute14
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
                        $enabledCheck   = $mgUser.AccountEnabled
                        $liveLastSignIn = Resolve-EntraSignIn $mgUser
                    }
                    catch {
                        $resultList.Add((New-ResultEntry -UPN $upn `
                            -Status 'Error' -ErrorMessage "Entra lookup failed: $_"))
                        continue
                    }
                }

                # Disabled since export → already actioned elsewhere, skip
                if ($enabledCheck -eq $false -and (ConvertTo-Bool $row.Enabled) -eq $true) {
                    $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam `
                        -Status 'Skipped' -SkipReason 'DisabledSinceExport'))
                    continue
                }
            }
            else {
                # Discovery mode: state comes directly from the working list
                $enabledCheck   = $row.Enabled
                $extAttr14      = $row.ExtensionAttribute14
                $liveLastLogon  = $row.LastLogonDate
                $liveLastSignIn = $row.entraLastSignInAEST
            }

            # ----------------------------------------------------------
            # Compute InactiveDays
            # $liveLastLogon and $liveLastSignIn are populated by the live
            # check (import mode) or from discovery data (discovery mode).
            # Created is the last resort for accounts that have never logged on.
            # In import mode Created is a string from the CSV and must be parsed;
            # in discovery mode it is already a DateTime.
            # ----------------------------------------------------------
            $createdFallback = $null
            if ($importMode) {
                try { if ($row.Created) { $createdFallback = [datetime]$row.Created } } catch {}
            }
            else {
                $createdFallback = $row.Created
            }

            $availableSignInTimestamps = @($liveLastLogon, $liveLastSignIn) | Where-Object { $_ }
            $lastActivity              = if ($availableSignInTimestamps) {
                ($availableSignInTimestamps | Sort-Object -Descending | Select-Object -First 1)
            } else {
                $createdFallback
            }

            if (-not $lastActivity) {
                $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam -Status 'Error' `
                    -ErrorMessage 'Cannot determine last activity: no LastLogonDate, LastSignInEntra, or WhenCreated.'))
                continue
            }

            $inactiveDays = [int][Math]::Floor(($today - $lastActivity.Date).TotalDays)

            # Below warn threshold -- account is active enough, skip silently
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
            #    match against each known prefix + separator; remainder is the
            #    candidate standard SAM (e.g. prefix 'ca', SAM 'ca.jsmith' -> 'jsmith').
            #    For Entra-native accounts the UPN local-part is used instead of SAM.
            #    $Prefixes passed through so discovery and owner resolution stay in sync.
            #
            # 2. Extension attribute: parse 'owner=<sam>' from semicolon-delimited
            #    key=value pairs. extensionAttribute14 is used as it tends to be
            #    spare in most environments; swap it in Get-ADAccountOwner for
            #    whichever attribute your org uses. Only available for AD accounts.
            #
            # 3. Entra sponsor: when both AD strategies fail and the account has an
            #    EntraObjectId, the Entra sponsor relationship is queried via
            #    Get-MgUserSponsor. The first sponsor's Mail address (or UPN) is used
            #    as the notification recipient. Primary path for cloud-native accounts.
            #
            # If no strategy resolves a recipient, the account is skipped.
            # ----------------------------------------------------------
            # Use $sam for AD accounts (canonical value); fall back to UPN local part for
            # Entra-native accounts where $sam is $null and the UPN local part is the only
            # prefixed identifier available.
            $ownerSam = if ($sam) { $sam } else {
                if ($upn -match '^([^@]+)@') { $Matches[1] } else { $null }
            }

            $ownerParams = @{ SamAccountName = $ownerSam; ExtAttr14 = $extAttr14 }
            if ($Prefixes) { $ownerParams['Prefixes'] = $Prefixes }
            $ownerResult = Get-ADAccountOwner @ownerParams

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
                Source         = if ($sam) { 'AD' } else { 'Entra' }
                EntraObjectId  = $entraObjectId
                LastActivity   = $lastActivity
                Description    = $row.Description
            }

            # ----------------------------------------------------------
            # NOTIFICATION
            # ----------------------------------------------------------
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
            $effectiveRecipient = if ($NotificationRecipientOverride) { $NotificationRecipientOverride } else { $notifyRecipient }

            $mailError = $null
            if ($PSCmdlet.ShouldProcess($effectiveRecipient, "Send $notificationStage notification for $upn ($inactiveDays days inactive)")) {
                try {
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
                catch {
                    $mailError = "Notification failed: $_"
                }
            }
            else {
                $notifySent = $true   # WhatIf: treat as sent
            }

            if ($mailError) {
                $resultList.Add((New-ResultEntry -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                    -ActionTaken $actionTaken -NotificationStage $notificationStage `
                    -NotificationRecipient $notifyRecipient `
                    -Status 'Error' -ErrorMessage $mailError -InputRow $inputRow))
                continue
            }

            # ----------------------------------------------------------
            # ACTION
            # Accounts already disabled are silently skipped for the Disable
            # step -- $enabledCheck=$false means the work is already done.
            # They still receive a notification and produce a Completed entry.
            # (Import mode: accounts disabled since export are caught earlier
            # as DisabledSinceExport and never reach this point.)
            # ----------------------------------------------------------
            $actionError = $null

            if ($actionTaken -eq 'Disable' -or ($actionTaken -eq 'Delete' -and -not $EnableDeletion)) {
                if ($enabledCheck -ne $false) {
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

            $actionInputRow = if ($actionError) { $inputRow } else { $null }
            $resultList.Add((New-ResultEntry `
                -UPN $upn -SamAccountName $sam -InactiveDays $inactiveDays `
                -ActionTaken $actionTaken -NotificationStage $notificationStage `
                -NotificationSent $notifySent -NotificationRecipient $notifyRecipient `
                -Status $entryStatus -ErrorMessage $actionError -InputRow $actionInputRow))
        }

        $output.Success = $true
    }
    catch {
        if (-not $output.Error) { $output.Error = $_.Exception.Message }
        Write-Warning "Invoke-InactiveAccountRemediation failed: $($output.Error)"
    }
    finally {
        # Build summary and populate output from whatever was collected before
        # any exception -- this ensures partial results are always returned.
        $summary = [pscustomobject]@{
            Total    = $resultList.Count
            Warned   = @($resultList | Where-Object { $_.ActionTaken -eq 'Notify'  -and $_.Status -eq 'Completed' }).Count
            Disabled = @($resultList | Where-Object { $_.ActionTaken -eq 'Disable' -and $_.Status -eq 'Completed' }).Count
            Deleted  = @($resultList | Where-Object { $_.ActionTaken -eq 'Delete'  -and $_.Status -eq 'Completed' }).Count
            Skipped  = @($resultList | Where-Object { $_.Status -eq 'Skipped' }).Count
            Errors   = @($resultList | Where-Object { $_.Status -eq 'Error' }).Count
            NoOwner  = @($resultList | Where-Object { $_.SkipReason -eq 'NoOwnerFound' }).Count
        }

        Write-Host (("Invoke-InactiveAccountRemediation complete: {0} warned, {1} disabled, {2} deleted, " +
            "{3} skipped, {4} errors, {5} with no resolved owner.") -f
            $summary.Warned, $summary.Disabled, $summary.Deleted,
            $summary.Skipped, $summary.Errors, $summary.NoOwner)

        $output.Summary = $summary
        $output.Results = $resultList.ToArray()

        # Unprocessed: result entries where the owner was resolved but the action could
        # not be completed (notification or account action failed). InputRow is set on
        # these entries during the loop; filtering here is a single expression with no
        # mode branching. Always shaped as the import contract for direct re-run.
        $output.Unprocessed = @(
            $resultList | Where-Object { $_.InputRow } | ForEach-Object { $_.InputRow }
        )

        if (-not $UseExistingGraphSession) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        $output
    }
}
