#Requires -Version 7.0
<#
.SYNOPSIS
    Uploads SSL certificates to NetScaler (14.1) via NITRO, creates/updates certkeys, links and binds them.

.DESCRIPTION
    For each entry in "certificates" of the config file:
      1. uploads cert + key (PEM/DER) or a PFX to /nsconfig/ssl
      2. creates the sslcertkey object
         - if it already exists and "update": true -> runs "update ssl certKey" (renewal, bindings are kept)
      3. links it to its CA ("linkTo")
      4. binds it to existing vservers ("bindTo": LB, Gateway, AAA, CS ... any SSL vserver)
         - with "replace": true the currently bound server cert is unbound first
           (re-bound automatically if the new bind fails)

    Run this BEFORE Deploy-NsObjects.ps1 for new deployments (the objects can then bind the certkey by name),
    or on its own for renewals.

.EXAMPLE
    $env:PFX_PASS = 'xxx'
    ./Deploy-NsCertificates.ps1 -ConfigFile ./certs.json -SkipCertificateCheck -WhatIf
.EXAMPLE
    ./Deploy-NsCertificates.ps1 -ConfigFile ./certs.json -Credential (Get-Credential nsroot) -Backup -SyncHaFiles
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [pscredential]$Credential,
    [switch]$SkipCertificateCheck,
    [switch]$NoProxy,
    [switch]$Backup,
    [switch]$NoSave,
    [switch]$SyncHaFiles,
    [switch]$ContinueOnError
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetScalerNitro.psm1') -Force

$loaded = Import-NitroConfig $ConfigFile
$cfg    = $loaded.Config
if (-not @($cfg.certificates).Where({ $_ }).Count) {
    $hint = if ($cfg.steps) { " It contains 'steps' - use Deploy-NsObjects.ps1 for this file." } else { '' }
    throw "Config file '$ConfigFile' has no 'certificates' entries - nothing to do, nothing was changed or saved.$hint"
}
if (-not $Credential) { $Credential = Get-Credential -Message 'NetScaler NITRO login' }
$sslDir = '/nsconfig/ssl'

function Send-NsFile([string]$LocalPath, [bool]$Overwrite) {
    $full = if ([IO.Path]::IsPathRooted($LocalPath)) { $LocalPath } else { Join-Path $loaded.Dir $LocalPath }
    if (-not (Test-Path $full)) { throw "File not found: $full" }
    $name  = Split-Path -Leaf $full
    $label = "upload $name -> $sslDir"
    if (-not $PSCmdlet.ShouldProcess($label, 'POST systemfile')) { return $name }

    $body = @{ systemfile = @{
        filename     = $name
        filelocation = $sslDir
        filecontent  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($full))
        fileencoding = 'BASE64'
    } }
    $r = Invoke-Nitro -Method POST -Resource 'systemfile' -Body $body
    if ($r.ErrorCode -ne 0 -and $r.Message -match 'exist' -and $Overwrite) {
        $args = 'filelocation:' + [uri]::EscapeDataString($sslDir)
        [void](Invoke-Nitro -Method DELETE -Resource "systemfile/$name" -Query @{ args = $args })
        $r = Invoke-Nitro -Method POST -Resource 'systemfile' -Body $body
        $label += ' (overwritten)'
    }
    [void](Write-NitroResult $label $r -ContinueOnError:$ContinueOnError)
    return $name
}

function Invoke-CertCall([string]$Method, [string]$Resource, [string]$Action, [hashtable]$Data, [string]$Label) {
    if (-not $PSCmdlet.ShouldProcess($Label, $Method)) { return 'whatif' }
    $q = if ($Action) { @{ action = $Action } } else { $null }
    $r = Invoke-Nitro -Method $Method -Resource $Resource -Query $q -Body @{ $Resource = $Data }
    Write-NitroResult $Label $r -ContinueOnError:$ContinueOnError
}

