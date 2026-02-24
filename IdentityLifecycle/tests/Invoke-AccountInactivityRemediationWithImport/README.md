# Test Suite: Invoke-AccountInactivityRemediationWithImport

Tests for `Invoke-AccountInactivityRemediationWithImport` — the stateless import-driven
orchestrator that evaluates pre-identified inactive privileged accounts against absolute
inactivity thresholds and takes the required action in a single pass.

**204 assertions across 37 scenarios.**

## Running the tests

From the repo root:

```powershell
. .\IdentityLifecycle\tests\Invoke-AccountInactivityRemediationWithImport\Invoke-Test.ps1
```

An HTML report is written to `tests/Invoke-AccountInactivityRemediationWithImport/reports/`
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

Every test calls `Invoke-AccountInactivityRemediationWithImport` with
`SkipModuleImport = $true` (prevents real `Import-Module` calls overwriting the mocks)
and `UseExistingGraphSession = $true` by default (skips Graph auth). Scenarios that
test the connect path set `UseExistingGraphSession = $false` and `ConnectFail = $true`.

### What is mocked

| Function | Mock behaviour |
|---|---|
| `Get-ADUser` | Returns object from `$MockContext.ADUsers` keyed by SAM (lower-case); throws "not found" if absent |
| `Get-MgUser` | Returns object from `$MockContext.MgUsers` keyed by EntraObjectId (lower-case); throws if absent |
| `Send-GraphMail` | Records action in `$MockContext.Actions`; throws if UPN is in `$MockContext.NotifyFail` |
| `Disable-InactiveAccount` | Records action; returns `{ Success=$false }` if UPN is in `$MockContext.DisableFail` |
| `Remove-InactiveAccount` | Records action; returns `{ Success=$false }` if UPN is in `$MockContext.RemoveFail` |
| `Connect-MgGraph` | No-op; throws if `$MockContext.ConnectFail = $true` |
| `Disconnect-MgGraph` | No-op |

### What runs for real

- `Resolve-EntraSignIn` — sign-in timestamp resolution
- `ConvertTo-Bool` — inline helper, exercised throughout
- `Get-ADAccountOwner` — owner resolution via extensionAttribute14 and prefix-strip (uses the mocked `Get-ADUser`)
- `New-InactiveAccountLifecycleMessage` — builds notification subject/body

### MockContext keys

| Key | Type | Purpose |
|---|---|---|
| `ADUsers` | `hashtable` | SAM (lower) → fake ADUser object; used for live check, owner lookup, and owner email |
| `MgUsers` | `hashtable` | EntraObjectId (lower) → fake MgUser object |
| `Actions` | `List[pscustomobject]` | Captured actions: `{ Action, UPN, Stage, Recipient }` |
| `NotifyFail` | `string[]` | UPNs for which `Send-GraphMail` throws |
| `DisableFail` | `string[]` | UPNs for which `Disable-InactiveAccount` returns failure |
| `RemoveFail` | `string[]` | UPNs for which `Remove-InactiveAccount` returns failure |
| `ConnectFail` | `bool` | Makes `Connect-MgGraph` throw |

### Helpers

| File | Functions | Purpose |
|---|---|---|
| `helpers/New-TestAccount.ps1` | `New-ImportTestAccount` | Builds CSV-shaped input rows (`-Accounts` parameter) |
| | `New-ImportADUser` | Builds fake ADUser objects for `$MockContext.ADUsers` (live check + owner) |
| | `New-ImportMgUser` | Builds fake MgUser objects for `$MockContext.MgUsers` |
| `helpers/Assert-Result.ps1` | `Assert-Equal`, `Assert-True`, `Assert-False`, `Assert-Null`, `Assert-NotNull`, `Assert-Empty`, `Assert-Count`, `Assert-ActionFired`, `Assert-ActionNotFired`, `Assert-ResultField`, `Assert-SummaryField` | All assertion functions used in scenario scriptblocks |
| `helpers/Set-Mocks.ps1` | `Set-Mocks` | Installs all mock functions into the module scope; called once at harness startup |

---

## Scenario files

### 01-LiveCheck — Live directory re-query and early skips

The function re-queries the live directory for every account before acting on it.
These tests confirm the skip conditions and error paths for the live check phase.

| # | What is tested |
|---|---|
| 01-01 | AD account 30 days inactive — below `WarnThreshold`, skipped with `ActivityDetected` |
| 01-02 | Account disabled in AD since export — skipped with `DisabledSinceExport` |
| 01-03 | AD lookup fails (account not in mock) — error recorded in Results |
| 01-04 | Input row with no UPN — silently skipped, no result entry |
| 01-05 | Entra-native disabled since export — skipped with `DisabledSinceExport` |
| 01-06 | Entra-native with no `EntraObjectId` — error recorded |

### 02-Thresholds — Inactivity threshold evaluation and action selection

Tests the absolute threshold model. An account at 150 days should be disabled without
having been warned first. Already-disabled accounts in AD skip the disable call and
still return `Completed`.

