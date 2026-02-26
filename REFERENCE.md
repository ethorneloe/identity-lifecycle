# IdentityLifecycle

A PowerShell module for managing the lifecycle of inactive prefixed accounts across Active Directory and Entra ID.

## What it does

This module targets accounts identified by a SAMAccountName / UPN prefix — for example `admin`, `priv` — and evaluates each matching account against absolute inactivity thresholds, sending notifications at each stage and ultimately disabling or optionally deleting dormant accounts. The prefix set is fully configurable, making this suitable for any account population that needs a distinct inactivity policy.

```
InactiveDays >= WarnThreshold    →  Warning notification (email to owner)
InactiveDays >= DisableThreshold →  Disabled notification + account disabled
InactiveDays >= DeleteThreshold  →  Deletion notification + account removed (requires -EnableDeletion)
InactiveDays < WarnThreshold     →  Skipped (ActivityDetected)
```

All thresholds are configurable. An account inactive for 150 days is disabled in a single run even if it was never warned first — the sweep applies the highest-severity action warranted by the current inactivity duration.

Deletion is an explicit opt-in. Accounts that reach the delete threshold are held in their current disabled state until `-EnableDeletion` is passed. This is an intentional safety gate.

---

## One function, two modes

`Invoke-InactiveAccountRemediation` is the single entry point. The parameter set determines how accounts are sourced:

### Import mode (`-Accounts -Prefixes`)

Takes a pre-identified list of accounts (from a SIEM/IGA export or the `Unprocessed` output of a previous run) and evaluates each one in a single pass. A live directory re-query confirms current activity and enabled state before any action is taken. The `-Prefixes` filter guards against mis-routed inputs by silently discarding any row whose SAM or UPN does not start with a recognised prefix.

If the job fails partway through, `$result.Unprocessed` contains accounts worth automated retry: those where the owner was confirmed and a valid notification recipient resolved, but something downstream then failed (mail error, action error), plus any accounts that were never reached because a fatal exception aborted the run mid-batch. Pass `$result.Unprocessed` directly as `-Accounts` on the next run — only those accounts are retried.

### Discovery mode (`-Prefixes -ADSearchBase`)

Discovers accounts in real time by querying AD and Entra ID using the configured prefixes. No input list is required. It applies the same threshold model and produces the same output shape — `$result.Unprocessed` is already shaped to feed directly back into import mode for a targeted retry.

---

## Structure

```
functions/public/
  InactiveAccounts/    # Orchestrator and action functions
  Identity/            # Account collection from AD and Entra ID; owner resolution
tests/
  Invoke-InactiveAccountRemediation/
    Invoke-Test.ps1    # Merged test harness (import + discovery modes)
```

---

## Prerequisites

- PowerShell 5.1+
- `ActiveDirectory` module (RSAT)
- `Microsoft.Graph` module (`Connect-MgGraph` pre-authenticated, or pass `-ClientId/-TenantId/-CertificateThumbprint` for the Graph read principal)
- A `Send-GraphMail` implementation available in the session (not part of this module); requires a separate mail service principal with `Mail.Send`

---

## Input format (import mode)

Pass an array of objects via `-Accounts`. The expected fields match a standard dashboard export:

| Field | Type | Required | Notes |
|---|---|---|---|
| `UserPrincipalName` | string | Yes | Primary key; rows with no value produce a `Skipped/NoUPN` result entry |
| `SamAccountName` | string | AD accounts | Used for AD lookup and owner resolution; absent for Entra-native |
| `Enabled` | bool/string | No | Enabled state at export time; used to detect disable-since-export |
| `LastLogonDate` | datetime/string | No | Present in export; not used — live query always replaces it |
| `Created` | datetime/string | No | Last-resort baseline for accounts that have never logged on |
| `EntraObjectId` | string | Entra accounts | Required for Entra-native accounts; optional for AD accounts with Entra sign-in |
| `entraLastSignInAEST` | datetime/string | No | Present in export; not used — live query always replaces it |
| `Description` | string | No | Passed to action functions |

