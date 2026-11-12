#Requires -Version 7.0
<#
.SYNOPSIS
    Upgrades the firmware of ONE NetScaler node via NITRO: upload or download the build, backup, pre-check,
    install, reboot, wait, verify.

.DESCRIPTION
    Steps:
      1. local SHA256 of -BuildFile (compared with -Sha256 when given)
      2. NITRO login to the node itself (its NSIP, not a floating SNIP): current build, HA role
         - already on the target build -> nothing to do
         - HA primary -> stops (upgrade the secondary first, then "force ha failover", then this node) unless -Force
         - unsaved running config -> stops (the installer refuses it in API mode) unless -SaveConfig (save first) or
           -IgnoreUnsavedConfig (NITRO ignoreUnsavedConfig; unsaved changes are lost at the reboot)
      3. build onto the node:
         -BuildFile  scp to /var/nsinstall/<file> (scp.exe asks for the password itself, or -SshKey); skipped when a
                     file with the same size is already there
         -BuildUrl   the NetScaler downloads the build itself (http/https)
      4. system backup (basic) unless -NoBackup
      5. NITRO pre-check (install -preCheck: disk space, saved/synced config, licenses, ...). NITRO answers 201 even
         with warnings, so the result file /var/tmp/install_pre_check.<job>.json is read: any warning or failure
         stops the run. -PreCheckOnly stops here
      6. NITRO install, async: the job is followed until it ends. Without -DeleteOldKernels the installer runs in API
         mode and KEEPS the old kernel on /flash (rollback = select it in the boot loader); it does not reboot.
         -DeleteOldKernels sends "y" = -answerYesToAll: old kernels, signatures and RSA keys are deleted and the node
         reboots by itself.
      7. NITRO reboot (unless -NoReboot), wait until NITRO answers again, verify the build and the HA state.
    -WhatIf runs steps 1-2 only.

    HA pair, in this order:
      ./Update-NsFirmware.ps1 -NsIp https://<secondary NSIP> ...      # secondary first
      force ha failover   (CLI on the primary; or NITRO hafailover)
      ./Update-NsFirmware.ps1 -NsIp https://<old primary NSIP> ...    # now secondary
    Between the two runs the nodes run different builds: HA sync/propagation shows AUTO DISABLED (expected).

.EXAMPLE
    ./Update-NsFirmware.ps1 -NsIp https://192.0.2.11 -BuildFile ~/Downloads/build-14.1-73.58_nc_64.tgz -PinnedPublicKey 'sha256//...' -PreCheckOnly
.EXAMPLE
    ./Update-NsFirmware.ps1 -NsIp https://192.0.2.11 -BuildUrl https://files.example.org/netscaler/build-14.1-73.58_nc_64.tgz -NoProxy
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory)][string]$NsIp,
    [Parameter(Mandatory, ParameterSetName = 'File')][string]$BuildFile,
    [Parameter(Mandatory, ParameterSetName = 'Url')][string]$BuildUrl,
    [string]$Sha256,                    # expected SHA256 of the build (from the download page); checked for -BuildFile
    [pscredential]$Credential,
    [switch]$SkipCertificateCheck,
    [string]$PinnedPublicKey,
    [switch]$NoProxy,
    [Parameter(ParameterSetName = 'File')][string]$SshUser = 'nsroot',
    [Parameter(ParameterSetName = 'File')][string]$SshKey,       # private key for scp; default: scp asks for the password
    [switch]$SaveConfig,                # save an unsaved running config before the backup (default: stop)
    [switch]$IgnoreUnsavedConfig,       # install anyway (NITRO ignoreUnsavedConfig); unsaved changes are lost at the reboot
    [switch]$NoBackup,
    [switch]$PreCheckOnly,
    [switch]$NoReboot,
    [switch]$DeleteOldKernels,
    [switch]$Force,                     # allow upgrading an HA primary
    [int]$TimeoutMinutes = 30,
    [int]$PollSeconds = 15,             # job polling; the reboot wait uses 4x this before the first login attempt
    [Parameter(ParameterSetName = 'File')][string]$ScpCommand = 'scp.exe'   # tests replace it with a stub
)
$ErrorActionPreference = 'Stop'
if ($SaveConfig -and $IgnoreUnsavedConfig) { throw 'Use -SaveConfig or -IgnoreUnsavedConfig, not both.' }
Import-Module (Join-Path $PSScriptRoot 'NetScalerNitro.psm1') -Force

