# Identity Lifecycle — Solution Architecture

## Overview

A PowerShell module (`IdentityLifecycle`) that automates the lifecycle management of
inactive privileged accounts across an on-premises Active Directory and Entra ID
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
│  │  · Retrieves credentials from Key Vault                              │  │
│  │  · Imports IdentityLifecycle module                                  │  │
│  │  · Calls orchestrator function                                       │  │
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
│  │  · Outbound HTTPS to Azure Automation and Key Vault                  │  │
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
A registered Entra application with a **certificate credential** (no client secret) is
used for unattended authentication. The certificate private key is stored in Azure Key
Vault; the Automation account retrieves it at runtime via managed identity.

Required Graph application permissions:

| Permission | Type | Purpose |
|---|---|---|
| `User.Read.All` | Application | Read user objects and sign-in activity |
| `AuditLog.Read.All` | Application | Read `SignInActivity` (last sign-in timestamps) |
| `Mail.Send` | Application | Send notification emails via `Send-GraphMail` |
| `User.ReadWrite.All` | Application | Disable and delete Entra accounts |

### Credential storage

| Secret | Stored in | Retrieved by |
|---|---|---|
| Graph app certificate | Azure Key Vault | Automation runbook via managed identity |
| Sender mailbox UPN | Automation variable or Key Vault | Runbook at runtime |
| Tenant ID / Client ID | Automation variable (not secret) | Runbook at runtime |

---

## Module Structure

```
IdentityLifecycle/
├── IdentityLifecycle.psd1          Module manifest
├── IdentityLifecyle.psm1           Module loader (dot-sources all public functions)
└── functions/
    └── public/
        ├── InactiveAccounts/
        │   ├── Invoke-InactiveAccountSweep.ps1         Daily stateful orchestrator
        │   ├── Invoke-MonthlyInactiveAccountSweep.ps1  Monthly stateless orchestrator (export-driven)
        │   ├── Invoke-DirectInactiveAccountSweep.ps1   On-demand stateless orchestrator (auto-discovery)
        │   ├── Get-InactiveAccountStage.ps1            Pure threshold evaluation (daily sweep)
        │   ├── Disable-InactiveAccount.ps1             Disable in AD or Entra
        │   ├── Remove-InactiveAccount.ps1              Delete from Entra (AD stub pending)
        │   ├── New-InactiveAccountLifecycleMessage.ps1 HTML email builder
        │   └── Send-GraphMail.ps1                      Graph sendMail wrapper (pending)
        ├── Identity/
        │   ├── Get-PrefixedAccounts.ps1                Merge AD + Entra + state (daily sweep)
        │   ├── Get-PrefixedADAccounts.ps1              AD discovery by prefix
        │   ├── Get-PrefixedEntraAccounts.ps1           Entra discovery by prefix
        │   ├── Get-ADAccountOwner.ps1                  Owner resolution (prefix-strip + EA14)
        │   ├── Resolve-EntraSignIn.ps1                 Extract most recent sign-in from Graph user
        │   └── Resolve-StandardAccount.ps1             Legacy owner resolution (daily sweep)
        └── Storage/
            ├── Get-InactiveAccountStateTable.ps1       Bulk read from Azure Table Storage
            ├── Get-InactiveAccountStateRow.ps1         Deserialise a single state row
            ├── Set-InactiveAccountStateRow.ps1         Upsert state row
            └── Remove-InactiveAccountStateRow.ps1      Delete state row
```

---

## Three Orchestration Patterns

The module supports three distinct execution patterns. They share the same action
functions (`Disable-InactiveAccount`, `Remove-InactiveAccount`, `Send-GraphMail`) but
differ in how they discover accounts and manage state.

### 1. Daily stateful sweep (`Invoke-InactiveAccountSweep`)

```
Azure Automation (schedule: daily)
  │
  ├─ Get-PrefixedAccounts           Discover all prefixed accounts from AD + Entra
  │    └─ Get-InactiveAccountStateTable   Read current stage from Azure Table Storage
  │
  └─ foreach account:
       Get-InactiveAccountStage     Evaluate stage (None → Warning → Disabled → Deletion → Grace)
       Send-GraphMail               Notify owner at each stage transition
       Disable-InactiveAccount      At Disabled stage
       Remove-InactiveAccount       At Deletion stage
       Set-InactiveAccountStateRow  Write new stage back to Table Storage
```

