#Requires -Version 7.2
<#
.SYNOPSIS
    Offline LAS licensing via NITRO: license status of one or many NetScalers, activation request, activation import.

.DESCRIPTION
    For a NetScaler without internet access to the License Activation Service (LAS), licensed with a Fixed Bandwidth
    subscription. Same flow as the GUI (License > ADC License > LAS Activation):

      -Action Status    (default) read-only. For each -NsIp: show ns license + show ns laslicense (licensing mode,
                        model, LAS status, days to expiration, next renewal). An appliance that cannot be read
                        (login, TLS, NITRO error) is reported and the run goes on with the next one. A summary table
                        follows at the end. Exit code 1 when any license is below -WarnDays, any appliance is in LAS
                        mode without an active LAS license, or any appliance could not be read; else 0.
      -Action Request   one appliance. show ns licenseactivationdata [-useHostname]: the NetScaler writes the request
                        (and on its first request an activation key pair) to /nsconfig/license; the script downloads
                        the .tgz to -OutDir and shows host name, identifier and build from it. Upload it in Citrix
                        Cloud (Licensing > NetScaler licenses > NetScaler ADC) and download the activation file.
      -Action Activate  one appliance. Uploads -ActivationFile to /nsconfig/license (add system file, replaces an
                        older copy) and applies it (apply ns laslicense -fixedBandwidth). The licensing mode changes
                        after a reboot: -Reboot saves the config, reboots warm, waits and shows the result. -Reboot on
                        an HA primary needs -Force (the reboot fails over to the peer).

    Request and Activate support -WhatIf / -Confirm; -WhatIf does not log in.

    An activation applies only on the NetScaler that created the request (bound to its key pair and identity). A
    rebuilt VPX keeps it only with the same MAC on interface 0/1, the same BIOS UUID, the same hypervisor and a
    restored full system backup - see docs/las-licensing.md. Observed on 14.1 builds 73.46 / 73.49 / 73.58; not
    documented by NetScaler in this form.

.EXAMPLE
    ./Invoke-NsLasLicense.ps1 -NsIp https://192.0.2.10, https://192.0.2.20 -WarnDays 45 -NoProxy
.EXAMPLE
    ./Invoke-NsLasLicense.ps1 -NsIp https://192.0.2.10, https://192.0.2.11 -PinnedPublicKey 'sha256//...' -PassThru | Export-Csv las.csv
.EXAMPLE
    ./Invoke-NsLasLicense.ps1 -NsIp https://192.0.2.10 -Action Request -UseHostname -OutDir . -PinnedPublicKey 'sha256//...'
.EXAMPLE
    ./Invoke-NsLasLicense.ps1 -NsIp https://192.0.2.10 -Action Activate -ActivationFile ./NS_ns01_activation.blob.tgz -Reboot
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string[]]$NsIp,
    [ValidateSet('Status', 'Request', 'Activate')][string]$Action = 'Status',
    [pscredential]$Credential,              # one login for all appliances; prompted when missing
    [switch]$SkipCertificateCheck,
    [string[]]$PinnedPublicKey,             # one pin for all -NsIp (e.g. an HA pair with a synced cert) or one per -NsIp
    [switch]$NoProxy,
    [ValidateRange(0, 3650)][int]$WarnDays = 30,     # Status: warn below this many days
    [switch]$PassThru,                      # Status: return the result objects (CSV/JSON/monitoring)
    [switch]$UseHostname,                   # Request: name the NetScaler by its host name in Citrix Cloud
    [string]$OutDir = '.',                  # Request: where the request .tgz goes
    [string]$ActivationFile,                # Activate: NS_<id or host name>_activation.blob.tgz from Citrix Cloud
    [switch]$Reboot,                        # Activate: save + warm reboot + show the licensing mode afterwards
    [switch]$Force,                         # Activate -Reboot: allow rebooting an HA primary
    [ValidateRange(1, 600)][int]$PollSeconds = 20,       # Activate -Reboot: login attempts while it restarts
    [ValidateRange(1, 120)][int]$TimeoutMinutes = 15     # Activate -Reboot: give up after this long
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetScalerNitro.psm1') -Force

$licDir    = '/nsconfig/license'
$licDirArg = 'filelocation:%2Fnsconfig%2Flicense'
$NsIp = @($NsIp | ForEach-Object { if ($_ -match '^https?://') { $_.TrimEnd('/') } else { "https://$($_.TrimEnd('/'))" } })