function Write-Step($Text) { Write-Host "`n# $Text" -ForegroundColor Cyan }
function Get-NsBuild {
    $r = Invoke-Nitro -Method GET -Resource 'nsversion'
    if ($r.ErrorCode -ne 0) { throw "GET nsversion failed: $($r.Message)" }
    "$(@($r.Data.nsversion)[0].version)"
}
function Get-HaSelf {
    $r = Invoke-Nitro -Method GET -Resource 'hanode'
    $nodes = @($r.Data.hanode | Where-Object { $_ })
    [pscustomobject]@{
        Pair  = $nodes.Count -gt 1
        State = "$(($nodes | Where-Object { "$($_.id)" -eq '0' } | Select-Object -First 1).state)"
        Peer  = $nodes | Where-Object { "$($_.id)" -ne '0' } | Select-Object -First 1
    }
}
function Get-InstallFile($Name) {
    # list /var/nsinstall instead of GET systemfile?args=filename:...: with a file name NITRO returns the content
    # (base64) and refuses a build-sized file with "File too large"; the listing carries name + size only
    $r = Invoke-Nitro -Method GET -Resource 'systemfile' -Query @{ args = 'filelocation:%2Fvar%2Fnsinstall' }
    if ($r.ErrorCode -ne 0) { throw "GET systemfile (/var/nsinstall listing) failed: $($r.Message)" }
    @($r.Data.systemfile) | Where-Object { $_ -and $_.filename -eq $Name } | Select-Object -First 1
}
function Get-ConfigState {
    $r = Invoke-Nitro -Method GET -Resource 'nsconfig'
    if ($r.ErrorCode -ne 0) { throw "GET nsconfig failed: $($r.Message)" }
    $c = @($r.Data.nsconfig)[0]
    [pscustomobject]@{
        Unsaved = "$($c.configchanged)" -match '^(true|yes)$'
        Changed = $c.lastconfigchangedtime
        Saved   = $c.lastconfigsavetime
    }
}
function ConvertFrom-NsTime($Text) {
    # "Thu Nov 12 19:29:56 2026" / "Thu Nov  5 14:43:16 2026"
    $t = [datetime]::MinValue
    [void][datetime]::TryParseExact(("$Text".Trim() -replace '\s+', ' '), 'ddd MMM d HH:mm:ss yyyy',
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)
    $t
}
function Get-PreCheckResult {
    # the pre-check writes /var/tmp/install_pre_check.<job>.json; NITRO answers 201 for it even with warnings
    $r = Invoke-Nitro -Method GET -Resource 'systemfile' -Query @{ args = 'filelocation:%2Fvar%2Ftmp' }
    if ($r.ErrorCode -ne 0) { return $null }
    $f = @($r.Data.systemfile) | Where-Object { $_ -and $_.filename -match '^install_pre_check\.(\d+)\.json$' } |
        Sort-Object { ConvertFrom-NsTime $_.filemodifiedtime }, { [int]($_.filename -replace '\D', '') } |
        Select-Object -Last 1       # newest by time: job ids start over after a reboot
    if (-not $f) { return $null }
    $r = Invoke-Nitro -Method GET -Resource 'systemfile' -Query @{ args = "filename:$($f.filename),filelocation:%2Fvar%2Ftmp" }
    if ($r.ErrorCode -ne 0) { return $null }
    $content = "$(@($r.Data.systemfile)[0].filecontent)"
    try { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($content)) | ConvertFrom-Json } catch { $null }
}
function Connect-Node { Connect-Nitro -NsIp $NsIp -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck -PinnedPublicKey $PinnedPublicKey -NoProxy:$NoProxy }

