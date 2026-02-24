# Test Suite: Invoke-AccountInactivityRemediation

Tests for `Invoke-AccountInactivityRemediation` — the stateless discovery sweep that
finds inactive privileged accounts directly from AD and Entra ID by prefix, evaluates
each against absolute inactivity thresholds, and takes the required action in a single pass.

**205 assertions across 37 scenarios.**

## Running the tests

From the repo root:

```powershell
. .\IdentityLifecycle\tests\Invoke-AccountInactivityRemediation\Invoke-Test.ps1
```

An HTML report is written to `tests/Invoke-AccountInactivityRemediation/reports/`
and opened automatically (unless `$env:CI = 'true'`).

---

## Architecture

### How it works

The module is loaded with `Import-Module -Global`. All external dependencies are replaced
by mock functions injected into the module's `script:` scope via
`& (Get-Module IdentityLifecycle) { function script:Fn { ... } }`. Global-scope overrides
do not reach inside a module loaded this way — this is a fundamental PowerShell scoping
constraint that drove the design of the custom harness.

A single `$MockContext` hashtable is shared by reference across all mocks. Each scenario
resets it before running via `Set-ScenarioContext`. Because the hashtable is shared by
reference, mutations made inside `AssertAfterRun` scriptblocks (e.g. clearing
`DisableFail` for a re-run scenario) are immediately visible to the mocks.

`Get-PrefixedADAccounts` and `Get-PrefixedEntraAccounts` are mocked to return lists
controlled by the scenario, eliminating any dependency on the live directory for
discovery. Every test calls `Invoke-AccountInactivityRemediation` with
`SkipModuleImport = $true` and `UseExistingGraphSession = $true` by default.

### What is mocked

| Function | Mock behaviour |
|---|---|
| `Get-PrefixedADAccounts` | Returns `$MockContext.ADAccountList`; throws if `$MockContext.ADAccountListFail = $true` |
| `Get-PrefixedEntraAccounts` | Returns `$MockContext.EntraAccountList` (empty by default) |
| `Get-ADUser` | Returns object from `$MockContext.ADUsers` keyed by SAM (lower-case); throws "not found" if absent |
| `Send-GraphMail` | Records action in `$MockContext.Actions`; throws if UPN is in `$MockContext.NotifyFail` |
| `Disable-InactiveAccount` | Records action; returns `{ Success=$false }` if UPN is in `$MockContext.DisableFail` |
| `Remove-InactiveAccount` | Records action; returns `{ Success=$false }` if UPN is in `$MockContext.RemoveFail` |
| `Connect-MgGraph` | No-op; throws if `$MockContext.ConnectFail = $true` |
| `Disconnect-MgGraph` | No-op |

### What runs for real

- `Get-ADAccountOwner` — owner resolution via prefix-strip and extensionAttribute14 (uses the mocked `Get-ADUser`)
- `New-InactiveAccountLifecycleMessage` — builds notification subject and body

### MockContext keys

| Key | Type | Purpose |
|---|---|---|
| `ADAccountList` | `pscustomobject[]` | Returned by `Get-PrefixedADAccounts`; built with `New-RemediationADAccount` |
| `EntraAccountList` | `pscustomobject[]` | Returned by `Get-PrefixedEntraAccounts`; built with `New-RemediationEntraAccount` |
| `ADUsers` | `hashtable` | SAM (lower) → fake ADUser object; used for owner resolution and email lookup |
| `Actions` | `List[pscustomobject]` | Captured actions: `{ Action, UPN, Stage, Recipient }` |
| `NotifyFail` | `string[]` | UPNs for which `Send-GraphMail` throws |
| `DisableFail` | `string[]` | UPNs for which `Disable-InactiveAccount` returns failure |
| `RemoveFail` | `string[]` | UPNs for which `Remove-InactiveAccount` returns failure |
| `ConnectFail` | `bool` | Makes `Connect-MgGraph` throw |
| `ADAccountListFail` | `bool` | Makes `Get-PrefixedADAccounts` throw (tests fatal discovery failure) |

### Helpers

| File | Functions | Purpose |
|---|---|---|
| `helpers/New-TestAccount.ps1` | `New-RemediationADAccount` | Builds `Get-PrefixedADAccounts`-shaped objects for `$MockContext.ADAccountList` |
| | `New-RemediationEntraAccount` | Builds `Get-PrefixedEntraAccounts`-shaped objects for `$MockContext.EntraAccountList` |
| | `New-RemediationOwnerADUser` | Builds fake ADUser objects for `$MockContext.ADUsers` (owner resolution and email) |
| `helpers/Assert-Result.ps1` | `Assert-Equal`, `Assert-True`, `Assert-False`, `Assert-Null`, `Assert-NotNull`, `Assert-Empty`, `Assert-Count`, `Assert-ActionFired`, `Assert-ActionNotFired`, `Assert-ResultField`, `Assert-SummaryField` | All assertion functions used in scenario scriptblocks |
| `helpers/Set-Mocks.ps1` | `Set-Mocks` | Installs all mock functions into the module scope; called once at harness startup |

---

## Scenario files

### 01-Discovery — Account discovery and early skips

These tests confirm the discovery phase: that AD and Entra accounts are collected and
merged correctly, and that already-handled accounts (disabled, below threshold) are
dealt with before the main processing loop.

| # | What is tested |
|---|---|
| 01-01 | AD account 30 days inactive — below `WarnThreshold`, skipped with `ActivityDetected` |
| 01-02 | AD account already disabled at `DisableThreshold` — Disable step skipped; still Completed |
| 01-03 | `Get-PrefixedADAccounts` throws — fatal error; `Success=$false`, `Results` empty, `Summary` present with zeros |
| 01-04 | No accounts discovered (empty working set) — `Success=$true`, `Total=0` |
| 01-05 | AD account already disabled at `DeleteThreshold`, `EnableDeletion` on — Disable skipped, Remove fired, Deleted |
| 01-06 | Mixed AD + cloud-native Entra batch — AD account warned (owner resolved); Entra-native skipped (`NoOwnerFound`, no SAM) |