# --- input checks (before any login) -----------------------------------------------------------------------------
if ($Action -ne 'Status' -and $NsIp.Count -ne 1) { throw "-Action $Action works on one NetScaler at a time (got $($NsIp.Count) -NsIp)." }
$pins = @($PinnedPublicKey | Where-Object { $_ })
if ($pins.Count -gt 1 -and $pins.Count -ne $NsIp.Count) {
    throw "-PinnedPublicKey: give one pin for all appliances or one per -NsIp ($($NsIp.Count)), not $($pins.Count)."
}
if ($Action -eq 'Request' -and -not (Test-Path -PathType Container $OutDir)) { throw "-OutDir '$OutDir' is not a folder." }
if ($Action -eq 'Activate') {
    if (-not $ActivationFile) { throw '-Action Activate needs -ActivationFile.' }
    if (-not (Test-Path -PathType Leaf $ActivationFile)) { throw "$ActivationFile not found." }
}
if ($Action -ne 'Activate' -and ($Reboot -or $Force)) { throw '-Reboot / -Force belong to -Action Activate.' }

function Get-Pin([int]$Index) { if ($pins.Count -eq 1) { $pins[0] } elseif ($pins.Count) { $pins[$Index] } else { $null } }
function Connect-Ns([string]$Ip, [string]$Pin) {
    Connect-Nitro -NsIp $Ip -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck -PinnedPublicKey $Pin -NoProxy:$NoProxy
}
function Get-NitroObject([string]$Resource) {
    $r = Invoke-Nitro -Method GET -Resource $Resource
    if ($r.ErrorCode -ne 0) { throw "GET $Resource failed: $($r.ErrorCode) $($r.Message)" }
    @($r.Data.$Resource)[0]
}

function Get-LasState([string]$Ip) {
    # show ns license + show ns laslicense (read-only)
    # Two counters: show ns laslicense DaysToExpiration and show ns license "Days to expiration". They can differ
    # (seen 415 vs 353 on 14.1-73.58; the smaller one matches Renewalnextdate) -> the smaller one counts.
    $lic  = Get-NitroObject 'nslicense'
    $las  = Get-NitroObject 'nslaslicense'
    $lasDays = if ("$($las.daystoexpiration)" -match '^-?\d+$') { [int]$las.daystoexpiration } else { $null }
    $licDays = if ("$($lic.licensingmode)" -match 'LAS' -and "$($lic.daystoexpiration)" -match '^-?\d+$') { [int]$lic.daystoexpiration } else { $null }
    $known = @($lasDays, $licDays | Where-Object { $null -ne $_ })
    $days = if ($known) { [int]($known | Measure-Object -Minimum).Minimum } else { $null }
    $mode = "$($lic.licensingmode)"
    # an inactive LAS license reports the epoch ("Thu Jan  1 00:00:00 1970") as next renewal -> leave it out
    $renewal = if ("$($las.renewalnextdate)" -match '\b1970\b') { '' } else { "$($las.renewalnextdate)" }
    $result, $note = if ("$($las.status)" -eq 'ACTIVE') {
        if ($null -eq $days)       { 'WARN', 'days to expiration not readable' }
        elseif ($days -lt $WarnDays) { 'WARN', "below $WarnDays days" }
        else                         { 'OK', '' }
    } elseif ($mode -match 'LAS') { 'WARN', 'LAS mode without an active LAS license' }
    else                          { 'NO-LAS', 'not licensed through LAS' }
    [pscustomobject]@{
        NsIp = $Ip; Result = $result; LicensingMode = $mode; ModelId = "$($lic.modelid)"; LasStatus = "$($las.status)"
        DaysToExpiration = $days; LasDays = $lasDays; LicenseDays = $licDays; RenewalNext = $renewal; Note = $note
    }
}

function Write-LasState($s) {
    $color = @{ OK = 'Green'; WARN = 'Yellow'; 'NO-LAS' = 'DarkGray'; ERROR = 'Red' }[$s.Result]
    if ($s.Result -eq 'ERROR') { Write-Host "  [ERROR]   $($s.NsIp)  $($s.Note)" -ForegroundColor $color; return }
    $days = if ($s.LasStatus -ne 'ACTIVE') { '' } elseif ($null -ne $s.DaysToExpiration) { ", $($s.DaysToExpiration) days" } else { ', - days' }
    if ($null -ne $s.LasDays -and $null -ne $s.LicenseDays -and $s.LasDays -ne $s.LicenseDays) { $days += " (license $($s.LicenseDays), laslicense $($s.LasDays))" }
    Write-Host ("  [{0}]{1}{2}  mode {3}, model {4}, LAS {5}{6}{7}{8}" -f $s.Result, (' ' * [math]::Max(1, 8 - $s.Result.Length)),
        $s.NsIp, $s.LicensingMode, $s.ModelId, $s.LasStatus, $days, $(if ($s.RenewalNext) { ", renewal $($s.RenewalNext)" }),
        $(if ($s.Note -and $s.Result -ne 'OK') { " ($($s.Note))" })) -ForegroundColor $color
}

