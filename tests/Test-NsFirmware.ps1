#Requires -Version 7.0
<#
.SYNOPSIS
    Offline test of Update-NsFirmware.ps1 against a fake NITRO API and an scp stub (no NetScaler needed).

.DESCRIPTION
    The fake behaves like NetScaler 14.1 in the lab upgrade of 2026-11-12: install with precheck answers
    synchronously, install with Async returns a job id, nsjob reports InProgress, then Success with errorcode 5221,
    reboot makes the next logins fail for a while, after that nsversion reports the new build. Checks:
      1. -WhatIf only reads (version, HA)
      2. an HA primary is refused
      3. -BuildUrl -PreCheckOnly: pre-check, no install
      4. -BuildFile full run: scp stub, size check, backup, pre-check, install WITHOUT y, job polling, reboot, wait
      5. already on the target build: nothing to do
      6. -DeleteOldKernels: install with y, no separate reboot
      7. failed pre-check stops before the install
#>
$ErrorActionPreference = 'Stop'

$state = [hashtable]::Synchronized(@{
    version = '73.46'; target = '73.58'; ha = @(@{ id = 0; ipaddress = '192.0.2.11'; state = 'Secondary' }, @{ id = 1; ipaddress = '192.0.2.10'; state = 'Primary' })
    loginFailures = 0; precheckFail = $false; jobPolls = 0; uploaded = $null
    requests = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
})

$tcp = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tcp.Start()
$port = $tcp.LocalEndpoint.Port; $tcp.Stop()
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

