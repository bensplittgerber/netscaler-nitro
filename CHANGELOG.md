# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/), versioning based on [SemVer](https://semver.org/).

## [Unreleased]

### Added
- `examples/09-netscaler-monitoring.json` + `docs/monitoring.md` (optional): remote TCP syslog at INFORMATIONAL and one
  audit messageaction line per successful Gateway logon with a client certificate (serial, issuer, subject, IdP user;
  never a token), via a NOREWRITE rewrite policy with goto NEXT on the selected Gateway. Adds its own global syslog
  policy next to existing logging. Parsing and inventory correlation: pki-monitoring.
- Global bindings (`*global_*_binding`, e.g. `auditsyslogglobal_auditsyslogpolicy_binding`): lookup before add with
  `GET <resource>`, journal by `policyname`, undo with `DELETE <resource>?args=policyname:<p>` (no name in the path).
  Regression test in `tests/Test-NsObjects.ps1` (an existing customer syslog binding is kept).

## [1.4.0] - 2026-11-14

### Added
- `scripts/Deploy-NsSite.ps1` + `examples/site.example.json` + `docs/end-to-end.md`: empty ESXi host to a working
  Gateway in one run, driven by one site file - new VPX with netscaler-vpx-deploy, base files, certificates
  (`Deploy-NsCertificates.ps1` or waiting for netscaler-acme), object files; key pinned on first contact, all
  prompts before the first change, the nsroot login proven (asked again on a typo) before the first NITRO phase,
  `-WhatIf`, `-SkipVpx`, `-From` to resume, `-Credential` for an unattended run; `nsip` may also be a URL with
  another port. Validated end to end on an empty lab ESXi host with a new VPX (14.1-73.58): Vpx -> Base ->
  Certificates (files, incl. client CA chains and CRL first copies) -> StoreFront LB -> Gateway -> SSL hardening ->
  mTLS (3 client CA chains, CRLs Valid); a re-run of the objects found every object before add.
- `tests/Test-NsSite.ps1` (8 cases against a fake NITRO API over TLS and a stub of `Deploy-NsVpx.ps1`: dry run,
  site file checks before any prompt, full run with the key pinned on first contact, certificate file list +
  `files` upload, `-SkipVpx -From`, wrong pin, wrong login, acme mode).
- `examples/00-prereq.json` enables the features the examples need (LB, SSL, SSLVPN, AAA, REWRITE, RESPONDER). A
  fresh 14.1 VPX has all features off: the vservers were created but did not serve (VIP answers ping, 443 closed) -
  found with the first end-to-end run on a new VPX.
- `-NsIp` on `Deploy-NsObjects.ps1`, `Deploy-NsCertificates.ps1` and `Invoke-NsDeployment.ps1`: replaces the `nsip` of
  the file(s), so the same files can be deployed to several appliances; the journal records the address used.
- `examples/08-mtls-client-ca.json` + `examples/01-certs-client-ca.json` (optional): client certificates on the
  Gateway - certificate Mandatory, two client CA chains (root + issuing), CRL check Mandatory, CRLs created from an
  uploaded first copy in `/var/netscaler/ssl` (a path outside it: 1650), switched to HTTP refresh and refreshed once
  (`interval` `NOW`, otherwise `Undefined` until the first scheduled refresh). An example policy to show the automation.
- `Deploy-NsCertificates.ps1`: optional `files` list - more files (default `/nsconfig/ssl`, per file `location`, e.g. the first copy of a CRL into `/var/netscaler/ssl`),
  uploaded before the certificates and always overwritten. `certificates.file` of a site file may be a list.
- `sslcrl` keyed by `crlname` (step label, lookup before add, undo).

### Changed
- `examples/00-prereq.json`: `pol_cert_deploy` is marked as an example policy only (narrow it to what your
  certificate tool runs).

## [1.3.1] - 2026-11-12

### Added
- `scripts/Invoke-NsLasLicense.ps1`: offline LAS licensing (Fixed Bandwidth) via NITRO, on the shared module.
  `-Action Status` (default, read-only) checks `show ns license` + `show ns laslicense` on many appliances
  (`-NsIp` list, one pin for all or one per appliance), goes on with the next one when an appliance cannot be read,
  prints a summary table and returns exit code 1 when a license is below `-WarnDays` (default 30; the smaller of
  the `show ns laslicense` and `show ns license` day counters, which can differ), LAS mode has no
  active LAS license, or an appliance was not readable; `-PassThru` returns the result objects.
  `-Action Request` creates the activation request (`-UseHostname`) and downloads it; `-Action Activate` uploads
  the activation file from Citrix Cloud, applies it with `-fixedBandwidth` and, with `-Reboot`, saves, reboots
  warm, waits and shows the licensing mode (refuses an HA primary unless `-Force`). Request / Activate work on one
  appliance at a time and support `-WhatIf` / `-Confirm`. Same NITRO calls as the single-VPX flow in
  netscaler-vpx-deploy (`-LasRequest` / `-LasActivate`).
