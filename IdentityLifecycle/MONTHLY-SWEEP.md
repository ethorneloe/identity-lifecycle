# Monthly Inactive Account Sweep

## Overview

`Invoke-MonthlyInactiveAccountSweep` is a stateless once-monthly orchestrator that
evaluates a pre-identified list of inactive privileged accounts against absolute
inactivity thresholds and takes the required action in a single pass.

Unlike `Invoke-InactiveAccountSweep` (which maintains state in Azure Table Storage
across daily runs and advances accounts through staged grace periods), this function
has no persistent state. Given the same input list it will always re-evaluate from
scratch and apply whichever action the current inactivity duration warrants.

---

## Intended usage

```
1. Export inactive privileged accounts from your dashboard tool (SIEM, IGA, etc.)
2. Import-Csv (or pass the objects directly) to build the input list
3. Run Invoke-MonthlyInactiveAccountSweep once
4. Inspect the returned output object -- Results and Summary
```

The function never throws. It always returns a structured object that the caller
can inspect and log regardless of what went wrong.

---

## Input format

Pass an array of objects via `-Accounts`. The expected fields match a standard
dashboard export:

| Field | Type | Required | Notes |
|---|---|---|---|
| `UserPrincipalName` | string | Yes | Primary key; rows with no value are silently discarded |
| `SamAccountName` | string | AD accounts | Used for AD lookup and owner resolution; absent for Entra-native |
| `Enabled` | bool/string | No | Enabled state at export time; used to detect disable-since-export |
| `LastLogonDate` | datetime/string | No | Present in export; not used — live query always replaces it |
| `Created` | datetime/string | No | Last-resort baseline for accounts that have never logged on |
| `EntraObjectId` | string | Entra accounts | Required for Entra-native accounts; optional for AD accounts with Entra sign-in |
| `entraLastSignInAEST` | datetime/string | No | Present in export; not used — live query always replaces it |
| `Description` | string | No | Passed to action functions |
| `Brand`, `Modified`, `PasswordLastSet`, `PasswordNeverExpires`, `EntraSynced`, `entraCreatedDateAEST` | — | No | Present in export; not read by the sweep |

