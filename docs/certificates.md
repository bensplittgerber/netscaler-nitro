# Certificates

`Deploy-NsCertificates.ps1` processes each entry of `certificates` in order:

1. **Upload** cert + key (or PFX) to `/nsconfig/ssl` via the `systemfile` resource.
2. **Create** the certkey (`add ssl certKey`).
3. **Update** in place if it already exists and `"update": true` (`update ssl certKey`).
4. **Link** to the CA certkey in `linkTo`.
5. **Bind** to every vserver in `bindTo`, optionally replacing the current certificate.

Put CA certificates **before** the certificates that link to them.

## Scenarios

### New certificate with chain

```json
{ "name": "le_yr1", "certFile": "../certs/YR1-2028.crt" },
{ "name": "app_example_com", "certFile": "../certs/app.crt", "keyFile": "../certs/app.key", "linkTo": "le_yr1" }
```

The root CA is normally not needed on the NetScaler: clients have it in their trust store. `show ssl certChain <certkey>` shows the root as "Add certificate with this subject name" - that is informational only.

### Renewal in place (recommended for certificates bound to many vservers)

```json
{ "name": "san_example_com", "certFile": "../certs/new.crt", "keyFile": "../certs/new.key",
  "linkTo": "le_yr1", "update": true }
```

The certkey name stays, all bindings stay, no listener goes down. New TLS handshakes get the new certificate immediately. Use a neutral certkey name (without a date) for certificates renewed this way.

### Swap a vserver to a different certkey

```json
{ "name": "app_example_com_2027", "certFile": "../certs/app2027.crt", "keyFile": "../certs/app2027.key",
  "linkTo": "le_yr1", "bindTo": ["gw_example_com", "lb_web"], "replace": true }
```

For each vserver in `bindTo`:

| Situation | Result |
|---|---|
| already bound to this certkey | `[EXISTS]`, nothing changes |
| no server certificate bound | certificate is bound (`[INFO]` + `[OK]`) |
| other server certificate, `replace: true` | old one unbound, new one bound; if the bind fails the old one is re-bound (`[ROLLBACK]`) |
| other server certificate, no `replace` | bind fails (only one server certificate per vserver without SNI) |

CA and SNI bindings on the vserver are never touched. Vservers not listed are never touched. `-WhatIf` reads the current bindings and shows exactly which certificate would be unbound.

### PFX

```json
{ "name": "app_pfx", "pfxFile": "../certs/app.pfx", "password": "${env:PFX_PASS}", "linkTo": "le_yr1" }
```

### Same file name again

Uploading a file whose name already exists in `/nsconfig/ssl` reports `[EXISTS]` and keeps the old file. Use a new file name for new certificates, or `"overwrite": true`.

## Duplicate certificates

NetScaler keeps each certificate (by content) only once. If the same certificate is already installed under another certkey name, the message shows that name:

```
[EXISTS]  add certkey new_name  (Resource already exists [certkeyName Contents, existing_name])
[FAILED]  certkey new_name was not created: this certificate is already installed under another certkey name ...
```

Use the existing name, or deploy a genuinely new certificate. Certkeys cannot be renamed.

**Let's Encrypt tools** (e.g. GenLeCertForNS) often install and update certkeys on the NetScaler themselves. Decide on one process: either the tool installs, or it only creates files and this script deploys them.

## HA pairs

Run against the primary. Use `-SyncHaFiles` so uploaded files are copied to the secondary (`sync ha files ssl`).

## Restricted account for certificate runs (optional)

```
add system cmdPolicy pol_cert_deploy ALLOW "^(show|add|link|update|bind|unbind)\s+ssl\s+.*|^(show|add|rm)\s+system\s+file\s+.*|^save\s+ns\s+config|^sync\s+ha\s+files\s+ssl|^create\s+system\s+backup.*"
bind system user <user> pol_cert_deploy 10
```

Test on a lab first; an authorization error names the missing command.

## Verify

```
show ssl certKey <certkey>
show ssl certChain <certkey>
```

What clients receive (PowerShell, no openssl needed):

```powershell
$tcp = [Net.Sockets.TcpClient]::new('<vip>', 443)
$ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
$ssl.AuthenticateAsClient('<hostname>')
[Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate) |
    Select-Object Subject, Issuer, SerialNumber, NotBefore, NotAfter
$ssl.Dispose(); $tcp.Dispose()
```
