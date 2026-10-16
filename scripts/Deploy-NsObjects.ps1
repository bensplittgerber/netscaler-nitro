#Requires -Version 7.0
<#
.SYNOPSIS
    Creates NetScaler (14.1) configuration objects from a JSON file via NITRO, with rollback.

.DESCRIPTION
    Runs the "steps" of the config file in order:
      * normal objects    -> POST /nitro/v1/config/<resource>
      * *_binding objects -> PUT  /nitro/v1/config/<resource>
      * "action": "x"     -> POST /nitro/v1/config/<resource>?action=x
      * "method": "PUT"   -> force a method (e.g. "set ssl vserver ...")
      * "skip": true      -> step is ignored (JSON has no comments - use this to switch steps off)
      * "note": "..."     -> free text, ignored by the script
    Objects that already exist are skipped, so the file can be re-run safely.

    Rollback:
      * Every object/binding CREATED by this run is recorded. Objects that already existed are never recorded,
        so a rollback never removes configuration that was there before.
      * If a step fails, all changes of this run are removed again in reverse order and the config is NOT saved
        (use -NoRollback to keep the partial state for troubleshooting).
      * After a successful run the record is written to .\journals\<config>-<timestamp>.json.
        Undo-NsObjects.ps1 -Journal <file> removes exactly those changes later.
      * "action" steps (e.g. nsfeature enable) and "set"/PUT updates are listed as MANUAL - they are not reversed.

.EXAMPLE
    ./Deploy-NsObjects.ps1 -ConfigFile ./02-lb-storefront.json -SkipCertificateCheck -WhatIf
.EXAMPLE
    ./Deploy-NsObjects.ps1 -ConfigFile ./02-lb-storefront.json -SkipCertificateCheck -Credential (Import-Clixml .\acme-user.cred.xml)
.EXAMPLE
    ./Deploy-NsObjects.ps1 -ConfigFile ./02-lb-storefront.json -PinnedPublicKey 'sha256//<base64 from acme-ns pin>'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [pscredential]$Credential,
    [switch]$SkipCertificateCheck,
    [string]$PinnedPublicKey,
    [switch]$NoProxy,
    [switch]$Backup,
    [switch]$NoSave,
    [switch]$NoRollback,
    [switch]$ContinueOnError
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetScalerNitro.psm1') -Force

$cfg = (Import-NitroConfig $ConfigFile).Config
if (-not @($cfg.steps).Where({ $_.resource }).Count) {
    $hint = if ($cfg.certificates) { " It contains 'certificates' - use Deploy-NsCertificates.ps1 for this file." } else { '' }
    throw "Config file '$ConfigFile' has no 'steps' with a resource - nothing to do, nothing was changed or saved.$hint"
}
if (-not $Credential) { $Credential = Get-Credential -Message 'NetScaler NITRO login' }
$journal = [System.Collections.Generic.List[object]]::new()

function Get-StepLabel($Resource, $Action, $Data) {
    # same key as the journal/undo uses (Get-NitroKey), so label and undo always name the same object
    $k  = if ($Data) { Get-NitroKey -Resource $Resource -Data $Data } else { $null }
    $id = if ($k) { $Data.$k } elseif ($Data.feature) { $Data.feature } else { $null }
    $s = $Resource
    if ($Action) { $s += " ?action=$Action" }
    if ($id)     { $s += "  [$($id -join ',')]" }
    $s
}

function Invoke-Step($Step) {
    if ($Step.comment) { Write-Host "`n# $($Step.comment)" -ForegroundColor Cyan }
    if (-not $Step.resource) { return }
    if ($Step.skip -eq $true) {
        Write-Host "  [SKIP]    $(Get-StepLabel $Step.resource $Step.action $Step.data)  (skip: true)" -ForegroundColor DarkGray
        return
    }

    $res    = $Step.resource
    $action = $Step.action
    $method = if ($action) { 'POST' }
              elseif ($Step.method) { $Step.method.ToUpper() }
              elseif ($res -like '*_binding') { 'PUT' }
              else { 'POST' }
    $label  = Get-StepLabel $res $action $Step.data

    if (-not $PSCmdlet.ShouldProcess($label, $method)) { return }
    $q = if ($action) { @{ action = $action } } else { $null }
    $r = Invoke-Nitro -Method $method -Resource $res -Query $q -Body @{ $res = $Step.data }
    $status = Write-NitroResult $label $r -ContinueOnError:$ContinueOnError
    if ($status -eq 'ok') {
        $journal.Add((Get-NitroUndoEntry -Resource $res -Method $method -Action $action -Data $Step.data))
    }
}

Connect-Nitro -NsIp $cfg.nsip -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck -PinnedPublicKey $PinnedPublicKey -NoProxy:$NoProxy
try {
    if ($Backup -and $PSCmdlet.ShouldProcess('system backup', 'create')) { [void](New-NitroBackup) }

    try {
        foreach ($s in $cfg.steps) { Invoke-Step $s }
    }
    catch {
        if ($journal.Count -gt 0 -and -not $NoRollback) {
            Write-Host "`n# ROLLBACK: removing $($journal.Count) change(s) made by this run" -ForegroundColor Red
            $left = Invoke-NitroUndo -Entries $journal.ToArray()
            if ($left -gt 0) { Write-Host "  $left item(s) could not be removed - check them manually." -ForegroundColor Red }
            Write-Host '  Running config was NOT saved.' -ForegroundColor Red
        } elseif ($NoRollback) {
            Write-Host "`n-NoRollback: partial changes left in the running config (not saved)." -ForegroundColor Yellow
        }
        throw
    }

    Write-Host ''
    if (-not $NoSave -and $PSCmdlet.ShouldProcess('running config', 'save ns config')) { [void](Save-NitroConfig) }

    $undoable = @($journal | Where-Object { $_.type -ne 'manual' })
    if ($journal.Count -gt 0 -and $undoable.Count -eq 0) {
        # F2: a re-run where all add/bind steps were [EXISTS] and only set/action steps ran - nothing an undo could remove
        Write-Host "No journal written: this run changed only settings that undo cannot reverse ($($journal.Count) x MANUAL)." -ForegroundColor DarkGray
    }
    elseif ($journal.Count -gt 0) {
        $dir  = Join-Path $PSScriptRoot 'journals'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir ('{0}-{1}.json' -f [IO.Path]::GetFileNameWithoutExtension($ConfigFile), (Get-Date -Format 'yyyyMMdd-HHmmss'))
        [ordered]@{
            nsip    = $cfg.nsip
            config  = (Resolve-Path $ConfigFile).Path
            created = (Get-Date).ToString('s')
            entries = $journal.ToArray()
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding utf8
        Write-Host "Journal: $file"
        Write-Host "Undo later with: .\Undo-NsObjects.ps1 -Journal `"$file`""
    }
}
finally {
    Disconnect-Nitro
}