Routing is determined by field presence, not by `Source` or `OnPremisesSyncEnabled`:
- `SamAccountName` present → AD path (also queries Entra if `EntraObjectId` is present)
- `SamAccountName` absent → Entra-native path (requires `EntraObjectId`)

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Accounts` | object[] | Mandatory | Input account rows |
| `-Sender` | string | Mandatory | Mailbox UPN for Graph mail (needs Mail.Send) |
| `-WarnThreshold` | int | 90 | Inactivity days to trigger Warning notification |
| `-DisableThreshold` | int | 120 | Inactivity days to disable account |
| `-DeleteThreshold` | int | 180 | Inactivity days to delete account |
| `-EnableDeletion` | switch | Off | Actually call Remove-InactiveAccount; without this, accounts at DeleteThreshold are disabled with a Deletion notification but not removed |
| `-ClientId` | string | — | Certificate param set: Entra app ID |
| `-TenantId` | string | — | Certificate param set: Entra tenant ID |
| `-CertificateThumbprint` | string | — | Certificate param set: cert thumbprint |
| `-UseExistingGraphSession` | switch | Off | Skip Graph connect/disconnect (use pre-established session) |
| `-SkipModuleImport` | switch | Off | Skip Import-Module calls (tests only) |
| `-WhatIf` | switch | — | Preview actions without executing them |

---

## Threshold model

Thresholds are **absolute inactivity durations**, not staged. The function takes the
highest-severity action warranted by the current inactivity in a single run:

```
InactiveDays >= DeleteThreshold  → Deletion notification + Remove (or Disable if -EnableDeletion not set)
InactiveDays >= DisableThreshold → Disabled notification + Disable
InactiveDays >= WarnThreshold    → Warning notification only
InactiveDays < WarnThreshold     → Skipped (ActivityDetected)
```

An account inactive for 150 days will be disabled in a single run even if it was
never warned first. This is intentional — the monthly sweep is not an incremental
process.

---

## Output object

The function always returns a `[pscustomobject]` with these top-level fields:

| Field | Type | Notes |
|---|---|---|
| `Success` | bool | `$true` only if the entire run completed without a fatal error |
| `Error` | string | Set on fatal errors (connect failure, module import failure, Send-GraphMail throw) |
| `Summary` | pscustomobject | Null on fatal errors; see below |
| `Results` | pscustomobject[] | Empty on fatal errors; one entry per processed account |

### Summary fields

| Field | Meaning |
|---|---|
| `Total` | Accounts that produced a result entry (excludes no-UPN rows) |
| `Warned` | Accounts successfully notified at Warning stage |
| `Disabled` | Accounts successfully disabled |
| `Deleted` | Accounts successfully deleted |
| `Skipped` | Accounts skipped (`ActivityDetected`, `DisabledSinceExport`, or `NoOwnerFound`) |
| `Errors` | Accounts where at least one step failed |
| `NoOwner` | Accounts skipped because no owner could be resolved |

### Results entry fields

| Field | Type | Notes |
|---|---|---|
| `UPN` | string | |
| `SamAccountName` | string | |
| `InactiveDays` | int? | Null for skips/errors before activity is computed |
| `ActionTaken` | string | `None`, `Notify`, `Disable`, `Delete` — what the sweep decided to do |
| `NotificationStage` | string | `Warning`, `Disabled`, `Deletion`, or null — drives the email template |
| `NotificationSent` | bool | |
| `NotificationRecipient` | string | Address the email went to; null if no owner resolved |
| `Status` | string | `Completed` — all required steps succeeded; `Skipped` — no action warranted; `Error` — at least one step failed |
| `SkipReason` | string | Why the account was skipped: `ActivityDetected`, `DisabledSinceExport`, `NoOwnerFound`, or null for completed/error entries |
| `Error` | string | Error detail if any step failed; null otherwise |
| `Timestamp` | string | ISO 8601 UTC timestamp of when this entry was produced |

---

## Execution flow (per account)

```
1. Skip rows with no UPN
2. Live check
   a. AD path (SamAccountName present):
      - Get-ADUser → live Enabled, LastLogonDate, extensionAttribute14
      - If EntraObjectId present: Get-MgUser → live SignInActivity
   b. Entra path (no SAM):
      - Get-MgUser → live AccountEnabled, SignInActivity
   c. If live Enabled = false and export said enabled → Skipped/DisabledSinceExport
3. Compute InactiveDays
   - Use live logon/sign-in; last resort: WhenCreated from input row (for never-logged-on accounts)
   - If no date at all → Error
   - If InactiveDays < WarnThreshold → Skipped/ActivityDetected
4. Owner resolution (all accounts)
   - Prefix strip: strip leading prefix from SamAccountName, verify SAM exists in AD (primary)
   - extensionAttribute14 'owner=<sam>' fallback (for accounts without a naming-convention owner)
   - Unresolved → Skipped/NoOwnerFound; no notification or action taken
5. Threshold evaluation → determines ActionTaken and NotificationStage
6. Send-GraphMail (throws on failure → outer catch → fatal, loop aborts)
7. Disable-InactiveAccount or Remove-InactiveAccount
   - Failure recorded in result entry; loop continues to next account
