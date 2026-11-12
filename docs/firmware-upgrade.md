# Firmware upgrade

`Update-NsFirmware.ps1` upgrades **one** NetScaler node through NITRO: build onto the node, backup, pre-check,
install, reboot, wait, verify. For an HA pair it runs once per node (secondary first).

```powershell
# upload with scp (scp asks for the nsroot password itself, or use -SshKey), pre-check only
./scripts/Update-NsFirmware.ps1 -NsIp https://192.0.2.11 -BuildFile ~/Downloads/build-14.1-73.58_nc_64.tgz `
    -Sha256 <checksum from the download page> -PinnedPublicKey 'sha256//...' -PreCheckOnly

# the whole upgrade (the upload is skipped when the same file is already on the node)
./scripts/Update-NsFirmware.ps1 -NsIp https://192.0.2.11 -BuildFile ~/Downloads/build-14.1-73.58_nc_64.tgz `
    -Sha256 <checksum> -PinnedPublicKey 'sha256//...'

# or let the NetScaler download the build from an internal web server (no upload from PowerShell)
./scripts/Update-NsFirmware.ps1 -NsIp https://192.0.2.11 -BuildUrl https://files.example.org/netscaler/build-14.1-73.58_nc_64.tgz
```

Connect to the node's own NSIP, not to a floating SNIP: the floating address moves to the other node during a
failover.

## What the script does

| Step | How | Notes |
|---|---|---|
| 1. checksum | `Get-FileHash` | compared with `-Sha256` when given |
| 2. node check | `GET nsversion`, `GET hanode`, `GET nsconfig` | already on the target build: stops, nothing to do. HA **primary**: stops (`-Force` to override). **Unsaved config** (`configchanged`): stops before the upload (`-SaveConfig` saves it before the backup) |
| 3. build onto the node | `-BuildFile`: `scp` to `/var/nsinstall/<file>`, size checked with `GET systemfile?args=filelocation:/var/nsinstall` (listing); `-BuildUrl`: the NetScaler downloads it | NITRO itself cannot upload a 1+ GB build (`systemfile` takes base64 inside JSON). A `GET systemfile` with a file name returns the content and fails with "File too large" for a build, so the script reads the folder listing |
| 4. backup | `systembackup ?action=create` (basic) | `-NoBackup` to skip |
| 5. pre-check | `POST install` with `precheck: true`, then the result file `/var/tmp/install_pre_check.<job>.json` | 14 checks: disk space, saved + synced config, licenses, platform, ... ~30 s. NITRO answers 201 **even with warnings**, so the script reads the result file (newest by time: job ids start over after a reboot) and stops on any warning or failure; `-PreCheckOnly` stops here |
| 6. install | `POST install` with `Async: true` -> job id; `GET nsjob/<id>` until `Success` | ~90 s on a VPX; ends with errorcode 5221 "...will not take effect until the system is rebooted" |
| 7. reboot | `POST reboot` `{ warm: false }` | `-NoReboot` to reboot later yourself |
| 8. verify | login again until NITRO answers on the new build | prints the HA state |

`-WhatIf` runs steps 1-2 only (it reports unsaved config without stopping).

### Unsaved configuration

`show ns config` can say `Config Changed since Last Saved Config: TRUE` while `diff ns config` is empty (a change
that the diff does not show, or one undone by hand). The pre-check only **warns** (`config_unsaved`), but the
installer in API mode then aborts after extracting the build: `Detected configuration changes after the last save.
Error: Installation failed.` (job `Failed`, errorcode 1490, details in `/var/tmp/install`). The script therefore
checks `nsconfig.configchanged` first. Three ways on:

| | What it does | Use when |
|---|---|---|
| `save ns config`, run again | you review `diff ns config` and save | the default |
| `-SaveConfig` | the script saves before the backup | the running config is the one you want to keep |
| `-IgnoreUnsavedConfig` | sends NITRO `ignoreUnsavedConfig: true` with the pre-check and the install (the override the pre-check names for `config_unsaved`); the warning shows as `[IGNORED]` | the "unsaved" flag is a known false alarm (`diff ns config` empty). Unsaved changes are **lost** at the reboot: the node boots from the saved `ns.conf` |

`-SaveConfig` and `-IgnoreUnsavedConfig` exclude each other.

### Old kernel: kept by default

Without `y`, NITRO starts the installer in API mode, which answers **No** to *"Do you wish to delete old rsa keys,
signatures and kernel images?"* and does not reboot. The old kernel stays on `/flash`: the boot loader can still
start it (rollback without reinstalling).

`-DeleteOldKernels` sends `y: true`. NITRO turns that into `-answerYesToAll`: the installer deletes the old kernels,
signatures and RSA keys and reboots by itself. Use it only when `/flash` is short of space.

Do **not** run `install <url> -y` over SSH instead: lower-case `-y` only answers the reboot question, the
installer then waits for the "delete old images" answer on stdin.

## HA pair

```powershell
./scripts/Update-NsFirmware.ps1 -NsIp https://<secondary NSIP> -BuildFile <build> ...
```
```
force ha failover -force          # CLI on the primary
```
```powershell
./scripts/Update-NsFirmware.ps1 -NsIp https://<old primary NSIP> -BuildFile <build> ...
```

- While the nodes run different builds, `show ha node` shows `Sync State` / `Propagation` = `AUTO DISABLED`. After
  the second node is up, sync runs once (`IN PROGRESS`) and returns to `SUCCESS` within a few minutes.
- `force ha failover` warns "HA version mismatch" between the two upgrades. That is expected when the config of both
  nodes is saved.
- The old primary may report unsaved config right after the failover although nothing changed; `save ns config`
  on it (or `-SaveConfig`) and run the script again.
- Fail back afterwards only if something depends on which node is primary.

## Requirements

- 7 GB free in `/var`, 200 MB in `/flash` (the pre-check verifies it). Delete old builds from `/var/nsinstall`.
- `scp.exe` (OpenSSH client, part of Windows 10/11 and every Linux) and SSH (port 22) to the NSIP for `-BuildFile`.
  The first connection asks to confirm the host key.
- Upload time: ~90 s for a 1.2 GB build on a licensed VPX. An unlicensed VPX (Express / Freemium, 20 Mbit/s) is
  capped for all traffic, the NSIP included: ~2.4 MB/s, ~9 min. `-BuildUrl` does not help there (same cap).
- Saved and synced configuration (`save ns config` on the primary).
- A VM snapshot or system backup you can go back to.