**When to use:** Large fleets where accounts may temporarily return to activity (grace
period), or where a staged warning → disable → delete progression with human review
windows between stages is required.

**State:** Azure Table Storage. One row per account, keyed by UPN. Stores current stage,
stage date, enabled state at time of action, and grace-pending flag.

---

### 2. Monthly stateless sweep (`Invoke-MonthlyInactiveAccountSweep`)

```
Azure Automation (schedule: monthly, or triggered manually)
  │
  ├─ Input: CSV export from SIEM / IGA dashboard (pre-identified inactive privileged accounts)
  │
  └─ foreach account:
       Get-ADUser / Get-MgUser      Live check: current enabled state + latest logon
       │  DisabledSinceExport?      Skip (already actioned by another process)
       │  ActivityDetected?         Skip (account logged on since export)
       Get-ADAccountOwner           Resolve owner: prefix-strip → EA14
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

### 3. Direct stateless sweep (`Invoke-DirectInactiveAccountSweep`)

```
Azure Automation (schedule: weekly/monthly, or triggered ad-hoc)
  │
  ├─ Get-PrefixedADAccounts         Discover AD accounts by prefix and OU
  ├─ Get-PrefixedEntraAccounts      Discover Entra accounts by prefix
  │    └─ Merge AD + Entra          Synced accounts get Entra sign-in enrichment;
  │                                 cloud-native Entra accounts added separately
  │
  └─ foreach account:
       Threshold evaluation         Same as monthly (90/120/180 defaults)
       Get-ADAccountOwner           Owner resolution: UPN local-part → prefix-strip → EA14
       Send-GraphMail               Notify owner
       Disable-InactiveAccount      If action = Disable
       Remove-InactiveAccount       If action = Delete and -EnableDeletion set
