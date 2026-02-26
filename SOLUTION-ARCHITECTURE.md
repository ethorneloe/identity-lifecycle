# Identity Lifecycle — Solution Architecture

## Overview

A PowerShell module (`IdentityLifecycle`) that automates the lifecycle management of
inactive accounts across an on-premises Active Directory and Entra ID
(formerly Azure AD) tenant. The module runs on an Azure Automation hybrid worker — a
server that sits on-premises and has line of sight to the AD domain — and orchestrates
discovery, notification, disablement, and deletion of accounts that have exceeded
configurable inactivity thresholds.

---

## Runtime Environment

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Azure Automation Account                                                   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Runbook (PowerShell)                                                │  │
│  │  · Retrieves credentials from secure storage                         │  │
│  │  · Imports IdentityLifecycle module                                  │  │
│  │  · Calls Invoke-InactiveAccountRemediation                           │  │
│  │  · Writes result to Log Analytics / Storage                          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│            │                                                                │
│            ▼ (runs on Hybrid Worker)                                        │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  On-Premises Hybrid Runbook Worker                                   │  │
│  │                                                                      │  │
│  │  · Domain-joined server with RSAT (ActiveDirectory module)           │  │
│  │  · Has AD read/write access within scope OU                          │  │
│  │  · Outbound HTTPS to Graph API (api.graph.microsoft.com)             │  │
│  │  · Outbound HTTPS to Azure Automation                                │  │
│  │  · IdentityLifecycle module installed in PowerShell module path      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why a hybrid worker?**

- AD cmdlets (`Get-ADUser`, `Disable-ADAccount`) require RSAT and domain connectivity.
  Cloud-only Automation workers have neither.
- Group Managed Service Accounts (gMSA) or a dedicated service account can be used for
  AD operations without storing a password anywhere.
- Outbound-only connectivity to Graph and Azure: no inbound firewall rules required.

---

## Identity and Authentication

### To Active Directory
The hybrid worker's identity (gMSA or service account) must have:

| Permission | Scope | Purpose |
|---|---|---|
| Read `SamAccountName`, `UserPrincipalName`, `LastLogonDate`, `Enabled`, `whenCreated`, `extensionAttribute14`, `EmailAddress` | Target OU and below | Account discovery and owner resolution |
| Write `Enabled` | Target OU and below | `Disable-ADAccount` |
| Delete objects | Target OU and below | `Remove-ADUser` (if AD deletion is enabled) |

### To Microsoft Graph

Two separate Entra app registrations are used, each with a **certificate credential**
(no client secret):

**Graph read principal** — authenticates `Connect-MgGraph` for directory and sign-in
data. Parameters: `-ClientId`, `-TenantId`, `-CertificateThumbprint`.

Required permissions:

| Permission | Type | Purpose |
|---|---|---|
| `User.Read.All` | Application | Read user objects, sign-in activity, and sponsor relationships |
| `AuditLog.Read.All` | Application | Read `SignInActivity` (last sign-in timestamps) |
| `User.ReadWrite.All` | Application | Disable and delete Entra accounts |

**Mail service principal** — used exclusively by `Send-GraphMail` for outbound
notifications. Parameters: `-MailClientId`, `-MailTenantId`, `-MailCertificateThumbprint`.
`Send-GraphMail` manages its own authentication internally using these credentials.

Required permissions:

| Permission | Type | Purpose |
|---|---|---|
| `Mail.Send` | Application | Send notification emails from the designated mailbox |

### Credential storage

| Secret | Stored in | Retrieved by |
|---|---|---|
| Graph read app certificate | Secure storage (e.g. Automation credential or encrypted variable) | Runbook at runtime |
| Mail service principal certificate | Secure storage | Runbook at runtime |
| Mail sender mailbox UPN (`MailSender`) | Automation variable | Runbook at runtime |
| Graph read tenant ID / client ID | Automation variable (not secret) | Runbook at runtime |
| Mail tenant ID / client ID | Automation variable (not secret) | Runbook at runtime |

---

## Module Structure