8. Result entry written
```

---

## Functions used

### Orchestrated by this function

| Function | File | What it does |
|---|---|---|
| `Disable-InactiveAccount` | `functions/public/InactiveAccounts/Disable-InactiveAccount.ps1` | Disables the account in AD (via `Disable-ADAccount -Identity SamAccountName`) or Entra (via `Update-MgUser`). Routes by `Account.Source`. |
| `Remove-InactiveAccount` | `functions/public/InactiveAccounts/Remove-InactiveAccount.ps1` | Deletes Entra-native accounts via `Remove-MgUser`. **AD deletion is a stub** — throws an exception; replace with your org's offboarding workflow. |
| `Send-GraphMail` | Not yet implemented | Sends HTML email via Microsoft Graph. Called with `-Sender`, `-ToRecipients`, `-Subject`, `-Body`. **This function does not exist in the module yet** — it must be created before the monthly sweep can run in production. |
| `New-InactiveAccountLifecycleMessage` | `functions/public/InactiveAccounts/New-InactiveAccountLifecycleMessage.ps1` | Builds the HTML email subject and body for a given stage (Warning / Disabled / Deletion). |

### Called internally during processing

| Function | File | What it does |
|---|---|---|
| `Get-ADAccountOwner` | `functions/public/Identity/Get-ADAccountOwner.ps1` | Resolves the owning standard account. Tries prefix-strip first (primary — naming convention is authoritative), then `extensionAttribute14 owner=<sam>` as a fallback for accounts that don't follow the prefix convention. Uses the live `extensionAttribute14` value fetched during the live check. |
| `Resolve-EntraSignIn` | `functions/public/Identity/Resolve-EntraSignIn.ps1` | Extracts the most recent sign-in datetime from a Graph user object, considering both interactive and non-interactive sign-in timestamps. |

### External cmdlets required

| Cmdlet | Module | Used for |
|---|---|---|
| `Get-ADUser` | ActiveDirectory (RSAT) | Live check, owner verification, owner email lookup |
| `Disable-ADAccount` | ActiveDirectory (RSAT) | Disabling AD accounts (called inside `Disable-InactiveAccount`) |
| `Get-MgUser` | Microsoft.Graph.Users | Entra live check and sign-in data for hybrid accounts |
| `Update-MgUser` | Microsoft.Graph.Users | Disabling Entra-native accounts (called inside `Disable-InactiveAccount`) |
| `Remove-MgUser` | Microsoft.Graph.Users | Deleting Entra-native accounts (called inside `Remove-InactiveAccount`) |
| `Connect-MgGraph` | Microsoft.Graph.Authentication | Graph session setup (skipped with `-UseExistingGraphSession`) |
| `Disconnect-MgGraph` | Microsoft.Graph.Authentication | Graph session teardown in `finally` |

---

## Known gaps / stubs

### `Send-GraphMail` — not implemented

The orchestrator calls `Send-GraphMail` but no such function exists in the module.
The test suite mocks it. Before running in production you must implement it.

Expected signature (inferred from call site and mock):

```powershell
function Send-GraphMail {
    param(
        [string]   $Sender,
        [string[]] $ToRecipients,
        [string]   $Subject,
        [string]   $Body,
        [string]   $BodyType = 'HTML',
        [string]   $ErrorAction
    )
}
```

It should send via `Send-MgUserMail` or the Graph `sendMail` endpoint.
The connected identity needs `Mail.Send` delegated to the `-Sender` mailbox.

### `Remove-InactiveAccount` — AD path is a stub

`Remove-InactiveAccount` supports Entra-native deletion (moves account to the Entra
recycle bin via `Remove-MgUser`). The AD path throws immediately:

```powershell
throw "AD account deletion is not yet implemented for: $target"
```

Replace this with your organisation's AD offboarding process (MIM workflow,
SailPoint request, direct `Remove-ADObject`, etc.).


---

## Operational modes

The function is deliberately flexible. The same code handles every pattern below by
varying what you feed it and which parameters you set.

---

### Mode 1 — Full single pass (warn + disable + delete in one run)

The simplest pattern. Feed the entire enabled-inactive list, set all three thresholds,
and let the function apply whichever action each account warrants.

```powershell
$accounts = Import-Csv 'C:\Reports\InactivePrivAccounts.csv'

$result = Invoke-MonthlyInactiveAccountSweep `
    -Accounts              $accounts `
    -Sender                'iam-automation@corp.local' `
    -ClientId              $appId `
    -TenantId              $tenantId `
    -CertificateThumbprint $thumb `
    -EnableDeletion
```

Accounts at 90+ days get a Warning email. Accounts at 120+ days are disabled. Accounts
at 180+ days are deleted. All in one run. An account inactive for 150 days is disabled
immediately — it does not need a warning run first. That is intentional.

**When to use**: When you want a fully automated remediation pipeline and your risk
appetite allows disablement and deletion to happen in the same job as the warning email.

---

### Mode 2 — Warn and disable only; defer deletion

Omit `-EnableDeletion`. Accounts at the delete threshold receive a Deletion notification
and are disabled, but `Remove-InactiveAccount` is never called.

```powershell
$result = Invoke-MonthlyInactiveAccountSweep `
    -Accounts              $accounts `
    -Sender                'iam-automation@corp.local' `
    -ClientId              $appId -TenantId $tenantId -CertificateThumbprint $thumb
    # -EnableDeletion intentionally absent
```

Review `$result.Results | Where-Object { $_.NotificationStage -eq 'Deletion' }` each
month. When you are confident those accounts are truly dead, run Mode 3.