# --- 1. build file ------------------------------------------------------------------------------------------------
$fileName = if ($BuildFile) { Split-Path -Leaf $BuildFile } else { Split-Path -Leaf ([uri]$BuildUrl).AbsolutePath }
if ($fileName -notmatch '^build-(\d+\.\d+)-(\d+\.\d+)_nc_64\.tgz$') {
    throw "'$fileName' does not look like a NetScaler build (build-<release>-<build>_nc_64.tgz)."
}
$target = "NS$($Matches[1]): Build $($Matches[2])"     # as in "NetScaler NS14.1: Build 73.58.nc, ..."
if ($BuildFile) {
    $BuildFile = (Resolve-Path $BuildFile).Path
    $size = (Get-Item $BuildFile).Length
    Write-Step "Build file $fileName ($([math]::Round($size / 1MB)) MB)"
    $hash = (Get-FileHash $BuildFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "  SHA256 $hash"
    if ($Sha256) {
        if ($hash -ne $Sha256.Trim().ToLowerInvariant()) { throw "SHA256 mismatch: expected $Sha256" }
        Write-Host '  [OK]      SHA256 matches -Sha256' -ForegroundColor Green
    } else {
        Write-Host '  compare it with the checksum on the download page (or pass -Sha256)' -ForegroundColor Yellow
    }
    $url = "file:///var/nsinstall/$fileName"
} else {
    $url = $BuildUrl
}

# --- 2. node ------------------------------------------------------------------------------------------------------
if (-not $Credential) { $Credential = Get-Credential -Message "NetScaler NITRO login ($NsIp)" }
Connect-Node
$rebooting = $false
try {
    $before = Get-NsBuild
    $ha = Get-HaSelf
    Write-Step 'Node'
    Write-Host "  running   $before"
    Write-Host "  target    $target"
    Write-Host "  HA        $(if ($ha.Pair) { "$($ha.State) (peer $($ha.Peer.ipaddress): $($ha.Peer.state))" } else { 'standalone' })"
    if ($before -match [regex]::Escape($target) + '\.') {
        Write-Host "  [OK]      already on $target - nothing to do" -ForegroundColor Green
        return
    }
    if ($ha.Pair -and $ha.State -eq 'Primary' -and -not $Force) {
        throw "This node is the HA PRIMARY. Upgrade the secondary first, then 'force ha failover', then this node (or -Force)."
    }
    # unsaved config: the pre-check only warns, the installer (API mode) then aborts with
    # "Detected configuration changes after the last save" - stop here, before the upload
    $cfg = Get-ConfigState
    Write-Host "  config    $(if ($cfg.Unsaved) { "UNSAVED changes (last change $($cfg.Changed), last save $($cfg.Saved))" } else { 'saved' })"
    if ($WhatIfPreference) { Write-Host "`nWhat if: upload/backup/pre-check/install/reboot of $target on $NsIp"; return }
    if ($cfg.Unsaved -and $IgnoreUnsavedConfig) {
        Write-Host '  [WARN]    unsaved changes ignored (-IgnoreUnsavedConfig): they are lost at the reboot' -ForegroundColor Yellow
    } elseif ($cfg.Unsaved -and -not $SaveConfig) {
        throw "The running config has unsaved changes - the installer refuses that. Check 'diff ns config', then 'save ns config' (or -SaveConfig, or -IgnoreUnsavedConfig to install without saving)."
    }

    # --- 3. build onto the node -----------------------------------------------------------------------------------
    if ($BuildFile) {
        Write-Step "Upload to /var/nsinstall/$fileName"
        $remote = Get-InstallFile $fileName
        if ($remote -and [long]$remote.filesize -eq $size) {
            Write-Host "  [EXISTS]  same size already on the node - not uploaded again" -ForegroundColor Yellow
        } else {
            $hostName = ([uri]$NsIp).Host
            $scpArgs = @('-o', 'ServerAliveInterval=30')
            if ($SshKey) { $scpArgs += @('-i', $SshKey, '-o', 'BatchMode=yes') }
            $scpArgs += @($BuildFile, "$SshUser@$($hostName):/var/nsinstall/")
            Write-Host "  scp $fileName -> $SshUser@$($hostName):/var/nsinstall/  (password prompt comes from scp)"
            & $ScpCommand @scpArgs
            if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }
            # the NITRO session may have idled out during a long upload
            Disconnect-Nitro; Connect-Node
            $remote = Get-InstallFile $fileName
            if (-not $remote -or [long]$remote.filesize -ne $size) {
                throw "Upload check failed: node reports $(if ($remote) { "$($remote.filesize) bytes" } else { 'no such file' }) in /var/nsinstall, local file has $size bytes."
            }
            Write-Host "  [OK]      uploaded, size checked ($size bytes)" -ForegroundColor Green
        }
    }

    # --- 4. backup --------------------------------------------------------------------------------------------------
    if ($cfg.Unsaved -and $SaveConfig) {
        Write-Step 'Save config (-SaveConfig)'
        [void](Save-NitroConfig)
    }
    if (-not $NoBackup) {
        Write-Step 'Backup'
        [void](New-NitroBackup)
    }

    # --- 5. pre-check ---------------------------------------------------------------------------------------------
    Write-Step "Pre-check $url"
    $pre = @{ url = $url; precheck = $true }
    if ($IgnoreUnsavedConfig) { $pre.ignoreUnsavedConfig = $true }
    $r = Invoke-Nitro -Method POST -Resource 'install' -Body @{ install = $pre }
    if ($r.ErrorCode -ne 0) { throw "Pre-check failed: $($r.ErrorCode) $($r.Message)" }
    $pc = Get-PreCheckResult
    if (-not $pc) {
        Write-Host '  [WARN]    pre-check accepted, but its result file (/var/tmp/install_pre_check.<job>.json) could not be read' -ForegroundColor Yellow
    } else {
        $issues = @($pc.pre_checks.PSObject.Properties | Where-Object { $_.Value.status -ne 'success' })
        $ignored = @($issues | Where-Object { $IgnoreUnsavedConfig -and $_.Name -eq 'config_unsaved' })
        $fatal   = @($issues | Where-Object { $_ -notin $ignored })
        foreach ($i in $issues) {
            $tag = if ($i -in $ignored) { 'IGNORED' } else { $i.Value.status.ToUpper() }
            Write-Host ("  [{0,-7}] {1}: {2}" -f $tag, $i.Value.label, $i.Value.message) -ForegroundColor Yellow
        }
        if ($fatal.Count -or ($pc.global_status -notin 'success', 'warning')) {
            throw "Pre-check $($pc.global_status): $(($fatal | ForEach-Object Name) -join ', ') ($($pc.summary.passed)/$($pc.summary.total_checks) passed). Fix it and run again."
        }
        Write-Host "  [OK]      pre-check passed ($($pc.summary.passed)/$($pc.summary.total_checks))" -ForegroundColor Green
    }
    if ($PreCheckOnly) { Write-Host "`n-PreCheckOnly: nothing installed."; return }

    # --- 6. install -----------------------------------------------------------------------------------------------
    Write-Step "Install $target$(if ($DeleteOldKernels) { ' (deletes old kernels, reboots by itself)' } else { ' (old kernel kept)' })"
    $body = @{ url = $url; Async = $true }
    if ($DeleteOldKernels) { $body.y = $true }
    if ($IgnoreUnsavedConfig) { $body.ignoreUnsavedConfig = $true }
    $r = Invoke-Nitro -Method POST -Resource 'install' -Body @{ install = $body }
    if ($r.ErrorCode -ne 0) { throw "Install failed to start: $($r.ErrorCode) $($r.Message)" }
    $jobId = "$(@($r.Data.install)[0].id)"
    Write-Host "  job $jobId started"
    $end = (Get-Date).AddMinutes($TimeoutMinutes)
    $job = $null; $lost = 0
    while ((Get-Date) -lt $end) {
        Start-Sleep -Seconds $PollSeconds
        # the installer restarts the web services while it copies files: a poll can be reset or the session gone.
        # Log in again and keep polling (seen on a VPX: "An existing connection was forcibly closed")
        $j = $null; $why = $null
        try { $j = Invoke-Nitro -Method GET -Resource "nsjob/$jobId" } catch { $why = $_.Exception.Message }
        if (-not $why -and $j.ErrorCode -ne 0) { $why = "$($j.ErrorCode) $($j.Message)" }
        if ($why) {
            if ($DeleteOldKernels) { break }   # the node is rebooting by itself
            if (++$lost -gt 10) { throw "GET nsjob/$jobId failed $lost times in a row, last: $why" }
            Write-Host "  job $jobId - NITRO not answering ($why); logging in again" -ForegroundColor Yellow
            try { Disconnect-Nitro 6>$null } catch { }
            try { Connect-Node 6>$null } catch { }
            continue
        }
        $lost = 0
        $job = @($j.Data.nsjob)[0]
        Write-Host "  job $jobId $($job.status) ($($job.timeelapsed) s)"
        if ($job.status -ne 'InProgress') { break }
    }
    if ($job -and $job.status -in 'Failed', 'TimedOut') { throw "Install job $jobId $($job.status): $($job.errorcode) $($job.message)" }
    if (-not $DeleteOldKernels -and (-not $job -or $job.status -ne 'Success')) { throw "Install job $jobId did not finish within $TimeoutMinutes minutes." }
    if ($job.message) { Write-Host "  $($job.message)" }     # 5221: takes effect after the reboot

    # --- 7. reboot ------------------------------------------------------------------------------------------------
    if ($DeleteOldKernels) { $rebooting = $true }
    elseif ($NoReboot) { Write-Host "`n-NoReboot: installed, $target becomes active with the next reboot."; return }
    else {
        Write-Step 'Reboot'
        $r = Invoke-Nitro -Method POST -Resource 'reboot' -Body @{ reboot = @{ warm = $false } }
        if ($r.ErrorCode -ne 0) { throw "Reboot failed: $($r.ErrorCode) $($r.Message)" }
        $rebooting = $true
    }
}
finally {
    if ($rebooting) { try { Disconnect-Nitro } catch { } } else { Disconnect-Nitro }
}

