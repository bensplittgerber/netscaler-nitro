# Offline LAS licensing (Fixed Bandwidth)

`scripts/Invoke-NsLasLicense.ps1` covers the offline License Activation Service (LAS) flow over NITRO, for a
NetScaler without internet access to LAS that is licensed with a Fixed Bandwidth subscription. Same steps as the GUI
(License > ADC License > LAS Activation), plus a read-only status check for many appliances. The NITRO login works
like the other scripts: `-Credential` or a prompt (one login for all appliances), `-PinnedPublicKey`, CA trust or
`-SkipCertificateCheck`, `-NoProxy`.

Observed on NetScaler 14.1 builds 73.46, 73.49 and 73.58 (VPX). This is not documented by NetScaler in this form and
may change with later builds.

| Action | Appliances | Changes |
|---|---|---|
| `Status` (default) | one or many `-NsIp` | nothing (read-only) |
| `Request` | one | creates the request file under `/nsconfig/license` (and on the first request the activation key pair) |
| `Activate` | one | uploads + applies the activation file; `-Reboot`: save, warm reboot |

`Request` and `Activate` support `-WhatIf` (shows what it would do, no login) and `-Confirm`.

## Status (read-only, many appliances)

```powershell
./scripts/Invoke-NsLasLicense.ps1 -NsIp https://192.0.2.10, https://192.0.2.11, https://192.0.2.20 -WarnDays 45
```

```
  [OK]      https://192.0.2.10  mode LAS (Fixed Bandwidth), model 5000, LAS ACTIVE, 427 days, renewal Sun Dec 26 10:04:12 2027
  [ERROR]   https://192.0.2.11  Login failed: Invalid username or password
  [WARN]    https://192.0.2.20  mode LAS (Fixed Bandwidth), model 5000, LAS ACTIVE, 12 days, renewal Tue Nov 24 08:30:00 2026 (below 45 days)

LAS license status (3 appliance(s), warn below 45 days):

NsIp               Result LicensingMode         ModelId LasStatus Days RenewalNext              Note
----               ------ -------------         ------- --------- ---- -----------              ----
https://192.0.2.10 OK     LAS (Fixed Bandwidth) 5000    ACTIVE     427 Sun Dec 26 10:04:12 2027
https://192.0.2.11 ERROR                                                                        Login failed: Invalid username or password
https://192.0.2.20 WARN   LAS (Fixed Bandwidth) 5000    ACTIVE      12 Tue Nov 24 08:30:00 2026 below 45 days

2 of 3 need attention (WARN/ERROR) - exit code 1.
```

Per appliance: `show ns license` (licensing mode, model) and `show ns laslicense` (LAS status, days to expiration,
next renewal). An appliance that cannot be read (no answer, TLS/pin mismatch, login, NITRO error) is reported as
`ERROR` and the run goes on with the next one.

| Result | Meaning | Exit code |
|---|---|---|
| `OK` | LAS ACTIVE, at least `-WarnDays` days left | 0 |
| `WARN` | LAS ACTIVE but fewer than `-WarnDays` days left (or the days are not readable), or LAS mode without an active LAS license | 1 |
| `ERROR` | not readable | 1 |
| `NO-LAS` | not licensed through LAS (e.g. Express, pooled) - information only | 0 |

- Days: NetScaler has two counters, `show ns laslicense` DaysToExpiration and `show ns license` "Days to
  expiration". They can differ (seen 415 vs 353 on 14.1-73.58, the smaller one matching Renewalnextdate). The script
  uses the smaller one and shows both when they differ: `353 days (license 353, laslicense 415)`.
- `-WarnDays` (default 30): use it as the renewal reminder, the next request has to go through Citrix Cloud before
  the current activation runs out.
- `-PassThru` returns the result objects (`NsIp, Result, LicensingMode, ModelId, LasStatus, DaysToExpiration,
  LasDays, LicenseDays, RenewalNext, Note`), e.g. `| Export-Csv` or `| ConvertTo-Json` for monitoring.
- `-PinnedPublicKey`: one pin for all appliances (an HA pair with a synced management certificate) or one pin per
  `-NsIp`, in the same order. Get a pin with `Get-NitroPin` (module) and compare it out of band.
- HA pair: the license belongs to each node. Check both NSIPs, not the floating SNIP.

## Request -> Citrix Cloud -> activation