```
 IdentityLifecycle/
├── IdentityLifecycle.psd1          Module manifest
├── IdentityLifecycle.psm1          Module loader (dot-sources all public functions)
└── functions/
    └── public/
        ├── InactiveAccounts/
        │   ├── Invoke-InactiveAccountRemediation.ps1   Orchestrator (import + discovery modes)
        │   ├── Disable-InactiveAccount.ps1             Disable in AD or Entra
        │   ├── Remove-InactiveAccount.ps1              Delete from Entra (AD stub pending)
        │   └── New-InactiveAccountLifecycleMessage.ps1 HTML email builder
        └── Identity/
            ├── Get-PrefixedADAccounts.ps1              AD discovery by prefix
            ├── Get-PrefixedEntraAccounts.ps1           Entra discovery by prefix
            ├── Get-ADAccountOwner.ps1                  Owner resolution (prefix-strip + EA14)
            └── Resolve-EntraSignIn.ps1                 Extract most recent sign-in from Graph user
```

---

## Two Orchestration Modes

`Invoke-InactiveAccountRemediation` is the single orchestrator. The parameter set
determines how accounts are sourced. Both modes share the same action functions,
threshold model, owner resolution logic, and output contract.

### Import mode (`-Accounts -Prefixes`)

```
Azure Automation (schedule: monthly, or triggered manually)
  │
  ├─ Input: CSV export from SIEM / IGA dashboard (pre-identified inactive privileged accounts)
  │         or $result.Unprocessed from a previous run
  │
  ├─ Prefix filter: rows whose SAM/UPN does not match any -Prefixes value are discarded
  │
  └─ foreach account:
       Get-ADUser / Get-MgUser      Live check: current enabled state + latest logon
       │  DisabledSinceExport?      Skip (already actioned by another process)
       │  ActivityDetected?         Skip (account logged on since export)
       Get-ADAccountOwner           Resolve owner: prefix-strip → EA14
       Get-MgUserSponsor            Fallback if AD strategies fail (requires EntraObjectId)
       │  NoOwnerFound?             Skip (flag for human investigation)
       Threshold evaluation         90d → Warn; 120d → Disable; 180d → Delete
       Send-GraphMail               Notify owner
       Disable-InactiveAccount      If action = Disable
       Remove-InactiveAccount       If action = Delete and -EnableDeletion set
```

**When to use:** Privileged account remediation where the input list is pre-curated by
your SIEM or IGA tool. Stateless: re-runnable with the same export if the job fails.

**State:** None. Resume safety comes from live re-query: accounts already disabled are
detected and skipped at the live check.

---

### Discovery mode (`-Prefixes -ADSearchBase`)

```
Azure Automation (schedule: weekly/monthly, or triggered ad-hoc)
  │
  ├─ Get-PrefixedADAccounts         Discover AD accounts by prefix and OU
  ├─ Get-PrefixedEntraAccounts      Discover Entra accounts by prefix
  │    └─ Merge AD + Entra          Synced accounts get Entra sign-in enrichment;
  │                                 cloud-native Entra accounts added separately
  │
  └─ foreach account:
       Threshold evaluation         Same as import mode (90/120/180 defaults)
       Get-ADAccountOwner           Owner resolution: SamAccountName → prefix-strip → EA14
       Get-MgUserSponsor            Fallback if AD strategies fail (requires EntraObjectId)
       Send-GraphMail               Notify owner
       Disable-InactiveAccount      If action = Disable
       Remove-InactiveAccount       If action = Delete and -EnableDeletion set
```

**When to use:** When you want the module to own discovery end-to-end with no external
export dependency. No dependency on an external SIEM or dashboard export.

**State:** None. Re-runnable. The `Unprocessed` field in the output is already shaped
as the import contract, so `$result.Unprocessed` feeds directly into import mode for
a targeted retry if a run fails mid-batch.

---

## Approach Comparison: Which Mode to Use