**When to use**: When deletion requires a secondary approval step, a ticket, or a
manual sign-off before accounts are permanently removed. Deletion is a deliberate,
separate action.

---

### Mode 3 — Deletion-only pass for old disabled accounts

Feed a separate export of already-disabled privileged accounts that have been sitting
disabled long enough to warrant removal. Set a low `WarnThreshold` so every account in
the list clears the activity check immediately (they are all inactive), then set
`-EnableDeletion`.

```powershell
# Export: disabled priv accounts inactive for 180+ days
$disabledOld = Import-Csv 'C:\Reports\DisabledPrivAccounts-180plus.csv'

$result = Invoke-MonthlyInactiveAccountSweep `
    -Accounts              $disabledOld `
    -Sender                'iam-automation@corp.local' `
    -WarnThreshold         1 `
    -DisableThreshold      1 `
    -DeleteThreshold       180 `
    -EnableDeletion `
    -ClientId              $appId -TenantId $tenantId -CertificateThumbprint $thumb
```

Because the accounts are already disabled, `liveEnabled = $false` is detected at the
action step and `Disable-InactiveAccount` is skipped with no error. The result entry
gets `Status = Completed`. The function jumps straight to removal when
`InactiveDays >= DeleteThreshold`.

**When to use**: When you run the warn/disable pass monthly on enabled accounts (Mode 2)
and want a separate, explicit quarterly or ad-hoc deletion pass for the accumulation of
disabled accounts. Keeps the two concerns — remediation and cleanup — fully separated.

---

### Mode 4 — Warning-only pass (notification, no action)

Set `DisableThreshold` and `DeleteThreshold` far above any realistic inactivity value so
the threshold check never reaches the action phase.

```powershell
$result = Invoke-MonthlyInactiveAccountSweep `
    -Accounts              $accounts `
    -Sender                'iam-automation@corp.local' `
    -WarnThreshold         90 `
    -DisableThreshold      99999 `
    -DeleteThreshold       99999 `
    -ClientId              $appId -TenantId $tenantId -CertificateThumbprint $thumb
```

Every account at 90+ days gets a Warning email. No account is ever disabled or deleted.

**When to use**: During an initial rollout when you want owners to receive notifications
and confirm the process before you start taking automated disablement actions. Run in
warning-only mode for one or two cycles to build confidence, then lower the thresholds.

---

### Mode 5 — Preview with -WhatIf

`-WhatIf` suppresses all side effects: no emails sent, no accounts disabled or deleted.
The function still runs the full live check and threshold evaluation and returns a
complete result object showing what would have happened.

```powershell
$result = Invoke-MonthlyInactiveAccountSweep `
    -Accounts              $accounts `
    -Sender                'iam-automation@corp.local' `
    -EnableDeletion `
    -UseExistingGraphSession `
    -WhatIf

$result.Summary
$result.Results | Format-Table UPN, InactiveDays, ActionTaken, NotificationStage, SkipReason
```

**When to use**: Before the first production run of a new export, after changing
thresholds, or any time you want to audit what the sweep would do without committing.

---

## Example — inspect results after a run

```powershell
Import-Module .\IdentityLifecycle\IdentityLifecycle.psd1 -Force

$accounts = Import-Csv 'C:\Reports\InactivePrivAccounts.csv'

$result = Invoke-MonthlyInactiveAccountSweep `
    -Accounts              $accounts `
    -Sender                'iam-automation@corp.local' `
    -ClientId              $appId `
    -TenantId              $tenantId `
    -CertificateThumbprint $thumb `
    -EnableDeletion

if (-not $result.Success) {
    Write-Error "Sweep failed: $($result.Error)"
}
else {
    $result.Summary

    # Accounts that need an owner assigned before next run
    $result.Results | Where-Object { $_.SkipReason -eq 'NoOwnerFound' } |
        Select-Object UPN, SamAccountName, InactiveDays

    # Any step that errored
    $result.Results | Where-Object { $_.Status -eq 'Error' } |
        Select-Object UPN, Error
}
```

---

## Tests

```powershell
. .\IdentityLifecycle\tests-monthly\Invoke-MonthlyTest.ps1
```

185 assertions. See [tests-monthly/README.md](tests-monthly/README.md)
for full scenario coverage.