$server = Start-ThreadJob -ArgumentList $listener, $state -ScriptBlock {
    param($listener, $state)
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        $req  = $ctx.Request
        $path = $req.Url.AbsolutePath -replace '^/nitro/v1/config/', ''
        $query = [uri]::UnescapeDataString($req.Url.Query)
        $body = if ($req.HasEntityBody) { [IO.StreamReader]::new($req.InputStream).ReadToEnd() } else { '' }
        [void]$state.requests.Add("$($req.HttpMethod) $path$query $body")
        $code = 200; $out = @{ errorcode = 0; message = 'Done' }
        switch -Regex ($path) {
            '^login$' {
                if ($state.loginFailures -gt 0) { $state.loginFailures--; $code = 503; $out = @{ errorcode = 1; message = 'Service unavailable' } }
                else { $out.sessionid = 'test-session' }
            }
            '^logout$' { }
            '^nsversion$' { $out.nsversion = @{ version = "NetScaler NS14.1: Build $($state.version).nc, Date: Nov  9 2026, 16:02:20   (64-bit)" } }
            '^hanode$' { $out.hanode = @($state.ha) }
            '^nsconfig$' {
                if ($req.HttpMethod -eq 'POST' -and $query -match 'action=save') { $state.configChanged = $false; $code = 201 }
                else { $out.nsconfig = @{ configchanged = $state.configChanged; lastconfigchangedtime = 'Thu Nov  5 14:43:16 2026'; lastconfigsavetime = 'Thu Nov  5 14:42:39 2026' } }
            }
            '^systemfile$' {
                if ($query -match 'filelocation:/var/tmp') {
                    # a stale result with a HIGHER job number from before a reboot, and the current one
                    $stale = '{"global_status":"success","pre_checks":{},"summary":{"passed":14,"total_checks":14}}'
                    $files = @{ 'install_pre_check.300.json' = @('Mon Nov  2 10:00:00 2026', $stale) }
                    if ($state.precheckJson) { $files['install_pre_check.12.json'] = @('Thu Nov 12 19:34:55 2026', $state.precheckJson) }
                    if ($query -match 'filename:([^,]+)') {
                        $f = $files[$Matches[1]]
                        $out.systemfile = @(@{ filename = $Matches[1]; filecontent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($f[1])); fileencoding = 'BASE64' })
                    } else {
                        $out.systemfile = @($files.Keys | ForEach-Object { @{ filename = $_; filelocation = '/var/tmp'; filemodifiedtime = $files[$_][0]; filesize = $files[$_][1].Length } })
                    }
                } else {
                    # like the device: a GET with filename returns the content and fails for a build-sized file
                    # ("File too large"); a listing (filelocation only) returns name + size without content
                    $listing = @(@{ filename = 'adc.version'; filelocation = '/var/nsinstall'; filesize = 62 })
                    if ($state.uploaded) { $listing += @{ filename = $state.uploaded.name; filelocation = '/var/nsinstall'; filesize = $state.uploaded.size } }
                    if ($query -match 'filename:') { $code = 599; $out = @{ errorcode = 1; message = 'File too large [Use other method to download the file]' } }
                    else { $out.systemfile = $listing }
                }
            }
            '^systembackup$' { $code = 201 }
            '^install$' {
                $b = ($body | ConvertFrom-Json).install
                if ($b.precheck) {
                    if ($state.precheckFail) { $code = 599; $out = @{ errorcode = 3802; message = 'Pre-check failed: config_unsaved' } }
                    else {
                        # like the device: HTTP 201 / errorcode 0 even with warnings; the details are in the result file
                        $checks = [ordered]@{ disk_space = @{ label = 'Disk Space Availability Check'; status = 'success'; message = 'Sufficient disk space' } }
                        if ($state.configChanged) { $checks.config_unsaved = @{ label = 'Unsaved Configuration Check'; status = 'warning'; message = 'Config has been modified since last saved' } }
                        if ($state.precheckWarn) { $checks.gateway_logon_customized = @{ label = 'Customized Portal Logon Pages Check'; status = 'warning'; message = 'Customized portal logon pages found' } }
                        $bad = @($checks.Values | Where-Object { $_.status -ne 'success' }).Count
                        $state.precheckJson = @{ global_status = $(if ($bad) { 'warning' } else { 'success' }); pre_checks = $checks
                                                 summary = @{ passed = 14 - $bad; total_checks = 14; warnings = $bad } } | ConvertTo-Json -Depth 5 -Compress
                        $code = 201
                    }
                } else {
                    $state.installY = [bool]$b.y; $state.jobPolls = 0; $code = 201
                    # like the device: API mode aborts on unsaved config unless ignoreUnsavedConfig is sent
                    $state.installUnsavedFail = $state.configChanged -and -not $b.ignoreUnsavedConfig
                    $out.install = @(@{ id = '211' })
                    if ($b.y) { $state.version = $state.target; $state.loginFailures = 2 }   # -Y: installs and reboots by itself
                }
            }
            '^nsjob/211$' {
                $state.jobPolls++
                if ($state.jobResetOnce -and $state.jobPolls -eq 1) { $abort = $true }    # installer restarts httpd
                elseif ($state.installY) { $code = 503; $out = @{ errorcode = 1; message = 'rebooting' } }
                elseif ($state.installUnsavedFail) { $out.nsjob = @(@{ id = 211; status = 'Failed'; timeelapsed = 25; errorcode = 1490; message = 'Please check the log file /var/tmp/install for more information' }) }
                elseif ($state.jobPolls -lt 2) { $out.nsjob = @(@{ id = 211; status = 'InProgress'; timeelapsed = 30 }) }
                else { $out.nsjob = @(@{ id = 211; status = 'Success'; timeelapsed = 90; errorcode = 5221; message = 'The configuration changes will not take effect until the system is rebooted' }) }
            }
            '^reboot$' { $code = 201; $state.version = $state.target; $state.loginFailures = 2 }
        }
        if ($abort) { $abort = $false; $ctx.Response.Abort(); continue }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 10 -Compress))
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "nitro-fw-test-$port"
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..' 'scripts' '*.ps*1') $work
$update = Join-Path $work 'Update-NsFirmware.ps1'
$build  = Join-Path $work 'build-14.1-73.58_nc_64.tgz'
[IO.File]::WriteAllBytes($build, [byte[]](1..200))
$sha = (Get-FileHash $build -Algorithm SHA256).Hash
# scp stub: records its arguments and "uploads" by telling the fake the file name and size
$scpLog = Join-Path $work 'scp-args.txt'
$scpStub = Join-Path $work 'fake-scp.ps1'
@"
`$args -join ' ' | Set-Content '$scpLog'
`$f = Get-Item `$args[-2]
`$global:FakeUpload = @{ name = `$f.Name; size = `$f.Length }
exit 0
"@ | Set-Content $scpStub
$nsip = "http://127.0.0.1:$port"
$cred = [pscredential]::new('nitro-test', (ConvertTo-SecureString 'fake-nitro-test' -AsPlainText -Force))
$common = @{ NsIp = $nsip; Credential = $cred; PollSeconds = 1; TimeoutMinutes = 2 }