```

**When to use:** When you want the module to do its own discovery from the live directory
without a pre-exported list. No dependency on an external SIEM or dashboard export.

**State:** None. Re-runnable.

---

## Approach Comparison: Which Function to Use

The module provides four execution styles. This section summarises the trade-offs to
guide the choice for a given operational context.

| | Daily stateful sweep | Monthly stateless sweep | Direct stateless sweep | Ad-hoc action functions |
|---|---|---|---|---|
| **Function** | `Invoke-InactiveAccountSweep` | `Invoke-MonthlyInactiveAccountSweep` | `Invoke-DirectInactiveAccountSweep` | `Send-InactivityWarning` / `Disable-InactiveAccounts` / `Remove-InactiveAccounts` |
| **Account source** | Live AD + Entra (auto-discovered) | Pre-exported CSV from SIEM / IGA | Live AD + Entra (auto-discovered) | Pre-supplied CSV (operator-chosen) |
| **State** | Azure Table Storage (persists between runs) | None | None | None |
| **Threshold model** | Staged over time (Warning → Disabled → Deletion across separate runs) | Absolute inactivity duration (single pass) | Absolute inactivity duration (single pass) | Absolute inactivity duration (single pass) |
| **Action per run** | One stage transition per account | Highest-severity action that applies | Highest-severity action that applies | Exactly the one action the function name says |
| **Live check** | Discovery is live; state tracks prior enabled state for drift detection | Yes — re-queries AD/Entra; skips if account became active or was disabled since export | Discovery is already live; no re-query | Yes — re-queries AD/Entra; skips if account became active since CSV was cut |
| **Owner resolution** | Required (skips if unresolvable) | Required (skips if unresolvable) | Required (skips if unresolvable) | Required (skips if unresolvable) |
| **Scheduling** | Daily (automated) | Monthly (automated or manual) | Weekly / monthly / ad-hoc | Ad-hoc only (operator invoked) |

### When to choose each

**Daily stateful sweep** — choose this when:
- You need a grace period (accounts that briefly return to activity should not be
  re-warned immediately; the Grace stage absorbs external manual intervention).
- You want staged human review windows between Warning, Disable, and Deletion with
  configurable day gaps.
- You have a large persistent population and want the module to track lifecycle state
  without any external tooling input.
- Drawback: requires Azure Table Storage; state can become inconsistent with the live
  directory if accounts are changed outside the sweep.

**Monthly stateless sweep** — choose this when:
- You already have a SIEM or IGA tool that produces a curated list of inactive accounts
  (e.g. a monthly compliance report).
- You want to act on a pre-reviewed list rather than the module deciding scope.
- You want simplicity: no state to manage; re-running with the same export is safe.
- Drawback: depends on the quality of the upstream export. Stale exports produce stale
  input; the live check guards against this but cannot compensate for a very old export.

**Direct stateless sweep** — choose this when:
- You want the module to own discovery end-to-end with no external export dependency.
- You prefer a fully automated, scheduled sweep that requires no manual input between
  runs.
- You are comfortable with the module deciding scope based on prefix + OU alone.
- Drawback: no grace period or staged progression. If an account logs in after being
  warned and then goes inactive again, it will be warned again on a future run — there
  is no memory of prior notifications.

**Ad-hoc action functions** — choose these when:
- An operator has reviewed a specific list and wants to take a single targeted action
  (e.g. "disable just these 12 accounts right now").
- You need to separate the decision of which accounts to act on from the execution —
  the module executes the action; a human or upstream tool decides the scope.
- You want to fire a single action type independently (warn without disabling, or
  disable without going through the full sweep).
- Drawback: the operator must supply a valid, current list. Wrong input means wrong
  actions; the live timestamp check is the only automated safety net.

### Combining approaches

These are not mutually exclusive. A common operational pattern:

1. Run `Invoke-DirectInactiveAccountSweep` monthly to handle the broad population
   automatically (Warning and Disable).
2. Before enabling deletion, review the `Results` output, extract the accounts at
   the delete threshold, and pass that reviewed list to `Remove-InactiveAccounts`
   as a deliberate ad-hoc action — adding a human review gate before the irreversible step.

---

## Data Flow: Monthly Sweep End-to-End

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
        ├─ Connect-MgGraph (certificate from Key Vault)                │
        │                                                              │
        ├─ Invoke-MonthlyInactiveAccountSweep                          │
        │     │                                                        │
        │     ├─ Get-ADUser (per account)          ◄── AD domain       │
        │     ├─ Get-MgUser (per account)          ◄── Graph API       │
        │     ├─ Get-ADUser (owner lookup)         ◄── AD domain       │
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

## Owner Resolution

Before any notification or action is taken, the module must identify who owns the
privileged account. Two strategies are tried in order:

```
1. Prefix strip (primary — naming convention is the authoritative ownership contract)
   adm.jsmith → strip 'adm.' → candidate SAM = 'jsmith'
   Verify 'jsmith' exists in AD → owner confirmed