function Get-HaRole {
    # 'standalone', 'Primary', 'Secondary', ...
    $r = Invoke-Nitro -Method GET -Resource 'hanode'
    if ($r.ErrorCode -ne 0) { throw "GET hanode failed: $($r.ErrorCode) $($r.Message)" }
    $nodes = @($r.Data.hanode | Where-Object { $_ })
    if ($nodes.Count -le 1) { return 'standalone' }
    "$(($nodes | Where-Object { "$($_.id)" -eq '0' } | Select-Object -First 1).state)"
}

function Wait-NsReboot([string]$Ip, [string]$Pin) {
    # 1. wait until the NetScaler goes down (443 closed or login refused), at most 3 min - it may answer for a few
    #    seconds after the reboot call; 2. wait until NITRO takes a login again
    $u = [uri]$Ip
    $port = if ($u.Port -gt 0) { $u.Port } else { 443 }
    $down = $false
    $deadline = (Get-Date).AddMinutes(3)
    while (-not $down -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        if (-not (Test-Connection $u.Host -TcpPort $port -Quiet -TimeoutSeconds 5)) { $down = $true; break }
        try { Connect-Ns $Ip $Pin 6>$null; Disconnect-Nitro 6>$null; Write-Host "  still up ($((Get-Date).ToString('HH:mm:ss')))" -ForegroundColor DarkGray }
        catch { $down = $true }
    }
    if (-not $down) { Write-Warning "$Ip did not seem to go down within 3 minutes - the result below may be from before the reboot." }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        try { Connect-Ns $Ip $Pin 6>$null; return }
        catch {
            if ((Get-Date) -gt $deadline) { throw "NITRO on $Ip not back after $TimeoutMinutes minutes: $($_.Exception.Message)" }
            Write-Host "  not answering yet ($((Get-Date).ToString('HH:mm:ss')))" -ForegroundColor DarkGray
        }
    }
}

# --- Status: read-only, many appliances, next one on error ---------------------------------------------------------
if ($Action -eq 'Status') {
    if (-not $Credential) { $Credential = Get-Credential -Message 'NetScaler NITRO login (all appliances)' }
    $all = for ($i = 0; $i -lt $NsIp.Count; $i++) {
        $ip = $NsIp[$i]
        try {
            Connect-Ns $ip (Get-Pin $i)
            try { $s = Get-LasState $ip } finally { try { Disconnect-Nitro } catch { } }
        } catch {
            $s = [pscustomobject]@{ NsIp = $ip; Result = 'ERROR'; LicensingMode = ''; ModelId = ''; LasStatus = ''
                                    DaysToExpiration = $null; LasDays = $null; LicenseDays = $null; RenewalNext = ''; Note = "$($_.Exception.Message)" }
        }
        Write-LasState $s
        $s
    }
    $all = @($all)
    $bad = @($all | Where-Object Result -in 'WARN', 'ERROR')
    Write-Host "`nLAS license status ($($all.Count) appliance(s), warn below $WarnDays days):" -ForegroundColor Cyan
    Write-Host (($all | Format-Table NsIp, Result, LicensingMode, ModelId, LasStatus,
        @{ n = 'Days'; e = { $_.DaysToExpiration } }, RenewalNext, Note -AutoSize | Out-String -Width 220).TrimEnd())
    if ($bad) { Write-Host "`n$($bad.Count) of $($all.Count) need attention (WARN/ERROR) - exit code 1." -ForegroundColor Yellow }
    else      { Write-Host "`nAll readable, none below $WarnDays days." -ForegroundColor Green }
    if ($PassThru) { $all }
    exit $(if ($bad) { 1 } else { 0 })
}

# --- Request / Activate: one appliance -----------------------------------------------------------------------------
$ip  = $NsIp[0]
$pin = Get-Pin 0

