# netscaler-nitro

PowerShell 7 toolset that deploys NetScaler (ADC / Gateway) configuration through the **NITRO REST API** from JSON files, instead of typing CLI commands over SSH.

- **Declarative JSON configs**: one file per area (certificates, LB, AAA, Gateway, ...)
- **Certificates**: upload, create, link to CA, bind, in-place renewal, swap on vservers with rollback
- **Objects**: any NITRO resource, safe to re-run (existing objects are skipped)
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
│   └── Undo-NsObjects.ps1         removes a previous deployment using its journal
├── templates/                     all supported patterns, every step disabled ("skip": true)
│   ├── certs-template.json
│   └── objects-template.json
├── examples/                      a complete, generic StoreFront + SAML Gateway setup
│   ├── 01-certs-example.json
│   ├── 02-lb-storefront.json
│   ├── 03-aaa-saml.json
│   └── 04-gateway.json
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

The four files in `scripts/` must stay together: every script loads `NetScalerNitro.psm1` from its own folder.

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
| `-SkipCertificateCheck` | all | Accept the NetScaler's self-signed management certificate |
| `-NoProxy` | all | Connect directly, bypassing the system/corporate proxy |
| `-NoSave` | all | Don't run `save ns config` (a reboot reverts the changes) |
| `-Backup` | deploy scripts | Create a system backup before changing anything |
| `-ContinueOnError` | deploy scripts | Keep going after a failed step |
| `-NoRollback` | `Deploy-NsObjects` | Keep partial changes after a failure (for troubleshooting) |
| `-SyncHaFiles` | `Deploy-NsCertificates` | `sync ha files ssl` after uploading certificates |

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
- `-SkipCertificateCheck` is for labs. In production, give the management interface a trusted certificate.
- Keep management traffic off web proxies (`-NoProxy` or a proxy exception), so credentials never pass an inspecting proxy.
