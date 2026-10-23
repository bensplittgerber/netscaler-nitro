#Requires -Version 7.2
<#
.SYNOPSIS
    End to end: empty ESXi host -> NetScaler VPX -> base config -> certificates -> Gateway objects, driven by one
    site file.

.DESCRIPTION
    Phases (all from one site JSON file, see examples/site.example.json and docs/end-to-end.md):
      Vpx          new VPX with netscaler-vpx-deploy (vmware/Deploy-NsVpx.ps1, separate repo, path in the site file):
                   OVF import, first-boot userdata, forced nsroot change, CallHome / MBF off, ISO removed.
                   Skipped with -SkipVpx (existing VPX) or when the site file has no "vpx" section.
      Base         Invoke-NsDeployment.ps1 with the "base" files (00-prereq, optional 00-network).
      Certificates "mode": "files" -> Deploy-NsCertificates.ps1 with the certificate file (unattended);
                   "mode": "acme"  -> pauses, prints the netscaler-acme commands for the Docker host and waits until
                   the listed certKeys exist on the NetScaler (acme-ns uploads them).
      Objects      Invoke-NsDeployment.ps1 with the "objects" files (LB, AAA, Gateway, ...).
    -From starts at a later phase (resume after a fix: earlier phases are not run again).

    Trust: after the Vpx phase the self-signed management key is pinned on first contact (Get-NitroPin, printed) and
    used for every NITRO call of this run. Existing VPX: pass -PinnedPublicKey, or nothing if its management
    certificate is CA-signed and trusted by this machine.

    Prompts (masked, all before the first change): nsroot login for the NITRO phases and every secret named in
    "secrets" of the site file; they are removed from the environment at the end. Deploy-NsVpx.ps1 prompts its own
    passwords (ESXi login, the image's default nsroot password, the new one) - use the same new nsroot password.
    Nothing is written to disk.

.EXAMPLE
    ./scripts/Deploy-NsSite.ps1 -SiteFile ./examples/site.example.json -WhatIf
.EXAMPLE
    ./scripts/Deploy-NsSite.ps1 -SiteFile ./configs/site-a.json
.EXAMPLE
    ./scripts/Deploy-NsSite.ps1 -SiteFile ./configs/site-a.json -SkipVpx -From Objects -PinnedPublicKey 'sha256//...'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SiteFile,
    [ValidateSet('Vpx', 'Base', 'Certificates', 'Objects')][string]$From = 'Vpx',
    [switch]$SkipVpx,
    [string]$PinnedPublicKey,
    [switch]$NoRollback
)
$ErrorActionPreference = 'Stop'
$dryRun = [bool]$WhatIfPreference
Import-Module (Join-Path $PSScriptRoot 'NetScalerNitro.psm1') -Force

$sitePath = (Resolve-Path $SiteFile).Path
$siteDir  = Split-Path -Parent $sitePath
try   { $site = Get-Content -Raw $sitePath | ConvertFrom-Json }
catch { throw "Site file '$sitePath' is not valid JSON: $($_.Exception.Message)" }
function Resolve-SitePath([string]$p) { if ([IO.Path]::IsPathRooted($p)) { $p } else { [IO.Path]::GetFullPath((Join-Path $siteDir $p)) } }

# --- check the site file before anything is prompted or changed -------------------------------------------------------
$phases = 'Vpx', 'Base', 'Certificates', 'Objects'
$run    = @($phases[$phases.IndexOf($From)..3])
if ($SkipVpx -or -not $site.vpx) { $run = @($run | Where-Object { $_ -ne 'Vpx' }) }
if (-not $site.nsip) { throw "Site file: 'nsip' (management address of the VPX, e.g. 192.0.2.10) is missing." }
$nsUrl   = "https://$($site.nsip)"
$base    = @($site.base    | Where-Object { $_ } | ForEach-Object { Resolve-SitePath $_ })
$objects = @($site.objects | Where-Object { $_ } | ForEach-Object { Resolve-SitePath $_ })
foreach ($f in $base + $objects) { if (-not (Test-Path $f)) { throw "Site file: config file not found: $f" } }
$certMode = if ($site.certificates) { $site.certificates.mode } else { 'none' }
switch ($certMode) {
    'files' { $certFile = Resolve-SitePath $site.certificates.file
              if (-not (Test-Path $certFile)) { throw "Site file: certificate file not found: $certFile" } }
    'acme'  { if (-not $site.certificates.certKeys) { throw "Site file: certificates.mode 'acme' needs 'certKeys' (the names acme-ns deploys)." } }
    'none'  { }
    default { throw "Site file: certificates.mode must be 'files', 'acme' or 'none' (is '$certMode')." }
}
$waitMin = if ($site.certificates.waitMinutes) { [int]$site.certificates.waitMinutes } else { 60 }
if ('Vpx' -in $run) {
    $vpxScript = Resolve-SitePath $site.vpx.script
    if (-not (Test-Path $vpxScript)) { throw "Site file: vpx.script not found: $vpxScript (clone netscaler-vpx-deploy, see docs/end-to-end.md)." }
    if ($site.vpx.parameters.Nsip) { throw "Site file: set the NSIP once in 'nsip', not in vpx.parameters." }
    $vpxArgs = @{ Nsip = $site.nsip }
    $site.vpx.parameters.PSObject.Properties | ForEach-Object { $vpxArgs[$_.Name] = $_.Value }
    if ($site.noProxy) { $vpxArgs.NoProxy = $true }
}
Write-Host "Site $(Split-Path -Leaf $sitePath): NSIP $($site.nsip), phases: $($run -join ' -> ')" -ForegroundColor Cyan