$failures = 0
function Assert($Condition, $Text) {
    if ($Condition) { Write-Host "  PASS  $Text" -ForegroundColor Green }
    else            { Write-Host "  FAIL  $Text" -ForegroundColor Red; $script:failures++ }
}
function Invoke-Update([hashtable]$Params) {
    $err = $null
    $buf = [System.Collections.Generic.List[string]]::new()     # keeps the output written before a throw
    try { & $update @common @Params 6>&1 | ForEach-Object { $buf.Add("$_") } } catch { $err = $_.Exception.Message }
    [pscustomobject]@{ Out = $buf -join "`n"; Error = $err }
}
function Get-Writes { @($state.requests | Where-Object { $_ -match '^POST (install|reboot|systembackup|nsconfig)' }) }
function Reset-Fake([string]$Role = 'Secondary') {
    $state.version = '73.46'; $state.ha[0].state = $Role; $state.loginFailures = 0; $state.precheckFail = $false
    $state.configChanged = $false; $state.precheckWarn = $false; $state.precheckJson = $null; $state.installUnsavedFail = $false
    $state.jobResetOnce = $false
    $state.uploaded = $null; $state.installY = $false; $state.requests.Clear()
}

try {
    Write-Host "`n== 1. -WhatIf" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; WhatIf = $true }
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ((Get-Writes).Count -eq 0) 'nothing sent besides reads'
    Assert ($r.Out -match 'running\s+NetScaler NS14\.1: Build 73\.46' -and $r.Out -match 'HA\s+Secondary') 'shows build and HA role'

    Write-Host "`n== 2. HA primary" -ForegroundColor Cyan
    Reset-Fake 'Primary'
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz' }
    Assert ($r.Error -match 'HA PRIMARY') 'primary refused'
    Assert ((Get-Writes).Count -eq 0) 'nothing changed'

    Write-Host "`n== 3. -BuildUrl -PreCheckOnly" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; PreCheckOnly = $true; NoBackup = $true }
    $w = @(Get-Writes)
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($w.Count -eq 1 -and $w[0] -match '"precheck":true' -and $w[0] -match 'https://files.example.org/build-14.1-73.58_nc_64.tgz') 'only the pre-check sent, with the URL'

    Write-Host "`n== 4. -BuildFile full run" -ForegroundColor Cyan
    Reset-Fake
    # the stub runs in this process: hand its upload to the fake after scp "finished"
    $stubWrapper = Join-Path $work 'scp-wrapper.ps1'
    @"
