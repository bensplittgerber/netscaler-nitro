# Rollback and undo

`Deploy-NsObjects.ps1` records every object and binding **it created** in a journal. Objects that already existed (`[EXISTS]`) are never recorded, so neither rollback nor undo can remove configuration that was there before.

## Automatic rollback

If a step fails, all changes of that run are removed in reverse order and the config is **not saved**:

```
[FAILED]  sslvserver_sslcertkey_binding  [lb_web]  -> 1540: Certificate does not exist

# ROLLBACK: removing 14 change(s) made by this run
  [OK]      remove lbvserver_service_binding [lb_web] servicename:svc_web01
  ...
  Running config was NOT saved.
```

Fix the cause and run the file again. Use `-NoRollback` to keep the partial state for troubleshooting (still not saved).

## Journal

After a successful run that created something, the journal is written to:

```
scripts/journals/<config-name>-<yyyyMMdd-HHmmss>.json
```

The output ends with the matching undo command. No journal is written for `-WhatIf` runs, failed runs (they are rolled back) or runs where everything already existed.

## Undo

```powershell
./scripts/Undo-NsObjects.ps1 -Journal ./scripts/journals/<file>.json -SkipCertificateCheck -WhatIf
./scripts/Undo-NsObjects.ps1 -Journal ./scripts/journals/<file>.json -SkipCertificateCheck
```

- Entries are removed in reverse order.
- Bindings whose parent object is removed in the same undo are skipped (`[SKIP]`), since deleting a vserver removes its bindings.
- Objects that no longer exist are reported as `[GONE]` and count as done, so an undo can be re-run.
- After a complete undo, the journal is renamed to `*.undone.json`.
- The config is saved at the end unless `-NoSave` is given.

**Undo in reverse deployment order** when files depend on each other, e.g. Gateway → AAA → LB. An authentication profile cannot be removed while a Gateway still uses it.

## What is not reversed (`[MANUAL]`)

- Steps with `"action"` (e.g. `enable ns feature`)
- Updates with `"method": "PUT"` (`set ...`)

Usually harmless: if the object was created by the same run, deleting it removes those settings too. Settings applied to pre-existing objects must be reverted by hand.

## Certificates

`Deploy-NsCertificates.ps1` does not write journals. A failed `replace` re-binds the previous certificate automatically. New certkeys are left in place; they have no effect until bound.

## Verify after undo

```
diff ns config
```

An empty diff means the running config matches the saved one.

## Journals and snapshots

If you revert a VM snapshot, delete the journals written after the snapshot. They describe objects that no longer exist.
