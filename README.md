# netscaler-nitro

PowerShell 7 toolset that deploys NetScaler (ADC / Gateway) configuration through the **NITRO REST API** from JSON files, instead of typing CLI commands over SSH.

- **Declarative JSON configs**: one file per area (certificates, LB, AAA, Gateway, ...)
- **Certificates**: upload, create, link to CA, bind, in-place renewal, swap on vservers with rollback
- **Objects**: any NITRO resource, safe to re-run (every add/bind is looked up first; existing objects are skipped and never journaled)
- **Safety**: dry run (`-WhatIf`), automatic rollback on failure, journal + undo, optional `-NoSave` and `-Backup`
- **Runs on Windows and Linux** (PowerShell 7), no extra modules required

Tested against NetScaler **14.1** (lab and a production migration).

## Repository layout

```
netscaler-nitro/
├── scripts/
│   ├── NetScalerNitro.psm1        shared module (login, NITRO calls, results, rollback helpers)
│   ├── Deploy-NsCertificates.ps1  certificate deployment
│   ├── Deploy-NsObjects.ps1       configuration objects (with rollback + journal)
│   ├── Undo-NsObjects.ps1         removes a previous deployment using its journal
│   └── Invoke-NsDeployment.ps1    runs several object files in order (one-flow), prompts secrets once
├── templates/                     all supported patterns, every step disabled ("skip": true)
│   ├── certs-template.json
│   └── objects-template.json
├── examples/                      a complete, generic StoreFront + SAML or Entra OIDC Gateway setup
│   ├── 00-prereq.json             host name, DNS, NTP, default SSL profile, least-privilege certificate user
│   ├── 00-network.json            optional static routes / VLAN / SNIP (all steps skip:true)
│   ├── 01-certs-example.json
│   ├── 02-lb-storefront.json
│   ├── 03-aaa-saml.json           SAML IdP ...
│   ├── 03-aaa-oidc-entra.json     ... or Microsoft Entra ID via OIDC (same AAA/profile names)
│   ├── 04-gateway.json
│   ├── 05-ssl-hardening.json      cipher group (forward secrecy + AEAD only), strict HTTP profile with WebSocket
│   ├── 06-callback.json           optional dedicated StoreFront callback vserver
│   └── 07-authorization.json      optional authorization policies via AAA group (clientless / RDP proxy)
├── tests/
│   └── Test-NsObjects.ps1         offline test against a fake NITRO API (dry run, journal, re-run, undo)
├── configs/                       your real environment configs (no secrets in here!)
├── certs/                         certificate/key files - ignored by git
└── docs/
    ├── getting-started.md
    ├── config-reference.md
    ├── certificates.md
    ├── rollback-and-undo.md
    ├── linux.md
    └── troubleshooting.md
```

The files in `scripts/` must stay together: every script loads `NetScalerNitro.psm1` from its own folder.

## Quick start

```powershell
# 1. dry run - logs in, shows what would happen, changes nothing
./scripts/Deploy-NsCertificates.ps1 -ConfigFile ./examples/01-certs-example.json -SkipCertificateCheck -WhatIf

# 2. certificates first, then objects in order
./scripts/Deploy-NsCertificates.ps1 -ConfigFile ./examples/01-certs-example.json -SkipCertificateCheck
./scripts/Deploy-NsObjects.ps1      -ConfigFile ./examples/02-lb-storefront.json -SkipCertificateCheck
./scripts/Deploy-NsObjects.ps1      -ConfigFile ./examples/03-aaa-saml.json      -SkipCertificateCheck
./scripts/Deploy-NsObjects.ps1      -ConfigFile ./examples/04-gateway.json       -SkipCertificateCheck

# 3. remove a deployment again (reverse order)
./scripts/Undo-NsObjects.ps1 -Journal ./scripts/journals/04-gateway-<timestamp>.json -SkipCertificateCheck
```

See [docs/getting-started.md](docs/getting-started.md) for requirements, credentials and the full workflow.

## Common switches

| Switch | Scripts | Effect |
|---|---|---|
| `-WhatIf` | all | Dry run: shows planned changes, changes nothing |
| `-Credential` | all | Login credential; prompted for if omitted |
| `-SkipCertificateCheck` | all | Accept the NetScaler's self-signed management certificate (no check at all) |
| `-PinnedPublicKey` | all | Accept only this management certificate key (`sha256//...`), checked on every request |
| `-NoProxy` | all | Connect directly, bypassing the system/corporate proxy |
| `-NoSave` | all | Don't run `save ns config` (a reboot reverts the changes) |
| `-Backup` | deploy scripts | Create a system backup before changing anything |
| `-ContinueOnError` | deploy scripts | Keep going after a failed step |
| `-NoRollback` | `Deploy-NsObjects` | Keep partial changes after a failure (for troubleshooting) |
| `-SyncHaFiles` | `Deploy-NsCertificates` | `sync ha files ssl` after uploading certificates |

## Tests

```powershell
./tests/Test-NsObjects.ps1    # no NetScaler needed: fake NITRO API on 127.0.0.1
```

## Related

- [netscaler-rdp-proxy-oidc](https://github.com/bensplittgerber/netscaler-rdp-proxy-oidc): complete RDP proxy Gateway
  with Microsoft Entra ID (OIDC) and authorization through an AAA group, deployed with these scripts.

## Documentation

- [Getting started](docs/getting-started.md)
- [Config file reference](docs/config-reference.md)
- [Certificates](docs/certificates.md)
- [Rollback and undo](docs/rollback-and-undo.md)
- [Running on Linux](docs/linux.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Changelog](CHANGELOG.md)

## Security notes

- Never commit certificates, keys, `.cred.xml` files or passwords. `.gitignore` covers the usual cases; secrets in configs go through `${env:NAME}` placeholders.
- Use a dedicated NetScaler account instead of `nsroot` for routine runs.
- `-SkipCertificateCheck` sends the credentials to whoever answers on the NSIP. Prefer `-PinnedPublicKey` (works with the self-signed certificate) or a trusted management certificate. Get the pin with `Get-NitroPin` or `acme-ns pin` and compare it out of band once.
- Keep management traffic off web proxies (`-NoProxy` or a proxy exception), so credentials never pass an inspecting proxy.