| | Import mode | Discovery mode |
|---|---|---|
| **Parameter set** | `-Accounts -Prefixes` | `-Prefixes -ADSearchBase` |
| **Account source** | Pre-exported list from SIEM / IGA | Live AD + Entra (auto-discovered by prefix) |
| **Prefix role** | Filter: discard rows not matching a prefix | Scope: query only accounts with matching prefix |
| **State** | None | None |
| **Threshold model** | Absolute inactivity duration (single pass) | Absolute inactivity duration (single pass) |
| **Action per run** | Highest-severity action that applies | Highest-severity action that applies |
| **Live check** | Yes — re-queries AD/Entra; skips if account became active or was disabled since export | Discovery is already live; no additional re-query |
| **Owner resolution** | Required (skips if unresolvable) | Required (skips if unresolvable) |
| **Scheduling** | Monthly (automated or manual) | Weekly / monthly / ad-hoc |

### When to choose each

**Import mode** — choose this when:

- You already have a SIEM or IGA tool that produces a curated list of inactive accounts
  (e.g. a monthly compliance report).
- You want to act on a pre-reviewed list rather than the module deciding scope.
- You want simplicity: no state to manage; re-running with the same export is safe.
- Drawback: depends on the quality of the upstream export. Stale exports produce stale
  input; the live check guards against this but cannot compensate for a very old export.

**Discovery mode** — choose this when:

- You want the module to own discovery end-to-end with no external export dependency.
- You prefer a fully automated, scheduled sweep that requires no manual input between
  runs.
- You are comfortable with the module deciding scope based on prefix + OU alone.
- Drawback: no grace period or staged progression. If an account logs in after being
  warned and then goes inactive again, it will be warned again on a future run — there
  is no memory of prior notifications.

### Combining modes

These are not mutually exclusive. A common operational pattern:

1. Run discovery mode monthly to handle the broad population automatically (Warning and Disable).
2. Before enabling deletion, review the `Results` output, extract the accounts at
   the delete threshold, and pass that reviewed list back in as import mode with
   `-EnableDeletion` — adding a human review gate before the irreversible step.
3. If a discovery run fails mid-batch, pass `$result.Unprocessed` into import mode
   for a targeted retry. No transformation needed — both modes share the same field names.

---

## Data Flow: Import Mode End-to-End

```
SIEM / IGA Dashboard
        │
        │  CSV export (inactive privileged accounts)
        ▼
Azure Blob Storage  ──────────────────────────────────────────────────┐
        │                                                              │
        │  (runbook downloads at job start)                           │
        ▼                                                              │
Hybrid Runbook Worker                                                  │
        │                                                              │
        ├─ Import-Module IdentityLifecycle                             │
        ├─ Connect-MgGraph (certificate)                                │
        │                                                              │
        ├─ Invoke-InactiveAccountRemediation -Accounts -Prefixes       │
        │     │                                                        │
        │     ├─ Prefix filter (discard non-matching rows)             │
        │     ├─ Get-ADUser (per account)          ◄── AD domain       │
        │     ├─ Get-MgUser (per account)          ◄── Graph API       │
        │     ├─ Get-ADUser (owner lookup)         ◄── AD domain       │
        │     ├─ Get-MgUserSponsor (owner fallback)◄── Graph API       │
        │     ├─ Send-GraphMail (per account)      ──► Graph API ──► Owner's mailbox
        │     ├─ Disable-ADAccount                ──► AD domain
        │     └─ Remove-MgUser                    ──► Graph API
        │
        ├─ $result.Summary, $result.Results
        │
        ├─ Write result JSON to Azure Blob Storage                     │
        │                                                              │
        └─ Send run summary to Log Analytics workspace ◄───────────────┘
```

---

## Canonical Field Names

All layers — discovery functions, working list, input contract, and `Unprocessed` output
— use the same field names. No translation is needed when crossing mode boundaries:

| Field | Source | Notes |
|---|---|---|
| `UserPrincipalName` | Primary key | Rows with no value are discarded (NoUPN) |
| `SamAccountName` | AD accounts | Empty string for Entra-native accounts |
| `Enabled` | AD/Entra enabled state | String `"True"`/`"False"` in CSV; bool in live objects |
| `LastLogonDate` | AD last logon | `$null` if never logged on |
| `entraLastSignInAEST` | Entra sign-in | `$null` if never signed in or no Entra account |
| `Created` | Account creation date | Last-resort inactivity baseline |
| `EntraObjectId` | Entra object ID | Required for Entra-native; optional for AD+Entra |
| `Description` | AD/Entra description | Passed to action functions |