Routing is determined by field presence, not by `Source` or `OnPremisesSyncEnabled`:
- `SamAccountName` present → AD path (also queries Entra if `EntraObjectId` is present)
- `SamAccountName` absent → Entra-native path (requires `EntraObjectId`)

---

## Parameters

### Import mode

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Accounts` | object[] | Mandatory | Input account rows |
| `-Prefixes` | string[] | Mandatory | SAM/UPN prefixes to accept, e.g. `@('admin.','priv.')`; rows not matching any prefix are silently discarded |
| `-MailSender` | string | Mandatory | Mailbox UPN used as the From address for notification emails |
| `-MailClientId` | string | Mandatory | Application (client) ID of the mail service principal |
| `-MailTenantId` | string | Mandatory | Entra tenant ID for the mail service principal |
| `-MailCertificateThumbprint` | string | Mandatory | Certificate thumbprint for the mail service principal |
| `-WarnThreshold` | int | 90 | Inactivity days to trigger Warning notification |
| `-DisableThreshold` | int | 120 | Inactivity days to disable account |
| `-DeleteThreshold` | int | 180 | Inactivity days to delete account |
| `-EnableDeletion` | switch | Off | Actually call Remove-InactiveAccount; without this, accounts at DeleteThreshold are disabled with a Deletion notification but not removed |
| `-NotificationRecipientOverride` | string | — | When set, all notifications go to this address instead of the resolved owner. The real owner is still recorded in the result for auditability. Use during testing to avoid notifying real owners. |
| `-ClientId` | string | — | Certificate param set: Entra app ID for Graph read access |
| `-TenantId` | string | — | Certificate param set: Entra tenant ID for Graph read access |
| `-CertificateThumbprint` | string | — | Certificate param set: cert thumbprint for Graph read access |
| `-UseExistingGraphSession` | switch | Off | Skip Graph connect/disconnect |
| `-WhatIf` | switch | — | Preview actions without executing them |

### Discovery mode

Same parameters as import mode, except `-Accounts` is replaced with `-ADSearchBase`:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Prefixes` | string[] | Mandatory | SAM/UPN prefixes to target, e.g. `@('admin.','priv.')` |
| `-ADSearchBase` | string | Mandatory | Distinguished name of the OU to scope AD discovery |

All other parameters are the same as import mode.

---

## Output object

`Invoke-InactiveAccountRemediation` always returns a `[pscustomobject]` — it never throws. Partial results are preserved via the `finally` block even on mid-batch failure.

| Field | Type | Notes |
|---|---|---|
| `Success` | bool | `$true` only if the entire run completed without a fatal error |
| `Error` | string | Set on fatal errors (connect failure, module import failure, Send-GraphMail throw) |
| `Summary` | pscustomobject | Null on fatal errors; see below |
| `Results` | pscustomobject[] | Empty on fatal errors; one entry per processed account |
| `Unprocessed` | pscustomobject[] | Accounts where the owner was confirmed but something downstream failed; shaped as import contract; empty when all accounts resolved |

### Summary fields

| Field | Meaning |
|---|---|
| `Total` | Accounts that produced a result entry (includes NoUPN skips) |
| `Warned` | Accounts successfully notified at Warning stage |
| `Disabled` | Accounts successfully disabled |
| `Deleted` | Accounts successfully deleted |
| `Skipped` | Accounts skipped (`NoUPN`, `ActivityDetected`, `DisabledSinceExport`, `NoOwnerFound`, or `NoEmailFound`) |
| `Errors` | Accounts where at least one step failed |
| `NoOwner` | Accounts skipped because no owner could be resolved |

### Results entry fields

