# Changelog

All notable changes to this project. Format based on [Keep a Changelog](https://keepachangelog.com/), versioning based on [SemVer](https://semver.org/).

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