---

## Owner Resolution

Before any notification or action is taken, the module must identify who owns the
account. Three strategies are tried in order; the first that yields a notification
recipient wins:

```
1. Prefix strip (primary — naming convention is the authoritative ownership contract)
   admin.jsmith → strip 'admin.' prefix → candidate SAM = 'jsmith'
   Verify 'jsmith' exists in AD → owner confirmed
   Owner email: Get-ADUser -Properties EmailAddress

2. Extension attribute  (fallback — for accounts that don't follow the naming convention)
   extensionAttribute14 is used as it tends to be spare in most environments; swap it
   in Get-ADAccountOwner for whichever attribute your org uses.
   e.g. extensionAttribute14 = 'dept=IT;owner=jsmith.mgr;location=HQ'
   Parse 'owner=jsmith.mgr' → verify 'jsmith.mgr' exists in AD → owner confirmed
   Owner email: Get-ADUser -Properties EmailAddress

3. Entra sponsor  (last resort — for cloud-native accounts and AD accounts with no AD owner)
   Requires EntraObjectId to be present on the account.
   Get-MgUserSponsor → first sponsor's Mail address (or UserPrincipalName if Mail is empty)
   Used directly as the notification recipient — no AD email lookup needed.
   This is the primary path for cloud-native Entra accounts that have no AD counterpart.

4. NoOwnerFound (skip — flagged for human investigation)
   Account appears in Results with SkipReason = 'NoOwnerFound'
   No notification sent; no action taken
   A human must assign an owner (fix the SAM naming, set the owner= extension attribute
   key, or assign an Entra sponsor) before the account will be processed on the next run
```

Owner's AD email address (strategies 1 and 2) is resolved via
`Get-ADUser -Properties EmailAddress`. If the lookup fails or `EmailAddress` is empty,
the account is skipped with `SkipReason = 'NoEmailFound'` — no notification or action
is attempted with a null recipient. Strategy 3 (Entra sponsor) bypasses this step since
the sponsor's address comes directly from Graph.

---

## Notification

Notifications are sent via Microsoft Graph (`Send-GraphMail`) from a shared mailbox
or service account UPN. Three templates exist, driven by `NotificationStage`:

| Stage | Trigger | Content |
|---|---|---|
| `Warning` | Account at or above WarnThreshold (90d) | Account is inactive; owner should log in or raise a request to keep it |
| `Disabled` | Account at or above DisableThreshold (120d); account has been disabled | Account has been disabled; owner must raise a request to restore it |
| `Deletion` | Account at or above DeleteThreshold (180d) | Account has been or will be deleted; data retrieval window is closing |

HTML templates are built by `New-InactiveAccountLifecycleMessage` and include the UPN,
last activity date, and inactivity day count.

**`Send-GraphMail` is not part of this module.** It is mocked in the test suite and must
be supplied (e.g. from a shared utilities module) before any sweep can send real
notifications. The orchestrator calls it with these parameters:

```powershell
Send-GraphMail `
    -Sender                'iam-automation@corp.local' `  # MailSender param value
    -ClientID              $MailClientId `
    -Tenant                $MailTenantId `
    -CertificateThumbprint $MailCertificateThumbprint `
    -ToRecipients          @('owner@corp.local') `
    -Subject               'Subject -- account@corp.local' `
    -Body                  '<html>...</html>' `
    -BodyType              'HTML' `
    -ErrorAction           Stop