| Field | Type | Notes |
|---|---|---|
| `UserPrincipalName` | string | |
| `SamAccountName` | string | |
| `InactiveDays` | int? | Null for skips/errors before activity is computed |
| `ActionTaken` | string | `None`, `Notify`, `Disable`, `Delete` |
| `NotificationStage` | string | `Warning`, `Disabled`, `Deletion`, or null |
| `NotificationSent` | bool | |
| `NotificationRecipient` | string | Resolved owner address (always the real owner, regardless of any override) |
| `Status` | string | `Completed`, `Skipped`, or `Error` |
| `SkipReason` | string | `NoUPN`, `ActivityDetected`, `DisabledSinceExport`, `NoOwnerFound`, `NoEmailFound`, or null |
| `Error` | string | Error detail if any step failed; null otherwise |
| `Timestamp` | string | ISO 8601 UTC |

### Unprocessed entries

`Unprocessed` contains accounts from two sources, both shaped as the import contract so they can be passed directly as `-Accounts` on the next run:

1. **Owner confirmed, downstream failed** — the owner was resolved and a valid notification recipient confirmed, but then something mechanical failed (mail error or action error). These are safe to retry automatically.
2. **Never reached** — a fatal exception aborted the loop mid-batch and these accounts never got a result entry. They are passed through from the working list as-is.

Accounts with `Status = Skipped` are **not** in `Unprocessed` — they were deliberate decisions (`NoUPN`, `ActivityDetected`, `DisabledSinceExport`, `NoOwnerFound`), not mechanical failures. Early-exit failures before owner resolution (no SAM + no EntraObjectId, AD lookup error) are also excluded — these require human investigation rather than automated retry.

---

## Execution flow (per account)

```
1. Rows with no UPN → result entry with Status=Skipped, SkipReason=NoUPN
2. Live check
   a. AD path (SamAccountName present):
      - Get-ADUser → live Enabled, LastLogonDate, extensionAttribute14
      - If EntraObjectId present: Get-MgUser → live SignInActivity
   b. Entra path (no SAM):
      - Get-MgUser → live AccountEnabled, SignInActivity
   c. If live Enabled = false and export said enabled → Skipped/DisabledSinceExport
   [Discovery mode: live check is skipped — data already comes from the live directory]
3. Compute InactiveDays
   - Use live logon/sign-in; last resort: Created from input row
   - If no date at all → Error
   - If InactiveDays < WarnThreshold → Skipped/ActivityDetected
4. Owner resolution (first strategy that yields a recipient wins)
   - Prefix strip: strip leading prefix from SamAccountName, verify SAM exists in AD (primary)
   - Extension attribute 'owner=<sam>' fallback (extensionAttribute14; swap for whichever your org uses)
   - Entra sponsor: if both AD strategies fail and EntraObjectId is present, query Get-MgUserSponsor;
     first sponsor's Mail (or UPN) is used directly as the notification recipient
   - All strategies exhausted → Skipped/NoOwnerFound
5. Owner email lookup via Get-ADUser -Properties EmailAddress (AD-resolved owner only)
   - Empty or failed → Skipped/NoEmailFound
6. Threshold evaluation → determines ActionTaken and NotificationStage
7. Send-GraphMail (throws on failure → fatal, loop aborts)
8. Disable-InactiveAccount or Remove-InactiveAccount
   - Failure recorded in result entry; loop continues to next account
9. Result entry written
```

In `finally`: Summary tallied; `Unprocessed` filtered from result entries that carry an `InputRow` (set only after owner resolution succeeds and a valid recipient is confirmed).

---

## Quick start

### Import mode