```powershell
# 1. request: show ns licenseactivationdata + download from /nsconfig/license
./scripts/Invoke-NsLasLicense.ps1 -NsIp https://192.0.2.10 -Action Request -OutDir . -PinnedPublicKey 'sha256//...'

# 2. Citrix Cloud > Licensing > NetScaler licenses > NetScaler ADC: upload the request, download the activation file

# 3. activation: add system file + apply ns laslicense -fixedBandwidth, save, warm reboot, show the result
./scripts/Invoke-NsLasLicense.ps1 -NsIp https://192.0.2.10 -Action Activate `
    -ActivationFile ./NS_<id>_activation.blob.tgz -Reboot -PinnedPublicKey 'sha256//...'
```

| CLI | NITRO (what the script sends) |
|---|---|
| `show ns licenseactivationdata [-useHostname]` | `GET nslicenseactivationdata[?args=usehostname:true]` -> `filename` |
| download the request | `GET systemfile/<file>?args=filelocation:%2Fnsconfig%2Flicense` (base64 `filecontent`) |
| `add system file <file> -fileLocation /nsconfig/license` | `POST systemfile` (base64; an older copy with the same name is deleted first) |
| `apply ns laslicense -fileName <file> -fileLocation /nsconfig/license -fixedBandwidth` | `POST nslaslicense?action=apply`, `fixedbandwidth: true` |
| `show ns laslicense`, `show ns license`, `show ha node` | `GET nslaslicense`, `GET nslicense`, `GET hanode` |
| `save ns config`, `reboot -warm` | `POST nsconfig?action=save`, `POST reboot` with `warm: true` |

- `Request -UseHostname` names the appliance by its host name in Citrix Cloud (GUI toggle "Use hostname"); the
  identifier stays the same. The script prints host name, identifier, build and last activation id from the request.
- `Activate` without `-Reboot` imports and applies the file: `show ns laslicense` is ACTIVE right away, the
  licensing mode changes with the next reboot (do it in a maintenance window).
- `Activate -Reboot` saves the config, sends `reboot -warm`, waits until the appliance has gone down and NITRO takes
  a login again (`-PollSeconds`, default 20; `-TimeoutMinutes`, default 15) and shows the licensing mode. On an HA
  primary it stops before anything is uploaded (the reboot fails over to the peer) unless `-Force`; activate the
  secondary first, fail over, then the other node.

## What to know

- The **request** (`<id>_activation_request.tgz`, or `<host name>_activation_request.tgz` with `-UseHostname`)
  contains no secrets: an identifier derived from the Host Id (`show ns hardware`, the MAC of interface 0/1), the
  build, the request time and the public key of a key pair the NetScaler creates on its first request
  (`/nsconfig/license/las_key_pair/`, reused for later requests). The GUI shows an expiry of 7 days for the request.
- On a licensed appliance a new request also carries the last activation id (renewal / rehost in Citrix Cloud).
- The **activation file** is signed by Citrix and names the identifier, the products and the validity.
- It applies only on the NetScaler that created the request. Anywhere else: `License blob is invalid: blob not
  applicable for this LPEID` (the script then stops and says so). A key pair copied from another VM is not accepted
  (the NetScaler creates a new one).
- `apply ns laslicense` without `-fixedBandwidth` fails with `Failed to parse las license file`.
- `show ns laslicense` is ACTIVE right after the import; the licensing mode (`show ns license`) switches to
  "LAS (Fixed Bandwidth)" after a reboot.
- A `system backup` of a licensed appliance contains the activation key pair (private key): store it like a PFX.

## Rebuilt or moved VPX

A rebuilt VPX keeps an offline activation only with the old VM's identity (same MAC on interface 0/1, same BIOS
UUID) and a restored full system backup; otherwise create a new request and activate it in Citrix Cloud. On VMware
ESXi, [netscaler-vpx-deploy](https://github.com/bensplittgerber/netscaler-vpx-deploy) reads the identity of the old
VM (`-ShowIdentity`) and deploys the new one with it (`-MacAddress`, `-BiosUuid`); its `docs/vmware.md` has the
validated rebuild steps. Never run two VMs with the same identity.

The activation does **not** move to another hypervisor (seen ESXi -> KVM with the same MAC, UUID and a restored
backup): the platform id changes and the VPX drops to Express. Path: new request on the new VPX (it carries the last
activation id), Citrix Cloud, `-Action Activate`.

netscaler-vpx-deploy keeps its own minimal `-LasRequest` / `-LasActivate` for a single VPX right after the deploy;
this script is the day-2 tool (status of many appliances, any hypervisor or MPX/SDX instance reachable by NITRO).
