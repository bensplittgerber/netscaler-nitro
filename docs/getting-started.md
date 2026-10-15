# Getting started

## Requirements

- **PowerShell 7** (Windows, Linux or macOS). Windows PowerShell 5.1 is not supported.
- Network access from the machine running the scripts to the NetScaler **NSIP** (or a SNIP with management access) on HTTPS/443.
- A NetScaler account with sufficient rights (superuser for objects; a restricted command policy is possible for certificate-only use, see [certificates.md](certificates.md)).

## Setup

1. Clone or copy the repository.
2. On Windows, unblock downloaded files once:
   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```
3. Put certificate and key files in `certs/` (ignored by git).
4. Copy the examples or templates into `configs/` and adapt them to your environment. Set `nsip` at the top of every file.

## Credentials

The scripts prompt with `Get-Credential` if `-Credential` is not given.

**Windows: save a credential once (encrypted with DPAPI, only usable by your Windows account on that PC):**

```powershell
Get-Credential acme-user | Export-Clixml ./acme-user.cred.xml
./scripts/Deploy-NsObjects.ps1 -ConfigFile ./configs/x.json -Credential (Import-Clixml ./acme-user.cred.xml)
```

**Non-interactive (Linux, containers, pipelines): from environment variables:**

```powershell
$cred = [pscredential]::new($env:NS_USER, (ConvertTo-SecureString $env:NS_PASS -AsPlainText -Force))
./scripts/Deploy-NsObjects.ps1 -ConfigFile ./configs/x.json -Credential $cred
```

**Secrets inside config files** (LDAP bind password, RADIUS key, PFX password, ...) are written as `${env:NAME}` and filled from environment variables at run time:

```json
"ldapbinddnpassword": "${env:LDAP_BIND_PW}"
```

```powershell
$env:LDAP_BIND_PW = Read-Host 'LDAP bind password' -MaskInput
```

The run stops before connecting if a referenced variable is not set.

## Typical workflow

1. **Dry run** with `-WhatIf`. It logs in and shows every planned change; nothing is changed or saved.
2. **Certificates first** with `Deploy-NsCertificates.ps1`, so objects can bind certkeys by name.
3. **Objects** with `Deploy-NsObjects.ps1`, one file per area, in dependency order (e.g. LB → AAA → Gateway).
4. **Verify** on the appliance.
5. **Undo** if needed, in reverse order (see [rollback-and-undo.md](rollback-and-undo.md)).

## Testing without risk

- `-NoSave`: changes stay in the running config only; a reboot reverts them.
- `-Backup`: creates a NetScaler system backup before the first change.
- On a VPX: shut down and snapshot first, revert the snapshot after the test.
- `diff ns config` on the NetScaler shows any difference between running and saved config, useful to confirm an undo left nothing behind.

Note: certificate and key files uploaded to `/nsconfig/ssl` and backup files stay on disk after a reboot. They are inactive and are reported as `[EXISTS]` on the next run.

## Output legend

| Tag | Meaning |
|---|---|
| `[OK]` | Created / changed by this run |
| `[EXISTS]` | Already present, left unchanged (not journaled) |
| `[SKIP]` | Step disabled with `"skip": true`, or binding removed together with its parent during undo |
| `[INFO]` | Information only |
| `[MANUAL]` | Not reversed automatically during undo/rollback |
| `[GONE]` | Undo: object was already removed |
| `[ROLLBACK]` | Certificate swap failed, previous certificate re-bound |
| `[FAILED]` | Step failed; the run stops (and rolls back) unless `-ContinueOnError` |
