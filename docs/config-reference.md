# Config file reference

All config files are JSON. JSON has no comments: use `"comment"` steps for headings, `"note"` for free text, and `"skip": true` to disable a step.

Every file needs:

```json
{ "nsip": "https://<NSIP or management SNIP>", ... }
```

## Objects file (`Deploy-NsObjects.ps1`)

```json
{
  "nsip": "https://192.0.2.10",
  "steps": [
    { "comment": "Heading printed in the output" },
    { "resource": "<nitro resource>", "data": { ... } }
  ]
}
```

### Step fields

| Field | Required | Meaning |
|---|---|---|
| `resource` | yes* | NITRO resource name, e.g. `lbvserver`, `authenticationsamlaction` |
| `data` | yes* | Object properties, sent as `{ "<resource>": <data> }` |
| `action` | no | Sends `POST ...?action=<action>` (e.g. `enable`, `link`) |
| `method` | no | Force the HTTP method, e.g. `"PUT"` to change an existing object (`set ...`) |
| `skip` | no | `true` = step is ignored |
| `comment` | no | Printed as a heading; a step may contain only a comment |
| `note` | no | Free text, ignored |

\* not needed for comment-only steps.

### How the HTTP method is chosen

| Step | Request | CLI equivalent |
|---|---|---|
| plain resource | `POST /nitro/v1/config/<resource>` | `add ...` |
| resource ending in `_binding` | `PUT /nitro/v1/config/<resource>` | `bind ...` |
| with `"action": "x"` | `POST /nitro/v1/config/<resource>?action=x` | `enable ...`, `link ...` |
| with `"method": "PUT"` | `PUT /nitro/v1/config/<resource>` | `set ...` |

### Translating CLI to JSON

Resource names follow the CLI object without spaces; parameters are the CLI options in lower case:

```
add lb vserver lb_web SSL 10.0.20.11 443 -persistenceType SOURCEIP
```

```json
{ "resource": "lbvserver",
  "data": { "name": "lb_web", "servicetype": "SSL", "ipv46": "10.0.20.11", "port": 443, "persistencetype": "SOURCEIP" } }
```

| CLI | NITRO resource |
|---|---|
| `bind lb vserver X svc` | `lbvserver_service_binding` |
| `bind ssl vserver X -certkeyName c` | `sslvserver_sslcertkey_binding` |
| `set ssl vserver X -sslProfile p` | `sslvserver` with `"method": "PUT"` |
| `set ssl service X -sslProfile p` | `sslservice` with `"method": "PUT"` |
| `bind authentication vserver X -policy p` | `authenticationvserver_authenticationpolicy_binding` |
| `bind vpn vserver X -staServer url` | `vpnvserver_staserver_binding` |
| `bind vpn vserver X -policy p -type REQUEST` | `vpnvserver_vpnsessionpolicy_binding` with `"bindpoint": "REQUEST"` |
| `enable ns feature LB SSL` | `nsfeature` with `"action": "enable"` |
| `set ns hostName ns01` | `nshostname` with `"method": "PUT"` |
| `add dns nameServer 192.0.2.53` | `dnsnameserver` (`ip`) |
| `add ntp server ntp.example.org` / `enable ntp sync` | `ntpserver` (`servername` or `serverip`) / `ntpsync` with `"action": "enable"` |
| `bind service X -monitorName m` | `service_lbmonitor_binding` (`name`, `monitor_name`) |
| `add ssl cipher g` / `bind ssl cipher g -cipherName c` | `sslcipher` (`ciphergroupname`) / `sslcipher_sslciphersuite_binding` |
| `bind ssl profile p -cipherName g` | `sslprofile_sslcipher_binding` (`name`, `ciphername`) |
| `add ns httpProfile p ...` / `set vpn vserver X -httpProfileName p` | `nshttpprofile` / `vpnvserver` with `"method": "PUT"` |
| `add authorization policy p "rule" ALLOW` | `authorizationpolicy` |
| `add aaa group g` / `bind aaa group g -policy p -type REQUEST` | `aaagroup` / `aaagroup_authorizationpolicy_binding` |
| `set authentication OAuthAction a -defaultAuthenticationGroup g` | `authenticationoauthaction` with `"method": "PUT"` |

### Undo keys of the resource types used in the examples

| Resource | Journal / undo |
|---|---|
| `sslcipher`, `sslcipher_sslciphersuite_binding` | removed by `ciphergroupname` (+ `ciphername` for the binding) |
| `sslprofile_sslcipher_binding` | removed by `name` + `ciphername` |
| `service_lbmonitor_binding` | removed by `name` + `monitor_name` |
| `aaagroup_authorizationpolicy_binding` | removed by `groupname` + `policy` |
| `nshttpprofile`, `authorizationpolicy`, `aaagroup` | removed by `name` / `groupname` |
| `nshostname`, `dnsnameserver`, `ntpserver`, `ntpsync`, `route`, all `"method": "PUT"` and `"action"` steps | `[MANUAL]`, not reversed |

Easiest way to get the exact JSON for an existing object: read it from a configured appliance, e.g. `GET https://<nsip>/nitro/v1/config/vpnvserver/<name>`.

Full parameter list per resource: NITRO API reference → Configuration → *resource*.

### Behaviour

- Steps run in file order. Order dependencies yourself (servers → services → vservers → bindings).
- Every add/bind step is looked up first (`GET /nitro/v1/config/<resource>/<key>`; for bindings the entry must
  match the step's policy/service/certkey/monitor/cipher/... argument). Found → `[EXISTS]  (found before add)`, the
  step is not sent and not journaled. This matters because NITRO answers some re-adds with **success** instead of
  `already exists` (seen on 14.1 for `authenticationpolicylabel` and `vpnvserver_*` policy bindings).
- If the lookup cannot decide (no key field, e.g. `dnsnameserver`, `ntpserver`, `route`), the step is sent and
  `Resource already exists` → `[EXISTS]` as before. Re-running a file is safe.
- `-WhatIf` runs the same lookups (read-only), so a dry run shows `[EXISTS]` for what is already there and
  `What if: ...` only for what would really be created.
- Existing objects are **not** updated by a plain step. Use `"method": "PUT"` for changes.
- Deleting a step from a file does **not** delete the object on the NetScaler.

## Certificates file (`Deploy-NsCertificates.ps1`)

```json
{
  "nsip": "https://192.0.2.10",
  "certificates": [
    { "name": "<certkey>", "certFile": "../certs/x.crt", "keyFile": "../certs/x.key", "linkTo": "<ca certkey>" }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | certkey name on the NetScaler (letters, digits, `_`, `-`, `.`; no parentheses) |
| `certFile` / `keyFile` | PEM/DER files; paths relative to the JSON file or absolute |
| `pfxFile` | PFX instead of cert + key |
| `password` | key/PFX password, use `${env:NAME}` |
| `linkTo` | CA certkey to link to (intermediate) |
| `bindTo` | list of vserver names (any SSL vserver type) |
| `replace` | `true` = unbind the current server certificate from each `bindTo` vserver first |
| `update` | `true` = existing certkey is updated in place (renewal) |
| `overwrite` | `true` = replace files with the same name in `/nsconfig/ssl` |

Details: [certificates.md](certificates.md).

## Validation

Before connecting, the scripts stop with a clear error if:

- the file is not valid JSON, or has no `nsip`
- an `${env:NAME}` placeholder references an unset variable
- the file contains nothing for this script (e.g. an objects file passed to `Deploy-NsCertificates.ps1`)
