function New-InactiveAccountLifecycleMessage {
    <#
    .SYNOPSIS
        Builds the HTML notification subject and body for an inactive account lifecycle stage.

    .PARAMETER Stage
        The lifecycle stage: 'Warning', 'Disabled', or 'Deletion'.

    .PARAMETER AccountUPN
        The UPN of the account being notified about.

    .PARAMETER LastActivityDisplay
        Human-readable string of the account's last activity date (e.g. '14 Jan 2025').

    .PARAMETER InactiveDays
        Number of days the account has been inactive.

    .OUTPUTS
        [pscustomobject] with fields Subject and Body.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Stage,

        [Parameter(Mandatory)]
        [string] $AccountUPN,

        [Parameter(Mandatory)]
        [string] $LastActivityDisplay,

        [Parameter(Mandatory)]
        [int] $InactiveDays
    )

    $runDate = (Get-Date).ToString('dd MMM yyyy')

    switch ($Stage) {
        'Warning' {
            $subject = "Action Required: Inactive privileged account -- $AccountUPN"
            $body = @"
<p>This is an automated notification from the Identity Lifecycle Management system.</p>
<p>The following privileged account has been identified as inactive and is scheduled
for automatic disablement.</p>
<table>
  <tr><td><b>Account</b></td><td>$AccountUPN</td></tr>
  <tr><td><b>Last Activity</b></td><td>$LastActivityDisplay</td></tr>
  <tr><td><b>Inactive Days</b></td><td>$InactiveDays</td></tr>
</table>
<p>If this account is still required, please contact the IAM team to arrange reactivation.
If it is no longer needed, no action is required -- the account will be disabled automatically.</p>
<p><i>Identity Lifecycle Management automation. Do not reply to this notification.</i></p>
"@
        }
        'Disabled' {
            $subject = "Notice: Privileged account disabled due to inactivity -- $AccountUPN"
            $body = @"
<p>This is an automated notification from the Identity Lifecycle Management system.</p>
<p>The following privileged account has been <b>disabled</b> due to inactivity.</p>
<table>
  <tr><td><b>Account</b></td><td>$AccountUPN</td></tr>
  <tr><td><b>Last Activity</b></td><td>$LastActivityDisplay</td></tr>
  <tr><td><b>Inactive Days</b></td><td>$InactiveDays</td></tr>
  <tr><td><b>Disabled On</b></td><td>$runDate</td></tr>
</table>
<p>The account will be submitted for deletion if it remains inactive.
To request reactivation please contact the IAM team.</p>
<p><i>Identity Lifecycle Management automation. Do not reply to this notification.</i></p>
"@
        }
        'Deletion' {
            $subject = "Notice: Privileged account submitted for deletion -- $AccountUPN"
            $body = @"
<p>This is an automated notification from the Identity Lifecycle Management system.</p>
<p>The following privileged account has been <b>submitted for deletion</b> following the
organisation's identity off-boarding process.</p>
<table>
  <tr><td><b>Account</b></td><td>$AccountUPN</td></tr>
  <tr><td><b>Last Activity</b></td><td>$LastActivityDisplay</td></tr>
  <tr><td><b>Inactive Days</b></td><td>$InactiveDays</td></tr>
  <tr><td><b>Submitted On</b></td><td>$runDate</td></tr>
</table>
<p>If you believe this action was taken in error, please contact the IAM team immediately.</p>
<p><i>Identity Lifecycle Management automation. Do not reply to this notification.</i></p>
"@
        }
        default {
            $subject = "Identity Lifecycle Notice -- $AccountUPN"
            $body    = "<p>Lifecycle event for $AccountUPN (stage: $Stage, inactive days: $InactiveDays).</p>"
        }
    }

    return [pscustomobject]@{ Subject = $subject; Body = $body }
}
