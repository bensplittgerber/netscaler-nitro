# Troubleshooting

## Connection

| Error | Cause | Fix |
|---|---|---|
| `The remote certificate is invalid ... RemoteCertificateNameMismatch, RemoteCertificateChainErrors` | Self-signed management certificate | `-SkipCertificateCheck` (lab), or a trusted management certificate |
| `The proxy tunnel request to proxy '...' failed with status code '407'` | Request goes through a corporate proxy that wants authentication | `-NoProxy`, or a proxy exception for the NSIP/hostname |
| `Unable to read data from the transport connection ... closed by the remote host` | Proxy, firewall, or TLS version/cipher mismatch | Test as below |
| `Login failed: ...` | Wrong credentials or account not allowed to use NITRO | Check user, password, command policy |
| `... failed (pinned sha256//...): The remote certificate was rejected by the provided RemoteCertificateValidationCallback` | Management certificate changed (renewed/replaced) or something else answers on the NSIP | `Get-NitroPin`, verify out of band, update the pin |
| `-PinnedPublicKey must look like 'sha256//<44 base64 characters>'` | Pin without the `sha256//` prefix or truncated | Copy the full value |
| `Unable to find type [NetScalerNitro.PinValidator]` / `ExportSubjectPublicKeyInfo` not found | PowerShell older than 7.2 | Update PowerShell, or use `-SkipCertificateCheck` |

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

## Re-run journals from 1.1.0 and older

Before 1.2.0 a re-run could journal objects that already existed as `[OK]` (NITRO answers some re-adds with
success, e.g. `authenticationpolicylabel` and `vpnvserver_*` policy bindings). An undo from such a journal removes
configuration the run did not create. Check old journals of re-runs before using them (`Undo-NsObjects.ps1 -WhatIf`
lists every entry) and delete entries for objects that existed before.

## Gateway / SSL (lessons learned)

| Situation | Cause / fix |
|---|---|
| STA servers of a new Gateway vserver `DOWN` | Normal for up to ~1 minute after the vserver is created; check again before troubleshooting |
| HTTP CRL: `Status: Undefined`, `Last Update: Failed, the CRL is incomplete` although the CRL URL works | 14.1 does not build the first copy from HTTP. Create the CRL from a local file first, then switch on HTTP refresh (CLI below) |
| Client-certificate nFactor factor (`CLIENT.SSL.CLIENT_CERT.EXISTS`) does not match, users see the user name/password form | `sessionTicket ENABLED` on the SSL profile: on a resumed TLS session the client certificate is not available. Keep session tickets `DISABLED` on profiles with a client-cert factor |
| `vpnvserver_authorizationpolicy_binding` / `vpnglobal_authorizationpolicy_binding` -> `1232` | 14.1 binds authorization policies only to AAA users/groups, see `examples/07-authorization.json` |
| Callback test with a browser / `Invoke-WebRequest` on `/CitrixAuthService/AuthService.asmx` fails | The NetScaler closes plain GETs there on every Gateway vserver. Test with a real login, see `examples/06-callback.json` |

HTTP CRL that starts from a local file (NetScaler CLI; `client_ca_issuing` = the CA certkey that signs the CRL):

```
shell curl -s -o /var/netscaler/ssl/client_ca.crl http://pki.example.org/crl
add ssl crl crl_client_ca client_ca.crl -inform DER -CAcert client_ca_issuing
set ssl crl crl_client_ca -refresh ENABLED -method HTTP -url http://pki.example.org/crl -port 80 -interval DAILY -time 03:00
set ssl crl crl_client_ca -interval NOW
save ns config
show ssl crl crl_client_ca
```

`show ssl crl` must say `Status: Valid` and `Last Update: Successful`. Because of this order, CRLs are not part of
the JSON examples (a NITRO `sslcrl` add with only an HTTP URL ends up in the same `Undefined` state).

## SAML (lessons learned)

- The SAML **ACS URL** is `https://<authentication host>/cgi/samlauth`. It is built from the hostname of the login (the authentication profile's `authenticationhost`), not from the SAML action name.
- The IdP looks up the SP by **Issuer** (`samlissuername`) and checks the ACS URL against that SP's registered list. "ACS URL matches no configured ACS URL" means the IdP's SP metadata contains a different hostname, or the same URL is registered for another SP.
- Update `relaystaterule` when the gateway hostname changes.
- The NetScaler publishes its SP metadata at `https://<host>/metadata/samlsp/<saml action name>`.
- If `samlsigningcertname` is not set, the NetScaler signs with its internal default certificate.