& '$scpStub' @args
`$state = `$global:FakeState
`$state.uploaded = `$global:FakeUpload
"@ | Set-Content $stubWrapper
    $global:FakeState = $state
    $r = Invoke-Update @{ BuildFile = $build; Sha256 = $sha; ScpCommand = $stubWrapper; SshKey = 'C:\keys\id_test' }
    $w = @(Get-Writes)
    $scp = Get-Content -Raw $scpLog
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($r.Out -match 'SHA256 matches') 'SHA256 checked'
    Assert ($scp -match '-i C:\\keys\\id_test' -and $scp -match 'nsroot@127\.0\.0\.1:/var/nsinstall/') "scp called with key and target ($scp)"
    Assert ($r.Out -match 'uploaded, size checked') 'upload size checked via systemfile'
    Assert (-not (@($state.requests) -match 'systemfile\?args=filename:[^ ]*/var/nsinstall'))'size read from the /var/nsinstall listing, not by file name (File too large)'
    Assert ($w[0] -match '^POST systembackup') 'backup first'
    Assert ($w[1] -match '"precheck":true' -and $w[1] -match 'file:///var/nsinstall/build-14.1-73.58_nc_64.tgz') 'pre-check with file:// URL'
    Assert ($r.Out -match 'pre-check passed \(14/14\)') 'pre-check result file read (14/14)'
    Assert ($w[2] -match '^POST install' -and $w[2] -match '"Async":true' -and $w[2] -notmatch '"y":') 'install async WITHOUT y (old kernel kept)'
    Assert ($r.Out -match 'job 211 InProgress' -and $r.Out -match 'job 211 Success') 'job followed until Success'
    Assert ($w[3] -match '^POST reboot' -and $w[3] -match '"warm":false') 'cold reboot sent'
    Assert ($r.Out -match 'not answering yet' -and $r.Out -match '\[OK\]\s+NS14\.1: Build 73\.58') 'waited through the reboot, new build verified'

    Write-Host "`n== 5. already on target" -ForegroundColor Cyan
    $state.requests.Clear()
    $r = Invoke-Update @{ BuildFile = $build; ScpCommand = $stubWrapper }
    Assert ($r.Out -match 'already on NS14\.1: Build 73\.58' -and (Get-Writes).Count -eq 0) 'nothing to do'

    Write-Host "`n== 6. -DeleteOldKernels" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; DeleteOldKernels = $true; NoBackup = $true }
    $w = @(Get-Writes)
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert (@($w | Where-Object { $_ -match '^POST install' -and $_ -match '"y":true' }).Count -eq 1) 'install with y'
    Assert (-not ($w -match '^POST reboot')) 'no separate reboot (installer reboots itself)'
    Assert ($r.Out -match '\[OK\]\s+NS14\.1: Build 73\.58') 'new build verified'

    Write-Host "`n== 7. failed pre-check" -ForegroundColor Cyan
    Reset-Fake; $state.precheckFail = $true
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; NoBackup = $true }
    Assert ($r.Error -match 'Pre-check failed: 3802') "stops with the pre-check error ($($r.Error))"
    Assert (-not ((Get-Writes) -match '"Async"')) 'no install sent'

    Write-Host "`n== 8. unsaved config" -ForegroundColor Cyan
    Reset-Fake; $state.configChanged = $true
    Remove-Item $scpLog -ErrorAction SilentlyContinue
    $r = Invoke-Update @{ BuildFile = $build; ScpCommand = $stubWrapper }
    Assert ($r.Error -match 'unsaved changes' -and $r.Error -match '-SaveConfig') "stops before anything is sent ($($r.Error))"
    Assert ((Get-Writes).Count -eq 0 -and -not (Test-Path $scpLog)) 'no upload, no writes'
    $r = Invoke-Update @{ BuildFile = $build; ScpCommand = $stubWrapper; WhatIf = $true }
    Assert (-not $r.Error -and $r.Out -match 'config\s+UNSAVED') '-WhatIf reports it without stopping'

    Write-Host "`n== 9. -SaveConfig" -ForegroundColor Cyan
    Reset-Fake; $state.configChanged = $true
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; SaveConfig = $true }
    $w = @(Get-Writes)
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($w[0] -match '^POST nsconfig\?action=save' -and $w[1] -match '^POST systembackup') 'saved, then backup'
    Assert ($r.Out -match 'pre-check passed \(14/14\)' -and $r.Out -match '\[OK\]\s+NS14\.1: Build 73\.58') 'clean pre-check, upgraded'

    Write-Host "`n== 10. pre-check warning (HTTP 201)" -ForegroundColor Cyan
    Reset-Fake; $state.precheckWarn = $true
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; NoBackup = $true }
    Assert ($r.Error -match 'Pre-check warning: gateway_logon_customized \(13/14') "stops on the warning from the newest result file ($($r.Error))"
    Assert ($r.Out -match '\[WARNING\] Customized Portal Logon Pages Check') 'warning printed'
    Assert (-not ((Get-Writes) -match '"Async"')) 'no install sent'

    Write-Host "`n== 11. -IgnoreUnsavedConfig" -ForegroundColor Cyan
    Reset-Fake; $state.configChanged = $true; $state.jobResetOnce = $true
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; IgnoreUnsavedConfig = $true }
    $w = @(Get-Writes)
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($r.Out -match 'NITRO not answering .*logging in again' -and $r.Out -match 'job 211 Success') 'connection reset during the job: logged in again, job followed to Success'
    Assert (-not ($w -match '^POST nsconfig')) 'config not saved'
    Assert (@($w | Where-Object { $_ -match '^POST install' -and $_ -match '"ignoreUnsavedConfig":true' }).Count -eq 2) 'ignoreUnsavedConfig sent with pre-check and install'
    Assert ($r.Out -match '\[IGNORED\] Unsaved Configuration Check' -and $r.Out -match '\[OK\]\s+NS14\.1: Build 73\.58') 'warning shown as IGNORED, upgraded'
    $r = Invoke-Update @{ BuildUrl = 'https://files.example.org/build-14.1-73.58_nc_64.tgz'; IgnoreUnsavedConfig = $true; SaveConfig = $true }
    Assert ($r.Error -match 'not both') 'with -SaveConfig: refused'
}
finally {
    $listener.Stop()
    $server | Stop-Job -PassThru | Remove-Job -Force
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable FakeState, FakeUpload -Scope Global -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures) { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
