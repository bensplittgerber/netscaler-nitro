#Requires -Version 7.0
<#
.SYNOPSIS
    Removes the objects/bindings a previous Deploy-NsObjects.ps1 run created, using its journal file.

.DESCRIPTION
    Entries are removed in reverse order (bindings before the objects they belong to).
    Only what that run created is removed - objects that already existed at deploy time were never journaled.
    MANUAL entries (actions like "enable ns feature", "set" updates) are listed but not reversed.
    The journal is renamed to *.undone.json afterwards.

.EXAMPLE
    ./Undo-NsObjects.ps1 -Journal .\journals\02-lb-storefront-20261013-223000.json -SkipCertificateCheck -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Journal,
    [pscredential]$Credential,
    [switch]$SkipCertificateCheck,
    [switch]$NoProxy,
    [switch]$NoSave
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetScalerNitro.psm1') -Force

$j       = Get-Content -Raw $Journal | ConvertFrom-Json
$entries = @($j.entries)
Write-Host "Journal: $Journal  (created $($j.created) from $($j.config))"
Write-Host "$($entries.Count) entr(y/ies) to reverse on $($j.nsip):"
for ($i = $entries.Count - 1; $i -ge 0; $i--) {
    $e = $entries[$i]
    if ($e.type -eq 'manual') { Write-Host "  manual : $($e.note)" -ForegroundColor Yellow }
    else                      { Write-Host "  remove : $($e.resource) [$($e.key)]" }
}

if (-not $PSCmdlet.ShouldProcess("$($entries.Count) entries on $($j.nsip)", 'undo')) { return }

if (-not $Credential) { $Credential = Get-Credential -Message 'NetScaler NITRO login' }
Connect-Nitro -NsIp $j.nsip -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck -NoProxy:$NoProxy
try {
    Write-Host "`n# Undo" -ForegroundColor Cyan
    $left = Invoke-NitroUndo -Entries $entries
    Write-Host ''
    if (-not $NoSave) { [void](Save-NitroConfig) }
    if ($left -eq 0) {
        Rename-Item -LiteralPath $Journal -NewName ([IO.Path]::GetFileNameWithoutExtension($Journal) + '.undone.json')
        Write-Host 'Undo complete.'
    } else {
        Write-Host "$left item(s) could not be removed - journal kept." -ForegroundColor Red
    }
}
finally {
    Disconnect-Nitro
}
