# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/), versioning based on [SemVer](https://semver.org/).

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