### 02-Thresholds — Inactivity threshold evaluation and action selection

Tests the absolute threshold model. No prior warning run is required for an account to
be disabled. Already-disabled accounts skip the disable call and still return Completed.

| # | What is tested |
|---|---|
| 02-01 | 90 days (exactly at `WarnThreshold`) — Notify, Warning stage |
| 02-02 | 89 days (below `WarnThreshold`) — skipped with `ActivityDetected` |
| 02-03 | 120 days (at `DisableThreshold`) — Disable, Disabled stage |
| 02-04 | 150 days (between thresholds) — Disable, Disabled stage |
| 02-05 | 180 days, `EnableDeletion` off — Disable with Deletion notification; Remove not called |
| 02-06 | 180 days, `EnableDeletion` on — Remove with Deletion notification; Disable not called |
| 02-07 | No `LastLogonAD` — `WhenCreated` used as `InactiveDays` baseline (account created 95 days ago → Warn) |
| 02-08 | No activity data at all (null logon, null created) — error recorded |
| 02-09 | Custom thresholds (`WarnThreshold=30`) — account at 35 days triggers Warning |

### 03-OwnerResolution — Notification recipient selection

| # | What is tested |
|---|---|
| 03-01 | Owner resolved via prefix-strip (primary strategy) — notification goes to owner email |
| 03-02 | No recognised prefix — prefix-strip skipped; owner resolved via `extensionAttribute14` fallback |
| 03-03 | EA14 `owner=<sam>` present but SAM not in AD — EA14 strategy fails; prefix-strip fallback succeeds |
| 03-04 | No owner resolvable (stripped SAM not in mock, no EA14) — skipped with `NoOwnerFound` |
| 03-05 | Both prefix-strip and EA14 would resolve — prefix-strip wins (checked first) |

### 04-Failures — Error handling and fatal failure paths

`Send-GraphMail` failure is fatal (loop aborts). `Disable-InactiveAccount` and
`Remove-InactiveAccount` failures are per-entry errors (loop continues). Discovery
failure (`Get-PrefixedADAccounts` throws) shuts the run down before any accounts
are processed.

| # | What is tested |
|---|---|
| 04-01 | `Send-GraphMail` throws — `Success=$false`, `Error` set, `Disable` not fired (loop aborts) |
| 04-02 | `Send-GraphMail` throws mid-batch — loop aborts; first account's `Disable` already fired |
| 04-03 | `Disable-InactiveAccount` returns failure — error recorded in Results; loop continues to next account |
| 04-04 | `Remove-InactiveAccount` returns failure — error recorded in Results; loop continues |
| 04-05 | Mixed batch: one disable succeeds, one fails — both counted correctly in Summary |
| 04-06 | `Connect-MgGraph` throws — `Success=$false`, `Error` set, `Results` empty, `Summary` present with zeros |

### 05-Output — Output object structure, summary tallying, and Unprocessed

These tests cover the complete output contract, including the `Unprocessed` field and
the cross-function re-run pattern — where `Unprocessed` from a discovery run is fed
directly into the import-driven function for targeted retry.

| # | What is tested |
|---|---|
| 05-01 | Return object has `Summary`, `Results`, `Success`, `Error`, `Unprocessed` properties |
| 05-02 | Disable failure → error entry in `Results` with `Status=Error`; `Summary.Errors` incremented |
| 05-03 | Mixed batch of warn/disable/skip — all `Summary` fields tallied correctly |
| 05-04 | Large mixed batch (7 accounts) — all outcome types: Warned, Disabled, Deleted×2 (including already-disabled), Error, Skipped/ActivityDetected, Skipped/NoOwnerFound |
| 05-05 | `-WhatIf` — Results fully populated with expected ActionTaken values; no actions fired against mocks |
| 05-06 | `Unprocessed` is empty when all accounts Completed |
| 05-07 | `Unprocessed` contains the error account in import-contract shape (all 8 fields, correct UPN/SAM) |
| 05-08 | **Cross-function re-run**: discovery run 1 produces one error → `Unprocessed` has 1 entry; run 2 passes `result1.Unprocessed` directly to `Invoke-AccountInactivityRemediationWithImport` → 1 Completed, 0 Unprocessed |

**Why 05-08 matters:** The discovery sweep and the import-driven sweep produce and consume
the same 8-field `Unprocessed` shape. This test is the end-to-end proof that:
- A discovery run's `Unprocessed` is directly consumable by the import-driven function
  with no transformation
- The previously-failed account completes when the blocking condition is cleared
- Nothing from the successful accounts in run 1 is reprocessed in run 2

This validates the cross-function retry contract — the `Unprocessed` field as the
shared language between both sweep modes.

### 06-EntraAndEdge — Entra-native accounts, synced accounts, and edge cases

| # | What is tested |
|---|---|
| 06-01 | Cloud-native Entra account with recent sign-in — skipped with `ActivityDetected` |
| 06-02 | Cloud-native Entra account 95 days inactive — skipped with `NoOwnerFound` (no SAM, no owner resolution path) |
| 06-03 | AD account with synced Entra counterpart — Entra sign-in (85 days) more recent than AD logon (120 days); skipped |
| 06-04 | AD account with synced Entra counterpart — AD logon (85 days) more recent than Entra sign-in (120 days); skipped |
| 06-05 | Mixed batch: AD with owner, AD without owner, cloud-native Entra — counts correct across all three |