# --- wait until the node answers on the new build ---------------------------------------------------------------
Write-Step "Waiting for $NsIp (up to $TimeoutMinutes min)"
Start-Sleep -Seconds (4 * $PollSeconds)
$end = (Get-Date).AddMinutes($TimeoutMinutes)
$after = $null
$seen = $null
while ((Get-Date) -lt $end -and -not $after) {
    try {
        Connect-Node 6>$null
        $seen = Get-NsBuild
        # the node may still answer on the old build for a few seconds before it goes down
        if ($seen -match [regex]::Escape($target) + '\.') { $after = $seen; break }
        Disconnect-Nitro 6>$null
        Write-Host "  still on the old build ($((Get-Date).ToString('HH:mm:ss')))" -ForegroundColor DarkGray
    } catch {
        Write-Host "  not answering yet ($((Get-Date).ToString('HH:mm:ss')))" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds $PollSeconds
}
if (-not $after) { throw "$NsIp is not on $target after $TimeoutMinutes minutes (last seen: $(if ($seen) { $seen } else { 'no answer' })) - check the console." }
try {
    $ha = Get-HaSelf
    Write-Host "  running   $after"
    if ($ha.Pair) { Write-Host "  HA        $($ha.State) (peer $($ha.Peer.ipaddress): $($ha.Peer.state)) - sync is AUTO DISABLED until both nodes run the same build" }
} finally { Disconnect-Nitro }
Write-Host "  [OK]      $target" -ForegroundColor Green
