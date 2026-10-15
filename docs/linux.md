# Running on Linux

The scripts run unchanged on Linux with PowerShell 7 (tested on Ubuntu).

## Install PowerShell

```bash
sudo snap install powershell --classic
pwsh --version
```

(or Microsoft's package repository for your distribution)

## Differences to Windows

| Topic | Linux |
|---|---|
| File names | Case-sensitive: `NetScalerNitro.psm1` must match exactly |
| Paths in configs | Use Linux paths (`/data/certs/x.crt` or relative `../certs/x.crt`) |
| `.cred.xml` from Windows | Not usable (Windows DPAPI). Prompt interactively or use environment variables |
| Execution policy / `Unblock-File` | Not needed |
| Line endings | CRLF from Windows is fine |
| Proxy | `HTTP_PROXY` / `HTTPS_PROXY` environment variables are used if set; `-NoProxy` bypasses them |

## Run

```bash
cd netscaler-nitro
pwsh
```

```powershell
./scripts/Deploy-NsObjects.ps1 -ConfigFile ./configs/02-lb.json -SkipCertificateCheck -WhatIf
```

Non-interactive:

```powershell
$cred = [pscredential]::new($env:NS_USER, (ConvertTo-SecureString $env:NS_PASS -AsPlainText -Force))
./scripts/Deploy-NsObjects.ps1 -ConfigFile ./configs/02-lb.json -SkipCertificateCheck -Credential $cred
```

## Containers / OpenShift (outlook)

The same scripts can run in a container based on the official PowerShell image:

- credentials and `${env:...}` secrets from environment variables / Kubernetes Secrets
- `configs/`, `certs/` and the journal directory as mounted volumes (container storage is not persistent)
- a trusted management certificate instead of `-SkipCertificateCheck`
- network access from the pod to the NSIP

Not part of this release.