```powershell
Import-Module .\IdentityLifecycle

$accounts = Import-Csv 'C:\Reports\InactivePrivAccounts.csv'

$result = Invoke-InactiveAccountRemediation `
    -Accounts                  $accounts `
    -Prefixes                  @('admin', 'priv') `
    -MailSender                'iam-automation@corp.local' `
    -MailClientId              $mailAppId `
    -MailTenantId              $tenantId `
    -MailCertificateThumbprint $mailThumb `
    -ClientId                  $graphAppId `
    -TenantId                  $tenantId `
    -CertificateThumbprint     $graphThumb `
    -EnableDeletion

$result.Summary
$result.Results | Where-Object { $_.Status -eq 'Error' } | Select-Object UPN, Error

# Re-run for any accounts where owner was confirmed but something downstream failed
if ($result.Unprocessed) {
    $retry = Invoke-InactiveAccountRemediation `
        -Accounts                  $result.Unprocessed `
        -Prefixes                  @('admin', 'priv') `
        -MailSender                'iam-automation@corp.local' `
        -MailClientId              $mailAppId `
        -MailTenantId              $tenantId `
        -MailCertificateThumbprint $mailThumb `
        -ClientId                  $graphAppId `
        -TenantId                  $tenantId `
        -CertificateThumbprint     $graphThumb `
        -EnableDeletion
}
```

### Discovery mode

```powershell
Import-Module .\IdentityLifecycle

$result = Invoke-InactiveAccountRemediation `
    -Prefixes                  @('admin', 'priv') `
    -ADSearchBase              'OU=PrivilegedAccounts,DC=corp,DC=local' `
    -MailSender                'iam-automation@corp.local' `
    -MailClientId              $mailAppId `
    -MailTenantId              $tenantId `
    -MailCertificateThumbprint $mailThumb `
    -ClientId                  $graphAppId `
    -TenantId                  $tenantId `
    -CertificateThumbprint     $graphThumb `
    -EnableDeletion

$result.Summary
$result.Results | Where-Object { $_.Status -eq 'Error' } | Select-Object UPN, Error

# Re-run failures in import mode (Unprocessed is already import-contract shaped)
if ($result.Unprocessed) {
    $retry = Invoke-InactiveAccountRemediation `
        -Accounts                  $result.Unprocessed `
        -Prefixes                  @('admin', 'priv') `
        -MailSender                'iam-automation@corp.local' `
        -MailClientId              $mailAppId `
        -MailTenantId              $tenantId `
        -MailCertificateThumbprint $mailThumb `
        -ClientId                  $graphAppId `
        -TenantId                  $tenantId `
        -CertificateThumbprint     $graphThumb `
        -EnableDeletion
}
```

### Dry run / WhatIf

`-WhatIf` suppresses all side effects (no emails sent, no accounts disabled or deleted) while still running the full live check and threshold evaluation and returning a complete result object:

```powershell
$result = Invoke-InactiveAccountRemediation `
    -Accounts $accounts -Prefixes @('admin', 'priv') `
    -MailSender 'iam@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
    -UseExistingGraphSession -WhatIf

$result.Results | Format-Table UPN, InactiveDays, ActionTaken, NotificationStage, SkipReason
```

---

## Operational modes

The same function handles all patterns below by varying the input and parameters.

### Mode 1 — Full single pass (warn + disable + delete in one run)

```powershell
$result = Invoke-InactiveAccountRemediation `
    -Accounts $accounts -Prefixes @('admin', 'priv') `
    -MailSender 'iam-automation@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
    -ClientId $graphAppId -TenantId $tenantId -CertificateThumbprint $graphThumb `
    -EnableDeletion
```

Accounts at 90+ days get a Warning email. Accounts at 120+ days are disabled. Accounts at 180+ days are deleted. All in one run.

### Mode 2 — Warn and disable only; defer deletion

Omit `-EnableDeletion`. Accounts at the delete threshold receive a Deletion notification and are disabled, but are not removed. Review `$result.Results | Where-Object { $_.NotificationStage -eq 'Deletion' }` and run Mode 3 when ready.

### Mode 3 — Deletion-only pass for old disabled accounts

```powershell
$disabledOld = Import-Csv 'C:\Reports\DisabledPrivAccounts-180plus.csv'

