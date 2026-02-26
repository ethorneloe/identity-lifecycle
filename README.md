# IdentityLifecycle

A PowerShell module that emails owners of inactive privileged accounts and disables or deletes them on a schedule.

## What it does

Accounts are evaluated against inactivity thresholds:

```
< 90 days inactive   → no action
90+ days inactive    → warning email to owner
120+ days inactive   → disable + email to owner
180+ days inactive   → delete + email to owner  (requires -EnableDeletion)
```

Thresholds are configurable. The module applies the highest action warranted — a newly discovered 150-day inactive account is disabled immediately, not warned first.

Deletion requires `-EnableDeletion` as an explicit opt-in.

---

## Prerequisites

- PowerShell 5.1+
- `ActiveDirectory` module (RSAT)
- `Microsoft.Graph` module
- A `Send-GraphMail` function in scope (not in this module — see Known Gaps below)

---

## Two ways to run it

**Discovery mode** — finds accounts itself by querying AD and Entra:

```powershell
$result = Invoke-InactiveAccountRemediation `
    -Prefixes     @('admin.', 'priv.') `
    -ADSearchBase 'OU=PrivAccounts,DC=corp,DC=local' `
    -MailSender                'iam@corp.local' `
    -MailClientId              $mailAppId `
    -MailTenantId              $tenantId `
    -MailCertificateThumbprint $mailThumb `
    -ClientId                  $graphAppId `
    -TenantId                  $tenantId `
    -CertificateThumbprint     $graphThumb `
    -EnableDeletion
```

**Import mode** — takes a list you provide (e.g. from a CSV export or the previous run's failures):

```powershell
$accounts = Import-Csv 'C:\Reports\PrivAccounts.csv'

$result = Invoke-InactiveAccountRemediation `
    -Accounts $accounts `
    -Prefixes @('admin.', 'priv.') `
    -MailSender                'iam@corp.local' `
    -MailClientId              $mailAppId `
    -MailTenantId              $tenantId `
    -MailCertificateThumbprint $mailThumb `
    -ClientId                  $graphAppId `
    -TenantId                  $tenantId `
    -CertificateThumbprint     $graphThumb `
    -EnableDeletion
```

---

## Output

`$result` always comes back — the function never throws. Check what happened:

```powershell
$result.Success    # $true if everything completed without a fatal error

$result.Summary    # totals: Warned, Disabled, Deleted, Skipped, Errors

$result.Results    # one row per account — Status, ActionTaken, Error, etc.

$result.Unprocessed  # accounts to retry — pass directly as -Accounts on next run
```

### Retrying failures

If accounts failed (mail error, action error, or the job crashed mid-run), `$result.Unprocessed` holds them ready to feed back in:

```powershell
if ($result.Unprocessed) {
    $retry = Invoke-InactiveAccountRemediation `
        -Accounts $result.Unprocessed `
        -Prefixes @('admin.', 'priv.') `
        -MailSender 'iam@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
        -ClientId $graphAppId -TenantId $tenantId -CertificateThumbprint $graphThumb `
        -EnableDeletion
}
```

Discovery mode output feeds directly into import mode — no conversion needed.

---

## How owner resolution works

For each account the module looks for the owner in order:

1. Strip the prefix from the SAM — `admin.jsmith` → looks for `jsmith` in AD
2. Check `extensionAttribute14` for an `owner=<sam>` value
3. Check the account's Entra sponsor

If no owner is found the account is skipped with `SkipReason=NoOwnerFound`.

---

## Dry run

Add `-WhatIf` to see what would happen without sending any emails or touching any accounts:

```powershell
$result = Invoke-InactiveAccountRemediation `
    -Accounts $accounts -Prefixes @('admin.', 'priv.') `
    -MailSender 'iam@corp.local' -MailClientId $mailAppId -MailTenantId $tenantId -MailCertificateThumbprint $mailThumb `
    -UseExistingGraphSession -WhatIf

$result.Results | Format-Table UserPrincipalName, InactiveDays, ActionTaken, SkipReason
```

---

## Running the tests

```powershell
. .\run-tests.ps1
```

---

## Known gaps

**`Send-GraphMail` is not in this module.** Bring your own implementation. The module calls it with `-Sender`, `-ClientID`, `-Tenant`, `-CertificateThumbprint`, `-ToRecipients`, `-Subject`, `-Body`, `-BodyType`, `-ErrorAction Stop`.

**AD account deletion is a stub.** `Remove-InactiveAccount` throws on the AD path — replace it with your org's offboarding process. Entra-native deletion works.

---

## Further reading

- [REFERENCE.md](REFERENCE.md) — full parameter reference, output schema, execution flow, and operational mode examples
- [SOLUTION-ARCHITECTURE.md](SOLUTION-ARCHITECTURE.md) — internal design, data flow, and module structure