- `tests/Test-NsLasLicense.ps1` (10 cases against a fake NITRO API with several appliances), `docs/las-licensing.md`.

## [1.3.0] - 2026-11-12

### Added
- `scripts/Update-NsFirmware.ps1`: firmware upgrade of one node via NITRO. Build onto the node with `scp`
  (`-BuildFile`, size checked with the `/var/nsinstall` listing) or downloaded by the NetScaler itself
  (`-BuildUrl`), SHA256 check, system backup, NITRO pre-check (`-PreCheckOnly`; the result file is read, any
  warning stops the run), async install followed via `nsjob`, NITRO reboot, wait and verify the new build. Keeps
  the old kernel on `/flash` by default (`-DeleteOldKernels` = `answeryestoall`), refuses an HA primary (secondary
  first, then `force ha failover`) and an unsaved running config (`-SaveConfig`, or `-IgnoreUnsavedConfig` = NITRO
  `ignoreUnsavedConfig`), `-WhatIf` only reads. The job poll logs in again when the installer restarts the web
  services. Verified 14.1 -> 73.58 on a lab HA pair (manual flow) and with the script on standalone VPX on ESXi
  and KVM, two nodes in parallel (README screenshot).
- `tests/Test-NsFirmware.ps1` (11 cases against a fake NITRO API), `docs/firmware-upgrade.md`.
- Troubleshooting: "OAuth / OIDC" section. After an `authenticationoauthaction` deploy, `OAuth Status: COMPLETE`
  means the JWKS endpoint was fetched.

### Changed
- Docs: the built-in cache policies that NetScaler binds by itself (reported as `[EXISTS]`) appear on
  authentication (AAA) vservers too, not only on VPN vservers (README, note in `examples/04-gateway.json`).

## [1.2.1] - 2026-10-25

### Added
- README screenshot gallery (`docs/screenshots/`): one-flow deploy, dry run, re-run, certificate add / renew /
  replace, rollback, undo - real runs on a NetScaler 14.1 lab HA pair, which also verified the 1.2.0 lookups and
  undo order on a device.
- MIT license (`LICENSE`).

### Fixed
- `[EXISTS]` lookup for `sslprofile_sslcipher_binding` did not match on a real NetScaler (found in the 1.2.0 device
  check on 14.1): GET returns the bound cipher group as `cipheraliasname`, the step uses `ciphername`. A re-run sent
  the binding anyway (NetScaler refused it, so no journal entry - but `-WhatIf` showed `What if`). The lookup now
  accepts `cipheraliasname` for `ciphername`; the offline test checks that a re-run sends no add/bind at all.

### Changed
- `.gitignore` ignores everything in `configs/` except `.gitkeep` (like `certs/`), so real environment configs
  (IPs, host names) in a clone cannot be committed by accident.

## [1.2.0] - 2026-10-23

### Fixed
- Re-runs journaled pre-existing objects as created (F11): NetScaler 14.1 answers some re-adds with success instead
  of `already exists` (seen on `authenticationpolicylabel` and `vpnvserver_*` policy bindings), so they were shown as
  `[OK]` and an undo from that journal removed configuration the run never created. `Deploy-NsObjects.ps1` now looks
  up every add/bind step first (`GET`, bindings matched on their policy/service/certkey/monitor/cipher argument):
  found = `[EXISTS] (found before add)`, not sent, not journaled. Steps without a usable key behave as before.
  Journals of re-runs written by 1.1.0 or older: see docs/troubleshooting.md.
- Undo/rollback skipped a binding whenever its parent object was removed later, even if the binding referenced
  another removed object that goes first: an SSL profile + cipher group created in one run failed to undo
  (`Cipher group has bound entities`). Such bindings are now removed explicitly before that object.
- Undo keys for `sslcipher` (`ciphergroupname`) and `ciphername` / `portaltheme` / `urlname` / `lbvserver` as binding
  delete arguments (cipher group, SSL profile cipher, portal theme, bookmark and CS default-LB bindings).
- `vpnurl` (bookmark) had no key: the step label showed no name, `[EXISTS]` lookup did not work and undo left the
  bookmark behind (`not reversed automatically: vpnurl (no key found)`). Key is now `urlname`.

### Added
- `-WhatIf` uses the same read-only lookups: a dry run shows `[EXISTS]` for what is already there and
  `What if` only for what would really be created.
- A run that created nothing says so ("No journal written: this run created nothing.").
- `tests/Test-NsObjects.ps1`: offline test against a fake NITRO API (dry run, partial deploy, re-run, undo).
- `examples/00-prereq.json`: host name, DNS servers, NTP server + sync.
- `examples/02-lb-storefront.json`: HTTP monitor on the StoreFront web page (`service_lbmonitor_binding`).
- `examples/05-ssl-hardening.json`: cipher group with forward secrecy + AEAD only, bound to the frontend SSL profile;
  strict HTTP profile with WebSocket on the Gateway.