```

`Send-GraphMail` is expected to manage its own Graph authentication internally using
the supplied mail SP credentials. The mail SP requires `Mail.Send` application permission.
This is separate from the `Connect-MgGraph` session used for directory reads.

---

## Output

`Invoke-InactiveAccountRemediation` returns a consistent `[pscustomobject]` regardless
of whether the run succeeded or failed:

```
{
  Success      : bool     -- $true only if all accounts were processed without a fatal error
  Error        : string   -- set on fatal exception (connect fail, module missing, etc.)
  Summary      : {
    Total    : int    -- accounts that produced a result entry
    Warned   : int
    Disabled : int
    Deleted  : int
    Skipped  : int    -- NoUPN + ActivityDetected + DisabledSinceExport + NoOwnerFound
    Errors   : int    -- accounts where at least one step failed
    NoOwner  : int    -- subset of Skipped with SkipReason = NoOwnerFound
  }
  Results      : [        -- one entry per processed account
    {
      UserPrincipalName     : string
      SamAccountName        : string
      InactiveDays          : int?
      ActionTaken           : string   -- None | Notify | Disable | Delete
      NotificationStage     : string   -- Warning | Disabled | Deletion | null
      NotificationSent      : bool
      NotificationRecipient : string
      Status                : string   -- Completed | Skipped | Error
      SkipReason            : string   -- NoUPN | ActivityDetected | DisabledSinceExport | NoOwnerFound | NoEmailFound | null
      Error                 : string
      Timestamp             : string   -- ISO 8601 UTC
    }
  ]
  Unprocessed  : [        -- accounts that can be retried on next run
    {
      UserPrincipalName   : string   -- same 8-field import contract shape
      SamAccountName      : string
      Enabled             : string
      LastLogonDate       : string
      Created             : string
      EntraObjectId       : string
      entraLastSignInAEST : string
      Description         : string
    }
  ]
}
```

**`Unprocessed` contains accounts from two sources:**

1. **Owner confirmed, downstream failed** — owner was resolved and a valid notification
   recipient confirmed, but then something mechanical failed (mail error or action error).
2. **Never reached** — a fatal exception aborted the loop mid-batch; these accounts
   have no result entry and are passed through from the working list.

Accounts skipped with `NoUPN`, `ActivityDetected`, `DisabledSinceExport`, or
`NoOwnerFound` are deliberate decisions and are **not** in `Unprocessed`. Early-exit
failures before owner resolution (no SAM + no EntraObjectId, AD lookup error) are also
excluded — these require human investigation rather than automated retry.

The shape of each `Unprocessed` entry exactly matches the import contract of
`Invoke-InactiveAccountRemediation -Accounts`, so `$result.Unprocessed` can be
passed directly as `-Accounts` with no transformation, regardless of which mode
produced the original run:

```powershell
$result2 = Invoke-InactiveAccountRemediation `
    -Accounts $result.Unprocessed -Prefixes @('admin.','priv.') -MailSender 'iam@corp.local' ...
```

Summary, Results, and Unprocessed are all built in a `finally` block so **partial
results are always returned** even when an exception aborts the run mid-batch.

---

## Known Gaps and Pending Work

| Item | Severity | Notes |
|---|---|---|
| `Send-GraphMail` not implemented | **Blocking** | No production notifications can be sent |
| `Remove-InactiveAccount` AD path is a stub | **Blocking for AD deletion** | Entra deletion works; AD throws. Replace stub with org offboarding process |
| Azure Automation runbook wrappers | Medium | Library functions need thin runbook wrappers that retrieve credentials and write results |
| `RequiredModules` in manifest | Low | `ActiveDirectory` and `Microsoft.Graph.*` not declared; worker fails at runtime rather than manifest validation |

---

## Security Considerations

- **Principle of least privilege:** The Graph application and AD service account should
  have only the permissions listed above — no Global Administrator, no broader write
  access than the target OU.
- **Certificate authentication only:** No client secrets. Certificates should be rotated
  on a schedule and stored in secure storage outside the runbook.
- **No credentials in code or runbooks:** All secrets should be retrieved from secure
  storage at runtime rather than hardcoded.
- **Audit trail:** Every account action is recorded in the `Results` array with a
  timestamp. The runbook should write this to Log Analytics or Blob Storage for
  retention and audit.
- **`-WhatIf` before first production run:** Always preview with `-WhatIf` after a
  threshold change or on a new account population to confirm the expected actions before
  committing.
- **Deletion is always opt-in:** `-EnableDeletion` must be explicitly set. The default
  action at the delete threshold is to disable with a Deletion notification, not to
  remove. Irreversible steps require deliberate configuration.