2. extensionAttribute14  (fallback — for accounts that don't follow the naming convention)
   extensionAttribute14 = 'dept=IT;owner=jsmith.mgr;location=HQ'
   Parse 'owner=jsmith.mgr' → verify 'jsmith.mgr' exists in AD → owner confirmed

3. NoOwnerFound (skip — flagged for human investigation)
   Account appears in Results with SkipReason = 'NoOwnerFound'
   No notification sent; no action taken
   A human must assign an owner (fix the SAM naming or set extensionAttribute14)
   before the account will be processed on the next run
```

Owner's email address is resolved via `Get-ADUser -Properties EmailAddress` and used
as the notification recipient. If the email lookup fails, notification is attempted
to `$null` (which `Send-GraphMail` should handle gracefully or raise as an error).

**Gap — cloud-only Entra accounts:** For Entra-native accounts whose UPN prefix does not
resolve to an AD standard account, the Graph `manager` attribute is a natural fallback
that has not yet been implemented. These accounts currently always reach `NoOwnerFound`.

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

**`Send-GraphMail` is not yet implemented.** It is mocked in the test suite and must
be implemented before any sweep can send real notifications. Expected signature:

```powershell
function Send-GraphMail {
    param(
        [string]   $Sender,        # UPN of the sending mailbox
        [string[]] $ToRecipients,  # Recipient email addresses
        [string]   $Subject,
        [string]   $Body,          # HTML string
        [string]   $BodyType = 'HTML'
    )
}
```

Uses `Send-MgUserMail`. The connected app identity requires `Mail.Send` application
permission scoped to the sender mailbox (or tenant-wide if not restricted).

---

## State Storage (Daily Sweep Only)

`Invoke-InactiveAccountSweep` maintains one Azure Table Storage row per account,
keyed by UPN. The stateless orchestrators (`Invoke-MonthlyInactiveAccountSweep` and
`Invoke-DirectInactiveAccountSweep`) do not read or write state.

| Property | Type | Description |
|---|---|---|
| `Stage` | string | `None`, `Warning`, `Disabled`, `Deletion`, `Grace` |
| `StageDate` | DateTime | When the account entered the current stage |
| `AccountEnabled` | bool | Account enabled state at the time it was last actioned |
| `GracePending` | bool | Whether the account is in a grace reversal period |

---

## Output

All three orchestrators return a consistent `[pscustomobject]` regardless of whether
the run succeeded or failed:

```
{
  Success  : bool     -- $true only if all accounts were processed without a fatal error
  Error    : string   -- set on fatal exception (connect fail, module missing, etc.)
  Summary  : {
    Total    : int    -- accounts that produced a result entry
    Warned   : int
    Disabled : int
    Deleted  : int
    Skipped  : int    -- ActivityDetected + DisabledSinceExport + NoOwnerFound
    Errors   : int    -- accounts where at least one step failed
    NoOwner  : int    -- subset of Skipped with SkipReason = NoOwnerFound
  }
  Results  : [        -- one entry per processed account
    {
      UPN                   : string
      SamAccountName        : string
      InactiveDays          : int?
      ActionTaken           : string   -- None | Notify | Disable | Delete
      NotificationStage     : string   -- Warning | Disabled | Deletion | null
      NotificationSent      : bool
      NotificationRecipient : string
      Status                : string   -- Completed | Skipped | Error
      SkipReason            : string   -- ActivityDetected | DisabledSinceExport | NoOwnerFound | null
      Error                 : string
      Timestamp             : string   -- ISO 8601 UTC
    }
  ]
}
```

Summary and Results are built in a `finally` block so **partial results are always
returned** even when an exception aborts the run mid-batch.

---

## Known Gaps and Pending Work

| Item | Severity | Notes |
|---|---|---|
| `Send-GraphMail` not implemented | **Blocking** | No production notifications can be sent |
| `Remove-InactiveAccount` AD path is a stub | **Blocking for AD deletion** | Entra deletion works; AD throws. Replace stub with org offboarding process |
| Entra-native owner resolution via Graph manager | Medium | Cloud-only accounts without AD standard account always reach `NoOwnerFound` |
| Azure Automation runbook wrappers | Medium | Library functions need thin runbook wrappers that retrieve credentials and write results |
| Module manifest typo (`IdentityLifecyle.psm1`) | Low | Cosmetic; module loads correctly despite typo |
| `RequiredModules` in manifest | Low | `ActiveDirectory` and `Microsoft.Graph.*` not declared; worker fails at runtime rather than manifest validation |

---

## Security Considerations

- **Principle of least privilege:** The Graph application and AD service account should
  have only the permissions listed above — no Global Administrator, no broader write
  access than the target OU.
- **Certificate authentication only:** No client secrets. Certificates are rotated on a
  schedule and stored in Key Vault; the Automation managed identity retrieves them.
- **No credentials in code or runbooks:** All secrets come from Key Vault at runtime.
- **Audit trail:** Every account action is recorded in the `Results` array with a
  timestamp. The runbook should write this to Log Analytics or Blob Storage for
  retention and audit.
- **`-WhatIf` before first production run:** Always preview with `-WhatIf` after a
  threshold change or on a new account population to confirm the expected actions before
  committing.
- **Deletion is always opt-in:** `-EnableDeletion` must be explicitly set. The default
  action at the delete threshold is to disable with a Deletion notification, not to
  remove. Irreversible steps require deliberate configuration.
