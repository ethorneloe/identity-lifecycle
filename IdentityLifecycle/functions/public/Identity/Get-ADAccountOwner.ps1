function Get-ADAccountOwner {
    <#
    .SYNOPSIS
        Resolves the owner of a prefixed AD account.

    .DESCRIPTION
        Attempts to identify the owning standard account in two steps, in order:

            1. Prefix strip -- matches the SamAccountName against each supplied prefix
               followed by a single separator character (dot or underscore), and treats
               the remainder as the candidate standard SAM
               (e.g. prefix 'ca', SAM 'ca.jsmith' -> candidate 'jsmith').
               The candidate is verified to exist in AD before being returned.
               This is the primary strategy because the naming convention is the
               authoritative ownership contract. Prefixes are tried longest-first so
               a prefix 'adm' is not shadowed by 'ad' if both are supplied.

            2. Extension attribute -- looks for an 'owner=<sam>' key=value pair in a
               semicolon-delimited string (e.g. 'dept=IT;owner=jsmith.mgr;location=HQ').
               The candidate SAM is verified to exist in AD before being returned.
               extensionAttribute14 is used here as it tends to be available in most
               environments; swap it for whichever extension attribute your org uses.
               Use this for accounts that do not follow the naming convention (shared
               accounts, exceptions, accounts owned by someone other than the name implies).

        Returns $null when neither strategy resolves a valid AD account.

    .PARAMETER SamAccountName
        The SamAccountName of the privileged account whose owner is being resolved.
        Required for the prefix-strip strategy; may be empty for Entra-native accounts
        (in which case the orchestrator derives a candidate from the UPN local-part).

    .PARAMETER ExtAttr14
        The value of an extension attribute on the AD account, if present. extensionAttribute14
        is used in the orchestrators as it tends to be spare in most environments; swap it for
        whichever attribute your org uses. May be $null or empty -- the strategy is silently
        skipped in that case.

    .PARAMETER Prefixes
        The set of known SAMAccountName prefixes, e.g. @('ca','adm','sup'). Passed in from
        the orchestrator so owner resolution uses the same prefix list as account discovery.
        Default: @('admin','priv') as a safe fallback, but callers should always pass the
        same list they use for Get-PrefixedADAccounts.

    .OUTPUTS
        [pscustomobject] with fields:
            SamAccountName  - the resolved owner SAM
            ResolvedBy      - 'ExtensionAttribute14' or 'PrefixStrip'
        Returns $null if no owner could be resolved.

    .EXAMPLE
        $owner = Get-ADAccountOwner -SamAccountName 'ca.jsmith' `
                     -Prefixes @('ca','adm','sup') `
                     -ExtAttr14 'dept=IT;owner=jsmith.mgr'
        if ($owner) {
            Write-Host "Owner resolved via $($owner.ResolvedBy): $($owner.SamAccountName)"
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string] $SamAccountName,

        [Parameter()]
        [string] $ExtAttr14,

        [Parameter()]
        [string[]] $Prefixes = @('admin', 'priv')
    )

    # ------------------------------------------------------------------
    # Strategy 1: prefix strip (primary -- naming convention is authoritative)
    # Try each known prefix (longest first to avoid partial matches).
    # Strip the prefix and one separator character (dot or underscore).
    # e.g. prefix 'ca',  SAM 'ca.jsmith'  -> candidate 'jsmith'
    #      prefix 'adm', SAM 'adm_jsmith' -> candidate 'jsmith'
    # ------------------------------------------------------------------
    if ($SamAccountName) {
        foreach ($prefix in ($Prefixes | Sort-Object { $_.Length } -Descending)) {
            if ($SamAccountName -match "^$([regex]::Escape($prefix))[._](.+)$") {
                $candidate = $Matches[1]
                try {
                    if (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction Stop) {
                        return [pscustomobject]@{
                            SamAccountName = $candidate
                            ResolvedBy     = 'PrefixStrip'
                        }
                    }
                }
                catch { Write-Verbose "Prefix-strip lookup failed for '$candidate': $_" }
                break  # prefix matched; no point trying shorter prefixes
            }
        }
    }

    # ------------------------------------------------------------------
    # Strategy 2: extension attribute  owner=<sam>  (exception override)
    # extensionAttribute14 is used as it tends to be spare; swap for whichever your org uses.
    # Used for accounts that don't follow the naming convention.
    # ------------------------------------------------------------------
    if ($ExtAttr14) {
        foreach ($pair in ($ExtAttr14 -split ';')) {
            if ($pair.Trim() -match '(?i)^owner=(.+)$') {
                $candidate = $Matches[1].Trim()
                if ($candidate) {
                    try {
                        if (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction Stop) {
                            return [pscustomobject]@{
                                SamAccountName = $candidate
                                ResolvedBy     = 'ExtensionAttribute14'
                            }
                        }
                    }
                    catch { Write-Verbose "EA14 owner lookup failed for '$candidate': $_" }
                }
            }
        }
    }

    return $null
}