| # | What is tested |
|---|---|
| 02-01 | 90 days (exactly at `WarnThreshold`) — Notify, Warning stage |
| 02-02 | 89 days (below `WarnThreshold`) — skipped with `ActivityDetected` |
| 02-03 | 120 days (at `DisableThreshold`) — Disable, Disabled stage |
| 02-04 | 150 days (between thresholds) — Disable, Disabled stage |
| 02-05 | 180 days, `EnableDeletion` off — Disable with Deletion notification |
| 02-06 | 180 days, `EnableDeletion` on — Remove with Deletion notification |
| 02-07 | Already disabled in AD at threshold — success without calling `Disable-InactiveAccount` |
| 02-08 | No `LastLogonDate` — `WhenCreated` used as `InactiveDays` baseline |
| 02-09 | No activity data at all — error recorded |

### 03-OwnerResolution — Notification recipient selection

Owner resolution determines who receives the notification. These tests exercise the
two resolution strategies (prefix-strip and extensionAttribute14) and their interaction.

| # | What is tested |
|---|---|
| 03-01 | No recognised prefix — prefix-strip skipped; owner resolved via `extensionAttribute14` fallback |
| 03-02 | Owner resolved via prefix-strip (primary strategy, no EA14 set) |
| 03-03 | EA14 `owner=<sam>` present but SAM not in AD — EA14 strategy fails; prefix-strip fallback succeeds |
| 03-04 | Both prefix-strip and EA14 would resolve — prefix-strip wins (checked first) |
| 03-05 | Mixed batch — one with resolved owner, one without; unresolved account skipped with `NoOwnerFound` |

### 04-Failures — Error handling and fatal failure paths

`Send-GraphMail` failure is fatal (loop aborts). `Disable-InactiveAccount` and
`Remove-InactiveAccount` failures are per-entry errors (loop continues). These tests
confirm both failure modes and that `Connect-MgGraph` failure shuts the run down before
any accounts are processed.

| # | What is tested |
|---|---|
| 04-01 | `Send-GraphMail` throws — `Success=$false`, `Error` set, `Disable` not fired |
| 04-02 | `Send-GraphMail` throws mid-batch — loop aborts; first account's `Disable` already fired |
| 04-03 | `Disable-InactiveAccount` returns failure — error recorded in Results entry; function completes |
| 04-04 | `Remove-InactiveAccount` returns failure — error recorded in Results entry; function completes |
| 04-05 | Mixed batch: one disable succeeds, one fails — both counted correctly in Summary |
| 04-06 | `Connect-MgGraph` throws — `Success=$false`, `Error` set, `Results` empty, no actions fired |

### 05-Output — Output object structure, summary tallying, and Unprocessed

These tests cover the complete output contract, including the `Unprocessed` field
and the end-to-end re-run pattern that `Unprocessed` enables.

| # | What is tested |
|---|---|
| 05-01 | Return object has `Summary`, `Results`, `Success`, `Error`, `Unprocessed` properties; `LogPath` absent |
| 05-02 | Disable failure → error entry in `Results` with `Status=Error`; `Summary.Errors` incremented |
| 05-03 | Mixed batch of warn/disable/skip — all `Summary` fields tallied correctly |
| 05-04 | Large mixed batch (7 accounts) — all outcome types in one run: Warned, Disabled, Deleted, Error, Skipped/ActivityDetected, Skipped/NoOwnerFound, Skipped/DisabledSinceExport |
| 05-05 | `-WhatIf` — Results fully populated with expected ActionTaken values; no actions fired against mocks |
| 05-06 | `Unprocessed` is empty when all accounts Completed |
| 05-07 | `Unprocessed` contains the error account in import-contract shape (all 8 fields, correct UPN/SAM) |
| 05-08 | **Re-run scenario**: run 1 produces one error → `Unprocessed` has 1 entry; `DisableFail` cleared; run 2 passes `result1.Unprocessed` directly as `-Accounts` → 1 Completed, 0 Unprocessed |

**Why 05-08 matters:** This is the end-to-end proof that the `Unprocessed` field is
genuinely re-runnable. It validates the entire retry contract in a single test:
- The error account appears in `Unprocessed` with the correct shape
- Passing `Unprocessed` as `-Accounts` with no transformation succeeds
- The previously-failed account completes on the retry
- Nothing is double-processed (completed account from run 1 is not in run 2)

### 06-EntraAndEdge — Entra-native accounts and edge cases

| # | What is tested |
|---|---|
| 06-01 | Entra-native with recent sign-in — skipped with `ActivityDetected` |
| 06-02 | Entra-native 95 days inactive — skipped with `NoOwnerFound` (no AD SAM, no owner resolution path) |
| 06-03 | AD account with `EntraObjectId` — Entra sign-in used when more recent than AD logon |
| 06-04 | AD account with `EntraObjectId` — AD logon used when more recent than Entra sign-in |
| 06-05 | Custom thresholds (`WarnThreshold=30`) — account at 35 days triggers Warning |
| 06-06 | All input rows have no UPN — zero result entries, `Success=$true` |
| 06-07 | `SamAccountName` present, `OnPremisesSyncEnabled` and `Source` absent — AD path taken |