if ($Action -eq 'Request') {
    if (-not $PSCmdlet.ShouldProcess($ip, "create the LAS activation request$(if ($UseHostname) { ' (host name)' }) and download it to $OutDir")) { return }
    if (-not $Credential) { $Credential = Get-Credential -Message "NetScaler NITRO login ($ip)" }
    Connect-Ns $ip $pin
    try {
        # creates the request (and on the first call the activation key pair) under /nsconfig/license; a second call
        # keeps the key pair, only the request time changes
        $q = if ($UseHostname) { @{ args = 'usehostname:true' } } else { $null }
        $r = Invoke-Nitro -Method GET -Resource 'nslicenseactivationdata' -Query $q
        [void](Write-NitroResult "show ns licenseactivationdata$(if ($UseHostname) { ' -useHostname' })" $r)
        $name = "$(@($r.Data.nslicenseactivationdata)[0].filename)"
        if (-not $name) { throw "no file name in the NITRO answer: $($r.Data | ConvertTo-Json -Depth 5 -Compress)" }
        if ($name -match '[\\/]|\.\.') { throw "unexpected file name in the NITRO answer: '$name'" }
        $f = Invoke-Nitro -Method GET -Resource "systemfile/$([uri]::EscapeDataString($name))" -Query @{ args = $licDirArg }
        [void](Write-NitroResult "download $licDir/$name" $f)
        $out = Join-Path (Resolve-Path $OutDir).Path $name
        [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String("$(@($f.Data.systemfile)[0].filecontent)"))
        Write-Host "saved $out ($((Get-Item $out).Length) bytes, sha256 $((Get-FileHash $out).Hash.ToLower()))" -ForegroundColor Green
        # the request holds no secrets: show what Citrix Cloud will see
        try {
            $j = tar -xzOf $out ns_offline_activation_request.json 2>$null | ConvertFrom-Json
            if ($j) { Write-Host "request: hostname $($j.hostname), id $($j.lsguid), build $($j.lsbuild), last activation '$($j.renewalinput.lastactivationid)'" }
        } catch { }
        Write-Host 'Next: upload it in Citrix Cloud (Licensing > NetScaler licenses > NetScaler ADC), then -Action Activate with the activation file.' -ForegroundColor Green
    } finally { Disconnect-Nitro }
    return
}

# Activate
$file = Get-Item $ActivationFile
$name = $file.Name
if (-not $PSCmdlet.ShouldProcess($ip, "upload $name to $licDir and apply it (-fixedBandwidth)$(if ($Reboot) { ', save + warm reboot' })")) { return }
if (-not $Credential) { $Credential = Get-Credential -Message "NetScaler NITRO login ($ip)" }
Connect-Ns $ip $pin
$rebooting = $false
try {
    $role = Get-HaRole
    Write-Host "  HA        $role"
    if ($Reboot -and $role -eq 'Primary' -and -not $Force) {
        throw "This node is the HA PRIMARY: -Reboot would fail over to the peer. Run without -Reboot (reboot later in a window), or -Force."
    }
    Write-Host '  before:'
    try { Write-LasState (Get-LasState $ip) } catch { Write-Host "  (license status not readable: $($_.Exception.Message))" -ForegroundColor Yellow }

    $body = @{ systemfile = @{ filename = $name; filelocation = $licDir; fileencoding = 'BASE64'
                               filecontent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName)) } }
    $r = Invoke-Nitro -Method POST -Resource 'systemfile' -Body $body
    if ($r.ErrorCode -ne 0 -and $r.Message -match 'exist') {
        # same name from an earlier try -> replace
        [void](Write-NitroResult "delete old $licDir/$name" (Invoke-Nitro -Method DELETE `
            -Resource "systemfile/$([uri]::EscapeDataString($name))" -Query @{ args = $licDirArg }))
        $r = Invoke-Nitro -Method POST -Resource 'systemfile' -Body $body
    }
    [void](Write-NitroResult "add system file $name -fileLocation $licDir" $r)

    # without -fixedBandwidth: "Failed to parse las license file"
    $a = Invoke-Nitro -Method POST -Resource 'nslaslicense' -Query @{ action = 'apply' } `
        -Body @{ nslaslicense = @{ filename = $name; filelocation = $licDir; fixedbandwidth = $true } }
    if ($a.ErrorCode -ne 0 -and $a.Message -match 'LPEID') {
        Write-Host ('The activation does not fit this NetScaler: it belongs to the one that created the request (other ' +
            'appliance, or a rebuild without the same identity + full backup). Create a new request (-Action Request).') -ForegroundColor Yellow
    }
    [void](Write-NitroResult "apply ns laslicense -fileName $name -fileLocation $licDir -fixedBandwidth" $a)
    Write-Host '  after the import:'
    Write-LasState (Get-LasState $ip)
    if (-not $Reboot) {
        Write-Host 'The licensing mode changes after a reboot: save ns config + reboot -warm (or run again with -Reboot).' -ForegroundColor Yellow
        return
    }
    [void](Save-NitroConfig)
    $rb = Invoke-Nitro -Method POST -Resource 'reboot' -Body @{ reboot = @{ warm = $true } }
    if ($rb.ErrorCode -ne 0) { throw "reboot -warm failed: $($rb.ErrorCode) $($rb.Message)" }
    $rebooting = $true
    Write-Host "  [OK]      reboot -warm (waiting up to $TimeoutMinutes min)" -ForegroundColor Green
} finally {
    if ($rebooting) { try { Disconnect-Nitro 6>$null } catch { } } else { Disconnect-Nitro }
}

Wait-NsReboot $ip $pin
try {
    Write-Host '  after the reboot:'
    $s = Get-LasState $ip
    Write-LasState $s
    if ($s.LicensingMode -notmatch 'LAS') { Write-Warning "licensing mode is '$($s.LicensingMode)', not LAS - check show ns license / ns.log." }
} finally { Disconnect-Nitro }
