#Requires -Version 7.2
<#
.SYNOPSIS
    Offline test of Invoke-NsLasLicense.ps1 against a fake NITRO API (no NetScaler needed).

.DESCRIPTION
    One HttpListener plays several appliances, one per path prefix (http://127.0.0.1:<port>/<name>). They answer like
    NetScaler 14.1 in the lab (offline LAS, Fixed Bandwidth):
      ok        LAS (Fixed Bandwidth), ACTIVE, 427 days
      expiring  LAS (Fixed Bandwidth), ACTIVE, 12 days
      express   Express, LAS INACTIVE (not licensed through LAS)
      broken    login works, GET nslaslicense fails
      ns01      the appliance for Request / Activate (Express until the activation, LAS after the reboot)
    plus one address where nothing listens (unreachable). Checks:
      1. Status, all fine: exit 0, read-only, -PassThru objects
      2. Status, expiring + unreadable + unreachable among several: every appliance read, summary table, exit 1
      3. -WarnDays 500 makes a healthy license WARN
      4. pin checks: wrong number of pins refused before any request
      5. Request: request created, .tgz downloaded and summarised; -UseHostname sent
      6. Activate: upload + apply with fixedbandwidth; an existing file is replaced; no reboot without -Reboot
      7. Activate -Reboot: save, warm reboot, wait, licensing mode LAS afterwards
      8. Activate -Reboot on an HA primary: refused before anything is written (-Force allows it)
      9. activation of another appliance (LPEID): stops with the hint
     10. -WhatIf for Request and Activate: no login at all; Request/Activate with several -NsIp refused
#>
$ErrorActionPreference = 'Stop'

function New-Appliance([string]$Mode, [string]$Las, $Days, [string]$Renewal) {
    @{ mode = $Mode; las = $Las; days = $Days; renewal = $Renewal; loginFailures = 0; lasError = $false; ha = 'standalone'
       files = @{}; applied = $null; rebooted = $false }
}
$state = [hashtable]::Synchronized(@{
    nodes    = @{}
    requests = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    reqTgz   = $null
})
function Reset-Fake {
    $state.nodes.ok       = New-Appliance 'LAS (Fixed Bandwidth)' 'ACTIVE' 427 '2027-10-31'
    $state.nodes.expiring = New-Appliance 'LAS (Fixed Bandwidth)' 'ACTIVE' 70 '2026-11-24'
    $state.nodes.expiring.licDays = 12       # show ns license counts less than show ns laslicense
    $state.nodes.express  = New-Appliance 'EXPRESS' 'INACTIVE' 0 'Thu Jan  1 00:00:00 1970'
    $state.nodes.broken   = New-Appliance 'LAS (Fixed Bandwidth)' 'ACTIVE' 300 ''
    $state.nodes.broken.lasError = $true
    $state.nodes.ns01     = New-Appliance 'Express' 'INACTIVE' 0 ''
    $state.requests.Clear()
}
Reset-Fake

$tcp = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tcp.Start()
$port = $tcp.LocalEndpoint.Port; $tcp.Stop()
$tcp = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tcp.Start()
$deadPort = $tcp.LocalEndpoint.Port; $tcp.Stop()       # nothing listens here
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

$server = Start-ThreadJob -ArgumentList $listener, $state -ScriptBlock {
    param($listener, $state)
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        $req = $ctx.Request
        $code = 200; $out = @{ errorcode = 0; message = 'Done' }
        $null = $req.Url.AbsolutePath -match '^/([^/]+)/nitro/v1/config/(.*)$'
        $nodeName = $Matches[1]; $path = [uri]::UnescapeDataString($Matches[2])
        $query = [uri]::UnescapeDataString($req.Url.Query)
        $body = if ($req.HasEntityBody) { [IO.StreamReader]::new($req.InputStream).ReadToEnd() } else { '' }
        [void]$state.requests.Add("$nodeName $($req.HttpMethod) $path$query $body")
        $n = $state.nodes[$nodeName]
        if (-not $n) { $code = 404; $out = @{ errorcode = 1; message = 'no such appliance' } }
        else {
            switch -Regex ($path) {
                '^login$' {
                    if ($n.loginFailures -gt 0) { $n.loginFailures--; $code = 503; $out = @{ errorcode = 1; message = 'Service unavailable' } }
                    else { $out.sessionid = "session-$nodeName" }
                }
                '^logout$' { }
                '^nslicense$' {
                    $ld = if ($n.mode -notmatch 'LAS') { '0' } elseif ($null -ne $n.licDays) { "$($n.licDays)" } else { "$($n.days)" }
                    $out.nslicense = @(@{ licensingmode = $n.mode; modelid = $(if ($n.mode -match 'LAS') { '5000' } else { '20' }); daystoexpiration = $ld })
                }
                '^nslaslicense$' {
                    if ($req.HttpMethod -eq 'GET') {
                        if ($n.lasError) { $code = 599; $out = @{ errorcode = 344; message = 'Internal error while reading LAS license' } }
                        else { $out.nslaslicense = @(@{ status = $n.las; daystoexpiration = "$($n.days)"; renewalnextdate = $n.renewal }) }
                    } elseif ($query -match 'action=apply') {
                        $b = ($body | ConvertFrom-Json).nslaslicense
                        if (-not $b.fixedbandwidth) { $code = 599; $out = @{ errorcode = 3613; message = 'Failed to parse las license file' } }
                        elseif ($b.filename -match 'other') { $code = 599; $out = @{ errorcode = 3613; message = 'License blob is invalid: blob not applicable for this LPEID' } }
                        elseif (-not $n.files.ContainsKey("$($b.filelocation)/$($b.filename)")) { $code = 599; $out = @{ errorcode = 1; message = 'file not found' } }
                        else { $n.las = 'ACTIVE'; $n.days = 365; $n.renewal = '2027-11-12'; $n.applied = $b.filename; $code = 201 }
                    }
                }
                '^hanode$' {
                    $out.hanode = if ($n.ha -eq 'standalone') { @(@{ id = 0; ipaddress = '192.0.2.10'; state = 'StandAlone' }) }
                                  else { @(@{ id = 0; ipaddress = '192.0.2.10'; state = $n.ha }, @{ id = 1; ipaddress = '192.0.2.11'; state = 'Secondary' }) }
                }
                '^nslicenseactivationdata$' {
                    $fname = if ($query -match 'usehostname:true') { 'ns01_activation_request.tgz' } else { '9f2c0e_activation_request.tgz' }
                    $n.files["/nsconfig/license/$fname"] = $state.reqTgz
                    $out.nslicenseactivationdata = @(@{ filename = $fname })
                }
                '^systemfile/(.+)$' {
                    $key = "/nsconfig/license/$($Matches[1])"
                    if ($req.HttpMethod -eq 'GET') {
                        if ($query -notmatch 'filelocation:/nsconfig/license') { $code = 599; $out = @{ errorcode = 1; message = 'wrong location' } }
                        elseif ($n.files.ContainsKey($key)) { $out.systemfile = @(@{ filename = $Matches[1]; filecontent = $n.files[$key]; fileencoding = 'BASE64' }) }
                        else { $code = 599; $out = @{ errorcode = 1; message = 'No such file or directory' } }
                    } elseif ($req.HttpMethod -eq 'DELETE') { $n.files.Remove($key) }
                }
                '^systemfile$' {
                    $b = ($body | ConvertFrom-Json).systemfile
                    $key = "$($b.filelocation)/$($b.filename)"
                    if ($n.files.ContainsKey($key)) { $code = 599; $out = @{ errorcode = 1642; message = 'File already exists' } }
                    else { $n.files[$key] = $b.filecontent; $code = 201 }
                }
                '^nsconfig$' { $code = 201 }
                '^reboot$' {
                    $code = 201; $n.rebooted = $true; $n.loginFailures = 2
                    if ($n.las -eq 'ACTIVE') { $n.mode = 'LAS (Fixed Bandwidth)' }
                }
            }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 10 -Compress))
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "nitro-las-test-$port"
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..' 'scripts' '*.ps*1') $work
$las = Join-Path $work 'Invoke-NsLasLicense.ps1'
# a real request .tgz (as the NetScaler writes it), served base64 by the fake
$reqDir = Join-Path $work 'req'; New-Item -ItemType Directory $reqDir | Out-Null
@{ hostname = 'ns01'; lsguid = '9f2c0e'; lsbuild = 'NS14.1 Build 73.58'; renewalinput = @{ lastactivationid = '' } } |
    ConvertTo-Json | Set-Content (Join-Path $reqDir 'ns_offline_activation_request.json')
$reqFile = Join-Path $work 'request.tgz'
tar -czf $reqFile -C $reqDir ns_offline_activation_request.json
if ($LASTEXITCODE -ne 0) { throw 'tar failed - needed to build the test request' }
$state.reqTgz = [Convert]::ToBase64String([IO.File]::ReadAllBytes($reqFile))
$outDir = Join-Path $work 'out'; New-Item -ItemType Directory $outDir | Out-Null
$blob = Join-Path $work 'NS_9f2c0e_activation.blob.tgz'; [IO.File]::WriteAllBytes($blob, [byte[]](1..64))
$otherBlob = Join-Path $work 'NS_other_activation.blob.tgz'; [IO.File]::WriteAllBytes($otherBlob, [byte[]](1..64))

$base = "http://127.0.0.1:$port"
$cred = [pscredential]::new('nitro-test', (ConvertTo-SecureString 'fake-nitro-test' -AsPlainText -Force))
$fakePin = 'sha256//' + [Convert]::ToBase64String([byte[]]::new(32))

$failures = 0
function Assert($Condition, $Text) {
    if ($Condition) { Write-Host "  PASS  $Text" -ForegroundColor Green }
    else            { Write-Host "  FAIL  $Text" -ForegroundColor Red; $script:failures++ }
}
function Invoke-Las([hashtable]$Params) {
    $err = $null; $objs = @()
    $buf = [System.Collections.Generic.List[string]]::new()     # keeps the output written before a throw
    $global:LASTEXITCODE = 0
    try {
        & $las -Credential $cred @Params 6>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord] -or $_ -is [string]) { $buf.Add("$_") } else { $objs += $_ }
        }
    } catch { $err = $_.Exception.Message }
    [pscustomobject]@{ Out = $buf -join "`n"; Error = $err; Exit = $global:LASTEXITCODE; Objects = $objs }
}
function Get-Writes([string]$Node) { @($state.requests | Where-Object { $_ -match "^$Node (POST|PUT|DELETE) (?!login|logout)" }) }
function Get-Requests([string]$Node) { @($state.requests | Where-Object { $_ -match "^$Node " }) }