if ($dryRun) {
    if ('Vpx' -in $run) { & $vpxScript @vpxArgs -WhatIf }
    if ('Base' -in $run) { Write-Host "WhatIf: Base - $(($base | Split-Path -Leaf) -join ', ')" -ForegroundColor Yellow }
    if ('Certificates' -in $run) {
        $what = switch ($certMode) { 'files' { Split-Path -Leaf $certFile } 'acme' { "wait for certKey(s) $($site.certificates.certKeys -join ', ')" } default { 'nothing' } }
        Write-Host "WhatIf: Certificates ($certMode) - $what" -ForegroundColor Yellow
    }
    if ('Objects' -in $run) { Write-Host "WhatIf: Objects - $(($objects | Split-Path -Leaf) -join ', ')" -ForegroundColor Yellow }
    Write-Host 'WhatIf: nothing was changed. Dry-run the NITRO files against an existing VPX with Invoke-NsDeployment.ps1 -WhatIf.' -ForegroundColor Yellow
    return
}

# --- prompts, all before the first change -------------------------------------------------------------------------------
$cred = Get-Credential nsroot -Message "NetScaler $($site.nsip) - nsroot (the NEW password when the VPX is deployed in this run)"
$prompted = @()
foreach ($name in @($site.secrets | Where-Object { $_ })) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { Set-Item "Env:$name" (Read-Host $name -MaskInput); $prompted += $name }
}

try {
    # --- Vpx ---------------------------------------------------------------------------------------------------------
    if ('Vpx' -in $run) {
        Write-Host "`n########## Vpx: $($vpxArgs.VmName) on $($vpxArgs.EsxHost) ##########" -ForegroundColor Cyan
        & $vpxScript @vpxArgs
        # same trust-on-first-use as the deploy itself, minutes later on the same path
        $PinnedPublicKey = Get-NitroPin -NsIp $nsUrl
        Write-Host "management key pin for this run: $PinnedPublicKey" -ForegroundColor Cyan
    }
    $tls    = if ($PinnedPublicKey) { @{ PinnedPublicKey = $PinnedPublicKey } } else { @{} }
    # the nsroot password was typed before the VPX existed -> prove it once, ask again on a typo (3 tries)
    for ($try = 1; $true; $try++) {
        try { Connect-Nitro -NsIp $nsUrl -Credential $cred -NoProxy:([bool]$site.noProxy) @tls; Disconnect-Nitro; break }
        catch {
            if ($_.Exception.Message -notmatch 'Login failed' -or $try -ge 3) { throw }
            Write-Warning "nsroot login to $($site.nsip) failed ($($_.Exception.Message)) - enter the password again ($try/3)."
            $cred = Get-Credential nsroot -Message "NetScaler $($site.nsip) - nsroot"
        }
    }
    $common = @{ Credential = $cred; NoProxy = [bool]$site.noProxy } + $tls

    # --- Base --------------------------------------------------------------------------------------------------------
    if ('Base' -in $run -and $base) {
        Write-Host "`n########## Base ##########" -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot 'Invoke-NsDeployment.ps1') -ConfigFile $base @common -NoRollback:$NoRollback
    }

    # --- Certificates ------------------------------------------------------------------------------------------------
    if ('Certificates' -in $run -and $certMode -eq 'files') {
        Write-Host "`n########## Certificates (files) ##########" -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot 'Deploy-NsCertificates.ps1') -ConfigFile $certFile @common
    }
    elseif ('Certificates' -in $run -and $certMode -eq 'acme') {
        $keys = @($site.certificates.certKeys)
        Write-Host "`n########## Certificates (netscaler-acme) ##########" -ForegroundColor Cyan
        Write-Host 'Run on the Docker host (first deployment: conf/pending/ + pin override, see netscaler-acme docs/operations.md):' -ForegroundColor Yellow
        $pinArg = if ($PinnedPublicKey) { " -e NS_CACERT= -e NS_PINNEDPUBKEY=$PinnedPublicKey" } else { '' }
        foreach ($c in @($site.certificates.acmeConfigs | Where-Object { $_ })) { Write-Host "  docker exec -e CONF_DIR=/conf/pending$pinArg acme acme-ns run $c" }
        Write-Host "Waiting for certKey(s) $($keys -join ', ') on $($site.nsip) - checked every 30 s, up to $waitMin min (Ctrl+C stops; resume with -From Objects) ..." -ForegroundColor Yellow
        $deadline = (Get-Date).AddMinutes($waitMin)
        Connect-Nitro -NsIp $nsUrl -Credential $cred -NoProxy:([bool]$site.noProxy) @tls
        try {
            while ($true) {
                $missing = @($keys | Where-Object { (Invoke-Nitro -Method GET -Resource "sslcertkey/$_").ErrorCode -ne 0 })
                if (-not $missing) { break }
                if ((Get-Date) -gt $deadline) { throw "certKey(s) still missing: $($missing -join ', ') - deploy them, then resume with -From Objects." }
                Write-Host "  missing: $($missing -join ', ')" -ForegroundColor DarkGray
                Start-Sleep 30
            }
        }
        finally { Disconnect-Nitro }
        Write-Host "  [OK]      certKey(s) present: $($keys -join ', ')" -ForegroundColor Green
    }

    # --- Objects -----------------------------------------------------------------------------------------------------
    if ('Objects' -in $run -and $objects) {
        Write-Host "`n########## Objects ##########" -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot 'Invoke-NsDeployment.ps1') -ConfigFile $objects @common -NoRollback:$NoRollback
    }
    Write-Host "`nSite $(Split-Path -Leaf $sitePath) done: $($run -join ' -> ')." -ForegroundColor Green
    if ($PinnedPublicKey) { Write-Host "Management key pin: $PinnedPublicKey - replace the self-signed certificate later (e.g. netscaler-acme)." -ForegroundColor Green }
}
finally {
    foreach ($name in $prompted) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
}
