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

## Fresh appliance (14.1 VPX)

A new VPX has the **default SSL profile disabled**: every new SSL vserver then allows SSLv3/TLS 1.0/1.1 and no TLS 1.3,
and SSL profiles cannot be bound. Enable it once before anything else (`examples/00-prereq.json` does it via NITRO,
without the CLI's Y/N prompt; it cannot be undone):

```
set ssl parameter -defaultProfile ENABLED
```

The default route is normally set at first boot. Static routes, extra VLANs and SNIPs: `examples/00-network.json`
(all steps `skip: true`).

## Trusting the management certificate

| Option | Check | Use |
|---|---|---|
| `-SkipCertificateCheck` | none - credentials go to whoever answers on the NSIP | lab only |
| `-PinnedPublicKey 'sha256//...'` | the certificate's public key must match, on every request | self-signed certificate |
| neither | normal CA validation | trusted management certificate |

```powershell
Import-Module ./scripts/NetScalerNitro.psm1
Get-NitroPin -NsIp https://192.0.2.10          # sha256//... - compare once out of band (console, another host)
./scripts/Deploy-NsObjects.ps1 -ConfigFile ./configs/x.json -PinnedPublicKey 'sha256//...'
```

The value is the same as `acme-ns pin` (netscaler-acme) and `curl --pinnedpubkey`. It changes when the management
certificate is replaced. Pinning needs PowerShell 7.2 or later.

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

## One flow (several files)

```powershell
./scripts/Invoke-NsDeployment.ps1 -ConfigFile ./configs/00-prereq.json, ./configs/02-lb.json, ./configs/04-gw.json `
    -Secret CERT_USER_PW, OIDC_CLIENT_SECRET -PinnedPublicKey 'sha256//...' -WhatIf
```

Files run in order, the first failure stops the flow (that file is rolled back, earlier files keep their journals).
Each `-Secret` variable is prompted masked if not set and removed again at the end. Files with only `skip: true` steps
are skipped.

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