function Set-CertBinding([string]$VServer, [string]$CertKey, [bool]$Replace) {
    $vsEsc = [uri]::EscapeDataString($VServer)
    $toRemove = @()

    if ($Replace) {
        # find server certs (not CA, not SNI) currently bound to the vserver
        $g = Invoke-Nitro -Method GET -Resource "sslvserver_sslcertkey_binding/$vsEsc"
        if ($g.ErrorCode -ne 0) {
            [void](Write-NitroResult "read cert bindings of $VServer" $g -ContinueOnError:$ContinueOnError)
            return
        }
        $toRemove = @($g.Data.sslvserver_sslcertkey_binding |
            Where-Object { $_.certkeyname -and "$($_.ca)" -ne 'true' -and "$($_.snicert)" -ne 'true' } |
            ForEach-Object { $_.certkeyname })
        if ($toRemove -contains $CertKey) {
            Write-Host "  [EXISTS]  bind $CertKey -> $VServer  (already bound)" -ForegroundColor Yellow
            return
        }
        if ($toRemove.Count -eq 0) { Write-Host "  [INFO]    $VServer has no server cert bound, nothing to replace" }
    }

    # unbind the old cert(s)
    $removed = @()
    foreach ($old in $toRemove) {
        $label = "unbind $old from $VServer"
        if (-not $PSCmdlet.ShouldProcess($label, 'DELETE')) { continue }
        $r = Invoke-Nitro -Method DELETE -Resource "sslvserver_sslcertkey_binding/$vsEsc" `
                          -Query @{ args = 'certkeyname:' + [uri]::EscapeDataString($old) }
        if ((Write-NitroResult $label $r -ContinueOnError:$ContinueOnError) -eq 'ok') { $removed += $old }
    }

    # bind the new cert; on failure put the old one(s) back
    $label = "bind $CertKey -> $VServer"
    if (-not $PSCmdlet.ShouldProcess($label, 'PUT')) { return }
    $r = Invoke-Nitro -Method PUT -Resource 'sslvserver_sslcertkey_binding' `
                      -Body @{ sslvserver_sslcertkey_binding = @{ vservername = $VServer; certkeyname = $CertKey } }
    if ($r.ErrorCode -ne 0 -and $r.Message -notmatch 'already' -and $removed.Count -gt 0) {
        Write-Host "  [ROLLBACK] bind of $CertKey failed, rebinding previous cert" -ForegroundColor Red
        foreach ($old in $removed) {
            $rb = Invoke-Nitro -Method PUT -Resource 'sslvserver_sslcertkey_binding' `
                               -Body @{ sslvserver_sslcertkey_binding = @{ vservername = $VServer; certkeyname = $old } }
            [void](Write-NitroResult "rebind $old -> $VServer" $rb -ContinueOnError)
        }
    }
    [void](Write-NitroResult $label $r -ContinueOnError:$ContinueOnError)
}

Connect-Nitro -NsIp $cfg.nsip -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck -NoProxy:$NoProxy
try {
    if ($Backup -and $PSCmdlet.ShouldProcess('system backup', 'create')) { [void](New-NitroBackup) }

    foreach ($c in $cfg.certificates) {
        Write-Host "`n# $($c.name)" -ForegroundColor Cyan
        $ow = [bool]$c.overwrite

        # 1. upload files + build certkey definition
        if ($c.pfxFile) {
            $ck = @{ certkey = $c.name; cert = (Send-NsFile $c.pfxFile $ow); inform = 'PFX' }
        } else {
            $ck = @{ certkey = $c.name; cert = (Send-NsFile $c.certFile $ow) }
            if ($c.keyFile) { $ck.key = Send-NsFile $c.keyFile $ow }
        }
        if ($c.password) { $ck.passplain = $c.password }

        # 2. create, or update in place for renewals
        $status = Invoke-CertCall POST 'sslcertkey' $null $ck "add certkey $($c.name)"

        # "exists" can also mean: the same certificate is already installed under ANOTHER certkey name.
        # Then this certkey was never created -> stop here instead of failing later at link/bind.
        if ($status -eq 'exists') {
            $chk = Invoke-Nitro -Method GET -Resource "sslcertkey/$([uri]::EscapeDataString($c.name))"
            if ($chk.ErrorCode -ne 0) {
                Write-Host "  [FAILED]  certkey $($c.name) was not created: this certificate is already installed under another certkey name (see message above). Use that name, or deploy a new certificate." -ForegroundColor Red
                if (-not $ContinueOnError) { throw "Duplicate certificate: $($c.name)" }
                continue
            }
        }
        if ($status -eq 'exists' -and $c.update) {
            $upd = $ck.Clone(); $upd.nodomaincheck = $true
            [void](Invoke-CertCall POST 'sslcertkey' 'update' $upd "update certkey $($c.name)")
        }

        # 3. link to CA
        if ($c.linkTo) {
            [void](Invoke-CertCall POST 'sslcertkey' 'link' @{ certkey = $c.name; linkcertkeyname = $c.linkTo } `
                   "link $($c.name) -> $($c.linkTo)")
        }

        # 4. bind to existing vservers ("replace": true swaps out the currently bound server cert)
        foreach ($vs in @($c.bindTo)) {
            if (-not $vs) { continue }
            Set-CertBinding -VServer $vs -CertKey $c.name -Replace ([bool]$c.replace)
        }
    }

    Write-Host ''
    if (-not $NoSave -and $PSCmdlet.ShouldProcess('running config', 'save ns config')) { [void](Save-NitroConfig) }
    if ($SyncHaFiles -and $PSCmdlet.ShouldProcess('HA secondary', 'sync ha files ssl')) { [void](Sync-NitroHaFiles -Mode ssl) }
}
finally {
    Disconnect-Nitro
}
