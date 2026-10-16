#Requires -Version 7.0
<#
.SYNOPSIS
    Runs several Deploy-NsObjects.ps1 files in order, stops at the first failure, prompts secrets once.

.DESCRIPTION
    One-flow deployment, e.g. a fresh appliance from a VM snapshot:
      * files run in the given order; the first failing file stops the flow (that file rolls itself back,
        files before it stay deployed and have their own journals)
      * every environment variable named in -Secret is prompted masked if it is not set yet, and removed
        again at the end (also on failure); nothing is written to disk
      * files that only contain "skip": true steps are skipped (useful for optional files like 00-network.json)
      * the NetScaler login is prompted once and reused for all files

.EXAMPLE
    ./Invoke-NsDeployment.ps1 -ConfigFile ../examples/00-prereq.json, ../examples/02-lb-storefront.json `
        -Secret CERT_USER_PW -PinnedPublicKey 'sha256//...' -WhatIf
.EXAMPLE
    ./Invoke-NsDeployment.ps1 -ConfigFile (Get-ChildItem ../configs/site-a/0*.json | Sort-Object Name).FullName `
        -Secret CERT_USER_PW, OIDC_CLIENT_SECRET -SkipCertificateCheck -NoProxy
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string[]]$ConfigFile,
    [string[]]$Secret = @(),
    [pscredential]$Credential,
    [switch]$SkipCertificateCheck,
    [string]$PinnedPublicKey,
    [switch]$NoProxy,
    [switch]$NoRollback
)
$ErrorActionPreference = 'Stop'
$deploy = Join-Path $PSScriptRoot 'Deploy-NsObjects.ps1'

foreach ($f in $ConfigFile) { if (-not (Test-Path $f)) { throw "Config file not found: $f" } }
if (-not $Credential) { $Credential = Get-Credential -Message 'NetScaler NITRO login' }

$prompted = @()
try {
    foreach ($name in $Secret) {
        if (-not [Environment]::GetEnvironmentVariable($name)) {
            Set-Item "Env:$name" (Read-Host "$name" -MaskInput)
            $prompted += $name
        }
    }
    $n = 0
    foreach ($f in $ConfigFile) {
        $n++
        $cfg = Get-Content -Raw $f | ConvertFrom-Json
        if (-not @($cfg.steps | Where-Object { $_.resource -and $_.skip -ne $true }).Count) {
            Write-Host "`n===== [$n/$($ConfigFile.Count)] $(Split-Path -Leaf $f): no enabled steps - skipped" -ForegroundColor DarkGray
            continue
        }
        Write-Host "`n===== [$n/$($ConfigFile.Count)] $(Split-Path -Leaf $f) =====" -ForegroundColor Cyan
        & $deploy -ConfigFile $f -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck `
            -PinnedPublicKey $PinnedPublicKey -NoProxy:$NoProxy -NoRollback:$NoRollback -WhatIf:$WhatIfPreference
    }
    Write-Host "`nAll $($ConfigFile.Count) file(s) done." -ForegroundColor Green
}
finally {
    foreach ($name in $prompted) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
}