try {
    Write-Host "`n== 1. Status, all fine" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Las @{ NsIp = "$base/ok", "$base/express"; PassThru = $true; NoProxy = $true }
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($r.Exit -eq 0) "exit code 0 ($($r.Exit))"
    Assert ($r.Out -match '\[OK\]\s+\S+/ok\s+mode LAS \(Fixed Bandwidth\), model 5000, LAS ACTIVE, 427 days, renewal 2027-10-31') 'OK line'
    Assert ($r.Out -match '\[NO-LAS\]\s+\S+/express\s+mode EXPRESS, model 20, LAS INACTIVE \(not licensed through LAS\)') 'Express appliance shown as NO-LAS, without days and epoch renewal'
    Assert ($r.Objects[1].RenewalNext -eq '' -and $r.Out -notmatch '1970') 'epoch renewal date left out'
    Assert ((Get-Writes 'ok').Count -eq 0 -and (Get-Writes 'express').Count -eq 0) 'read-only (only login/logout posted)'
    Assert ($r.Objects.Count -eq 2 -and $r.Objects[0].DaysToExpiration -eq 427 -and $r.Objects[1].Result -eq 'NO-LAS') '-PassThru objects'

    Write-Host "`n== 2. Status, expiring + unreadable + unreachable among several" -ForegroundColor Cyan
    Reset-Fake
    $ips = "$base/ok", "http://127.0.0.1:$deadPort", "$base/broken", "$base/expiring", "$base/express"
    $r = Invoke-Las @{ NsIp = $ips; PassThru = $true }
    Assert (-not $r.Error) "no error thrown ($($r.Error))"
    Assert ($r.Exit -eq 1) "exit code 1 ($($r.Exit))"
    Assert ($r.Objects.Count -eq 5) 'all five reported'
    Assert (($r.Objects | ForEach-Object Result) -join ',' -eq 'OK,ERROR,ERROR,WARN,NO-LAS') "results in order ($(($r.Objects | ForEach-Object Result) -join ','))"
    Assert ((Get-Requests 'expiring') -match 'GET nslaslicense' -and (Get-Requests 'express') -match 'GET nslaslicense') 'went on after the unreachable and the broken one'
    Assert ($r.Out -match '\[WARN\]\s+\S+/expiring .*LAS ACTIVE, 12 days \(license 12, laslicense 70\).*below 30 days') 'expiring one WARN on the smaller counter (show ns license)'
    Assert ($r.Objects[3].DaysToExpiration -eq 12 -and $r.Objects[3].LasDays -eq 70 -and $r.Objects[3].LicenseDays -eq 12) 'both counters in -PassThru'
    Assert ($r.Out -match '\[ERROR\]\s+\S+/broken\s+GET nslaslicense failed: 344') 'broken one ERROR with the NITRO message'
    Assert ($r.Out -match "\[ERROR\]\s+http://127\.0\.0\.1:$deadPort") 'unreachable one ERROR'
    Assert ($r.Out -match 'LAS license status \(5 appliance\(s\)' -and $r.Out -match 'NsIp\s+Result\s+LicensingMode' -and $r.Out -match '3 of 5 need attention') 'summary table at the end'
    Assert ((Get-Requests 'broken') -match 'POST logout') 'logged out of the broken one'

    Write-Host "`n== 3. -WarnDays 500" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Las @{ NsIp = "$base/ok"; WarnDays = 500 }
    Assert ($r.Exit -eq 1 -and $r.Out -match '\[WARN\]\s+\S+/ok .*below 500 days') "healthy license WARN below 500 days (exit $($r.Exit))"

    Write-Host "`n== 4. pin checks" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Las @{ NsIp = "$base/ok", "$base/expiring", "$base/express"; PinnedPublicKey = $fakePin, $fakePin }
    Assert ($r.Error -match 'one pin for all appliances or one per -NsIp' -and $state.requests.Count -eq 0) "2 pins for 3 appliances refused before any request ($($r.Error))"

    Write-Host "`n== 5. Request" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Request'; OutDir = $outDir }
    $saved = Join-Path $outDir '9f2c0e_activation_request.tgz'
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ((Get-Requests 'ns01') -match '^ns01 GET nslicenseactivationdata ' -and -not ((Get-Requests 'ns01') -match 'usehostname')) 'request created (no host name)'
    Assert ((Test-Path $saved) -and (Get-FileHash $saved).Hash -eq (Get-FileHash $reqFile).Hash) 'request .tgz downloaded byte for byte'
    Assert ($r.Out -match 'request: hostname ns01, id 9f2c0e, build NS14\.1 Build 73\.58') 'request summarised'
    Assert ((Get-Writes 'ns01').Count -eq 0) 'nothing written'
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Request'; OutDir = $outDir; UseHostname = $true }
    Assert (-not $r.Error -and ((Get-Requests 'ns01') -match 'nslicenseactivationdata\?args=usehostname:true') -and (Test-Path (Join-Path $outDir 'ns01_activation_request.tgz'))) '-UseHostname sent, host-name file saved'
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Request'; OutDir = (Join-Path $work 'missing') }
    Assert ($r.Error -match 'is not a folder') 'missing -OutDir refused'

    Write-Host "`n== 6. Activate without -Reboot" -ForegroundColor Cyan
    Reset-Fake
    $state.nodes.ns01.files['/nsconfig/license/NS_9f2c0e_activation.blob.tgz'] = 'b2xk'    # copy from an earlier try
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Activate'; ActivationFile = $blob; Confirm = $false }
    $w = Get-Writes 'ns01'
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($w[0] -match '^ns01 POST systemfile ' -and $w[1] -match '^ns01 DELETE systemfile/NS_9f2c0e_activation\.blob\.tgz\?args=filelocation:/nsconfig/license' -and $w[2] -match '^ns01 POST systemfile ') 'existing file deleted and uploaded again'
    Assert ($state.nodes.ns01.files['/nsconfig/license/NS_9f2c0e_activation.blob.tgz'] -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($blob))) 'new content on the appliance'
    Assert ($w[3] -match '^ns01 POST nslaslicense\?action=apply ' -and $w[3] -match '"fixedbandwidth":true' -and $w[3] -match '"filelocation":"/nsconfig/license"') 'apply with fixedbandwidth'
    Assert ($r.Out -match 'after the import:\s+\[OK\]\s+\S+/ns01\s+mode Express, .*LAS ACTIVE, 365 days') 'LAS ACTIVE shown, mode still Express'
    Assert (-not ($w -match '^ns01 POST (reboot|nsconfig)') -and $r.Out -match 'licensing mode changes after a reboot') 'no save, no reboot, hint shown'

    Write-Host "`n== 7. Activate -Reboot" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Activate'; ActivationFile = $blob; Reboot = $true; PollSeconds = 1; TimeoutMinutes = 1; Confirm = $false }
    $w = Get-Writes 'ns01'
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert (($w | ForEach-Object { ($_ -split ' ')[2] -replace '\?.*' }) -join ',' -eq 'systemfile,nslaslicense,nsconfig,reboot') "upload, apply, save, reboot ($(($w | ForEach-Object { ($_ -split ' ')[2] -replace '\?.*' }) -join ','))"
    Assert ($w[3] -match '"warm":true') 'warm reboot'
    Assert ($r.Out -match 'not answering yet' -and $r.Out -match 'after the reboot:\s+\[OK\]\s+\S+/ns01\s+mode LAS \(Fixed Bandwidth\), model 5000, LAS ACTIVE, 365 days') 'waited, LAS (Fixed Bandwidth) afterwards'

    Write-Host "`n== 8. Activate -Reboot on an HA primary" -ForegroundColor Cyan
    Reset-Fake; $state.nodes.ns01.ha = 'Primary'
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Activate'; ActivationFile = $blob; Reboot = $true; PollSeconds = 1; TimeoutMinutes = 1; Confirm = $false }
    Assert ($r.Error -match 'HA PRIMARY' -and (Get-Writes 'ns01').Count -eq 0) "refused before anything is written ($($r.Error))"
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Activate'; ActivationFile = $blob; Reboot = $true; Force = $true; PollSeconds = 1; TimeoutMinutes = 1; Confirm = $false }
    Assert (-not $r.Error -and $state.nodes.ns01.rebooted) "-Force: activated and rebooted ($($r.Error))"

    Write-Host "`n== 9. activation of another appliance" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Activate'; ActivationFile = $otherBlob; Reboot = $true; Confirm = $false }
    Assert ($r.Error -match 'Stopping at failed step: apply ns laslicense' -and $r.Out -match 'does not fit this NetScaler') "stops with the LPEID hint ($($r.Error))"
    Assert (-not ((Get-Writes 'ns01') -match '^ns01 POST (reboot|nsconfig)')) 'no save, no reboot'

    Write-Host "`n== 10. -WhatIf and one-appliance rule" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Request'; OutDir = $outDir; WhatIf = $true }
    Assert (-not $r.Error -and $state.requests.Count -eq 0) "Request -WhatIf: no request at all ($($r.Error))"
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Activate'; ActivationFile = $blob; Reboot = $true; WhatIf = $true }
    Assert (-not $r.Error -and $state.requests.Count -eq 0) "Activate -WhatIf: no request at all ($($r.Error))"
    $r = Invoke-Las @{ NsIp = "$base/ns01", "$base/ok"; Action = 'Activate'; ActivationFile = $blob; Confirm = $false }
    Assert ($r.Error -match 'one NetScaler at a time' -and $state.requests.Count -eq 0) 'Activate with two -NsIp refused'
    $r = Invoke-Las @{ NsIp = "$base/ns01"; Action = 'Activate'; ActivationFile = (Join-Path $work 'nope.tgz'); Confirm = $false }
    Assert ($r.Error -match 'not found' -and $state.requests.Count -eq 0) 'missing activation file refused'
    $r = Invoke-Las @{ NsIp = "$base/ok"; Reboot = $true }
    Assert ($r.Error -match 'belong to -Action Activate' -and $state.requests.Count -eq 0) 'Status with -Reboot refused'
}
finally {
    $listener.Stop()
    $server | Stop-Job -PassThru | Remove-Job -Force
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures) { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