$result = Invoke-InactiveAccountRemediation `
    -Accounts $disabledOld -Prefixes @('admin', 'priv') `
    -MailSender 'iam-automation@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
    -WarnThreshold 1 -DisableThreshold 1 -DeleteThreshold 180 `
    -EnableDeletion `
    -ClientId $graphAppId -TenantId $tenantId -CertificateThumbprint $graphThumb
```

Already-disabled accounts skip the disable call and go straight to removal.

### Mode 4 — Warning-only pass (notification, no action)

```powershell
$result = Invoke-InactiveAccountRemediation `
    -Accounts $accounts -Prefixes @('admin', 'priv') `
    -MailSender 'iam-automation@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
    -WarnThreshold 90 -DisableThreshold 99999 -DeleteThreshold 99999 `
    -ClientId $graphAppId -TenantId $tenantId -CertificateThumbprint $graphThumb
```

### Mode 5 — Preview with -WhatIf

```powershell
$result = Invoke-InactiveAccountRemediation `
    -Accounts $accounts -Prefixes @('admin', 'priv') `
    -MailSender 'iam-automation@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
    -EnableDeletion -UseExistingGraphSession -WhatIf

$result.Summary
$result.Results | Format-Table UPN, InactiveDays, ActionTaken, NotificationStage, SkipReason
```

### Mode 6 — Retry unprocessed accounts

```powershell
# Run 1 — discovery mode
$result = Invoke-InactiveAccountRemediation `
    -Prefixes @('admin', 'priv') -ADSearchBase 'OU=PrivilegedAccounts,DC=corp,DC=local' `
    -MailSender 'iam-automation@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
    -ClientId $graphAppId -TenantId $tenantId -CertificateThumbprint $graphThumb -EnableDeletion

# Run 2 — import mode retry for accounts where something downstream failed
if ($result.Unprocessed) {
    $result2 = Invoke-InactiveAccountRemediation `
        -Accounts $result.Unprocessed -Prefixes @('admin', 'priv') `
        -MailSender 'iam-automation@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
        -ClientId $graphAppId -TenantId $tenantId -CertificateThumbprint $graphThumb -EnableDeletion
}
```

`Unprocessed` from a discovery run is already in import-contract shape, so cross-mode retry works directly.

---

## Known gaps / stubs

### `Send-GraphMail` — not implemented in this module

The orchestrator calls `Send-GraphMail` but it is not part of this module. The test suite mocks it. Before running in production you must supply an implementation (e.g. from a shared utilities module).

The orchestrator calls it with this signature:

```powershell
Send-GraphMail `
    -Sender                'iam-automation@corp.local' `
    -ClientID              $MailClientId `
    -Tenant                $MailTenantId `
    -CertificateThumbprint $MailCertificateThumbprint `
    -ToRecipients          @('owner@corp.local') `
    -Subject               'Subject text -- account@corp.local' `
    -Body                  '<html>...</html>' `
    -BodyType              'HTML' `
    -ErrorAction           Stop
```

Note that the mail service principal (`-ClientID`, `-Tenant`, `-CertificateThumbprint`) is a separate app registration from the Graph read principal used for `Connect-MgGraph`. `Send-GraphMail` is expected to manage its own authentication internally using those credentials. The app registration requires `Mail.Send` application permission.

### `Remove-InactiveAccount` — AD path is a stub

`Remove-InactiveAccount` supports Entra-native deletion via `Remove-MgUser`. The AD path throws immediately:

```powershell
throw "AD account deletion is not yet implemented for: $target"
```

Replace this with your organisation's AD offboarding process.

---

## Running tests

```powershell
# Merged test suite (import + discovery modes)
. .\IdentityLifecycle\tests\Invoke-InactiveAccountRemediation\Invoke-Test.ps1

# Or via the runner script
. .\run-tests.ps1
```