- `examples/06-callback.json`: optional dedicated StoreFront callback vserver, how to test it.
- `examples/07-authorization.json`: authorization policies through an AAA group + `defaultauthenticationgroup`
  (14.1 binds authorization policies only to AAA users/groups, NITRO error 1232 otherwise).
- Docs: CLI-to-NITRO table and undo keys for the new resource types; troubleshooting for HTTP CRLs without a
  local file, session tickets vs. client-certificate factors, STA `DOWN` right after vserver creation, callback
  tests; link to netscaler-rdp-proxy-oidc.
- Step labels show the value for `dnsnameserver`, `ntpserver` and `nshostname`.

## [1.1.0] - 2026-10-17

Validated end to end on a fresh NetScaler VPX 14.1 (build 73.46): deploy, re-run, undo, one-flow rebuild from a
VM snapshot, StoreFront LB + Gateway with Microsoft Entra ID (OIDC) and FAS.

### Added
- `-PinnedPublicKey 'sha256//...'` on all scripts: only the pinned management certificate key is accepted, checked on
  every request (works with the self-signed certificate; replaces `-SkipCertificateCheck`). Same value as
  `acme-ns pin` / `curl --pinnedpubkey`. `Get-NitroPin` reads it. Needs PowerShell 7.2+.
- `scripts/Invoke-NsDeployment.ps1`: runs several object files in order, stops at the first failure, prompts the
  listed `${env:...}` secrets once (masked) and removes them afterwards, skips files with only `skip: true` steps.
- `examples/00-prereq.json`: default SSL profile via NITRO (no Y/N prompt) and a least-privilege certificate user.
- `examples/00-network.json`: optional static routes, VLAN, interface, SNIP (all steps `skip: true`).
- `examples/03-aaa-oidc-entra.json`: Microsoft Entra ID via OIDC as an alternative to the SAML example (metadata URL,
  RS256 only, PKCE, non-addressable AAA vserver, same profile name for `04-gateway.json`).
- Docs: fresh-appliance prerequisites, management certificate trust options, one-flow usage, undo key rules.

### Fixed
- Undo and step labels use one key per resource type: `systemuser` objects were journaled as `[MANUAL]` (no key) and
  `systemuser_systemcmdpolicy_binding` was keyed by the policy instead of the user, so a rollback sent a wrong DELETE.
  Also `systemgroup`/`aaagroup` (groupname), `vlan` (id), `nsip` (ipaddress); routes are labelled and stay `[MANUAL]`.
- No journal is written when a run only changed `[MANUAL]` settings (re-runs no longer leave empty-undo journals).

### Changed
- `examples/04-gateway.json`: HSTS `preload` and `includeSubDomains` off (preload commits the whole parent domain).

## [1.0.0] - 2026-10-15

First documented release. Used for a full NetScaler 14.1 migration; tested on Windows and Ubuntu (PowerShell 7).

### Added
- `NetScalerNitro.psm1`: shared module with NITRO login/logout, request handling, result reporting, backup, save, HA file sync, rollback helpers.
- `Deploy-NsCertificates.ps1`: upload cert/key/PFX, create certkey, link to CA, bind to vservers.
  - `"update": true` for in-place renewal (`update ssl certKey`, bindings are kept).
  - `"bindTo"` + `"replace": true` swaps the bound server certificate, with automatic re-bind of the old one if the new bind fails.
  - Detects when a certificate is already installed under a different certkey name.
- `Deploy-NsObjects.ps1`: JSON "steps" for any NITRO resource; `action`, `method`, `skip`, `note`.
  - Automatic rollback of all changes of the run on failure; config is not saved in that case.
  - Journal per successful run (`scripts/journals/`).
- `Undo-NsObjects.ps1`: removes exactly what a deployment created, using its journal.
- `${env:NAME}` placeholders for secrets in config files.
- Switches `-WhatIf`, `-NoSave`, `-Backup`, `-SkipCertificateCheck`, `-NoProxy`, `-ContinueOnError`, `-NoRollback`, `-SyncHaFiles`.
- Templates covering LB, CS, rewrite/responder, SSL, AAA (LDAP, RADIUS, SAML, OAuth, cert, nFactor) and Gateway.

### Fixed (during testing, before 1.0.0)
- Connection and TLS errors inside the module now stop the run (previously the script continued after a failed login).
- Invalid JSON gives a clear error with the file name instead of a misleading "nsip is empty".
- Undo skips bindings whose parent object is removed in the same undo (avoids "Invalid argument" on some binding types).
- Undo treats already-removed objects as done (`does not exist`, `No such ...`, `not found`), so an undo can be re-run safely.
- Journal rename after a successful undo.
- Both deploy scripts refuse a config meant for the other script before connecting (nothing is changed or saved).
