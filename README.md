# IdentityLifecycle

A PowerShell module for managing the lifecycle of inactive prefixed privileged accounts across Active Directory and Entra ID.

## What it does

This module targets accounts identified by a SAMAccountName / UPN prefix — for example `admin`, `priv` — and evaluates each matching account against absolute inactivity thresholds, sending notifications at each stage and ultimately disabling or deleting dormant accounts. The prefix set is fully configurable, making this suitable for any account population that needs a distinct inactivity policy.

```
InactiveDays >= WarnThreshold    →  Warning notification (email to owner)
InactiveDays >= DisableThreshold →  Disabled notification + account disabled
InactiveDays >= DeleteThreshold  →  Deletion notification + account removed (requires -EnableDeletion)
InactiveDays < WarnThreshold     →  Skipped (ActivityDetected)
```

All thresholds are configurable. An account inactive for 150 days is disabled in a single run even if it was never warned first — the sweep applies the highest-severity action warranted by the current inactivity duration.

Deletion is an explicit opt-in. Accounts that reach the delete threshold are held in their current disabled state until `-EnableDeletion` is passed. This is an intentional safety gate.

## Two sweep modes

### Monthly sweep — stateless, CSV-driven

`Invoke-MonthlyInactiveAccountSweep` takes a pre-identified list of accounts (from a SIEM/IGA export) and evaluates each one in a single pass. No persistent state is maintained. If the job fails halfway, re-run it with the same export — accounts already actioned are detected via their live enabled state and skipped.

See [MONTHLY-SWEEP.md](IdentityLifecycle/MONTHLY-SWEEP.md) for full documentation.

### Direct sweep — stateless, live discovery

`Invoke-DirectInactiveAccountSweep` discovers accounts in real time by querying AD and Entra ID directly using the configured prefixes. No input CSV is required. It applies the same absolute threshold model as the monthly sweep.

## Structure

```
functions/public/
  InactiveAccounts/    # Orchestrators and action functions
  Identity/            # Account collection from AD and Entra ID; owner resolution
tests-monthly/
  Invoke-MonthlyTest.ps1  # Monthly sweep test harness; see tests-monthly/README.md
tests-direct/
  Invoke-DirectTest.ps1   # Direct sweep test harness; see tests-direct/README.md
```

## Prerequisites

- PowerShell 5.1+
- `ActiveDirectory` module (RSAT)
- `Microsoft.Graph` module (`Connect-MgGraph` pre-authenticated, or pass `-ClientId/-TenantId/-CertificateThumbprint`)

## Quick start

### Monthly sweep

```powershell
Import-Module .\IdentityLifecycle

$accounts = Import-Csv 'C:\Reports\InactivePrivAccounts.csv'

$result = Invoke-MonthlyInactiveAccountSweep `
    -Accounts              $accounts `
    -Sender                'iam-automation@corp.local' `
    -ClientId              $appId `
    -TenantId              $tenantId `
    -CertificateThumbprint $thumb `
    -EnableDeletion

$result.Summary
$result.Results | Where-Object { $_.Status -eq 'Error' } | Select-Object UPN, Error
```

### Direct sweep

```powershell
Import-Module .\IdentityLifecycle

$result = Invoke-DirectInactiveAccountSweep `
    -Prefixes              @('admin', 'priv') `
    -ADSearchBase          'OU=PrivilegedAccounts,DC=corp,DC=local' `
    -Sender                'iam-automation@corp.local' `
    -ClientId              $appId `
    -TenantId              $tenantId `
    -CertificateThumbprint $thumb `
    -EnableDeletion

$result.Summary
$result.Results | Where-Object { $_.Status -eq 'Error' } | Select-Object UPN, Error
```

### Dry run / WhatIf

Both sweep functions support `-WhatIf`. Passing it suppresses all side effects (no emails sent, no accounts disabled or deleted) while still running the full live check and threshold evaluation and returning a complete result object:

```powershell
$result = Invoke-MonthlyInactiveAccountSweep -Accounts $accounts -Sender 'iam@corp.local' `
    -UseExistingGraphSession -WhatIf

$result.Results | Format-Table UPN, InactiveDays, ActionTaken, NotificationStage, SkipReason
```

## Running tests

```powershell
# Monthly sweep
. .\IdentityLifecycle\tests-monthly\Invoke-MonthlyTest.ps1

# Direct sweep
. .\IdentityLifecycle\tests-direct\Invoke-DirectTest.ps1
```
