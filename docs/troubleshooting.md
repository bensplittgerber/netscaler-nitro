# Troubleshooting

## Connection

| Error | Cause | Fix |
|---|---|---|
| `The remote certificate is invalid ... RemoteCertificateNameMismatch, RemoteCertificateChainErrors` | Self-signed management certificate | `-SkipCertificateCheck` (lab), or a trusted management certificate |
| `The proxy tunnel request to proxy '...' failed with status code '407'` | Request goes through a corporate proxy that wants authentication | `-NoProxy`, or a proxy exception for the NSIP/hostname |
| `Unable to read data from the transport connection ... closed by the remote host` | Proxy, firewall, or TLS version/cipher mismatch | Test as below |
| `Login failed: ...` | Wrong credentials or account not allowed to use NITRO | Check user, password, command policy |

Without changing the scripts, the proxy can also be bypassed for the current PowerShell window:

```powershell
[System.Net.Http.HttpClient]::DefaultProxy = [System.Net.WebProxy]::new()
```

Quick connectivity test (no credentials sent; `OK` means the TLS handshake works):

```powershell
$u = 'https://<nsip>/nitro/v1/config/nsversion'
foreach ($p in 'Tls12','Tls13') { foreach ($np in $false,$true) {
    try { Invoke-RestMethod $u -SkipCertificateCheck -SkipHttpErrorCheck -SslProtocol $p -NoProxy:$np | Out-Null; "$p NoProxy=$np : OK" }
    catch { "$p NoProxy=$np : $($_.Exception.Message)" } } }
```

## Config files

| Message | Cause |
|---|---|
| `... is not valid JSON` | Missing quotes (e.g. `[acme-gw]` instead of `["acme-gw"]`) or a wrong comma after the last element |
| `... has no "nsip" value` | `nsip` missing at the top |
| `Environment variable 'X' is referenced ... but not set` | Set `$env:X` before the run |
| `... has no 'certificates' entries ... use Deploy-NsObjects.ps1` | Objects file passed to the certificate script |
| `... has no 'steps' with a resource ... use Deploy-NsCertificates.ps1` | Certificate file passed to the objects script |
| `File not found: ...` | Cert paths are relative to the JSON file |

## NITRO errors (examples)

| Code / message | Meaning |
|---|---|
| `1540: Certificate does not exist` | Certkey not deployed yet, or created under another name |
| `Resource already exists [certkeyName Contents, X]` | Same certificate already installed as certkey `X` |
| `278: Invalid argument` | Wrong parameter name/value; compare with the NITRO reference or a GET of an existing object |
| `2054: No such policy exists` | Referenced policy missing (order of steps) |

## Running the wrong script

`Deploy-NsCertificates.ps1` with an objects file (or the reverse) stops before connecting since 1.0.0. Older versions connected, did nothing and saved the running config.

## Undo

| Situation | Behaviour |
|---|---|
| Binding of a removed vserver | `[SKIP]` (removed together with the vserver) |
| Object already removed | `[GONE]`, counts as done |
| `[MANUAL]` entries | `set`/`action` steps; revert by hand if they changed pre-existing objects |
| Undo fails because an object is still in use | Undo dependent deployments first (reverse order) |

## SAML (lessons learned)

- The SAML **ACS URL** is `https://<authentication host>/cgi/samlauth`. It is built from the hostname of the login (the authentication profile's `authenticationhost`), not from the SAML action name.
- The IdP looks up the SP by **Issuer** (`samlissuername`) and checks the ACS URL against that SP's registered list. "ACS URL matches no configured ACS URL" means the IdP's SP metadata contains a different hostname, or the same URL is registered for another SP.
- Update `relaystaterule` when the gateway hostname changes.
- The NetScaler publishes its SP metadata at `https://<host>/metadata/samlsp/<saml action name>`.
- If `samlsigningcertname` is not set, the NetScaler signs with its internal default certificate.
