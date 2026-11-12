#Requires -Version 7.2
<#
.SYNOPSIS
    Offline test of Deploy-NsSite.ps1 against a fake NITRO API over TLS and a stub of Deploy-NsVpx.ps1 (no ESXi,
    no NetScaler needed).

.DESCRIPTION
    The fake serves NITRO over HTTPS with a throwaway self-signed certificate, so the trust-on-first-use pin of the
    Vpx phase (Get-NitroPin) and the pinned NITRO calls run for real. The config files carry "nsip": 192.0.2.10; every
    call has to reach the fake through the site's nsip (-NsIp). Prompts (Get-Credential, Read-Host) are replaced by
    functions that fail the test. Checks:
      1. -WhatIf: the stub gets -WhatIf and the site's parameters, no NITRO call, no prompt
      2. site file errors stop before any prompt
      3. full run: stub called with Nsip + parameters, key pinned, Base -> Certificates -> Objects in order, all on
         the site's nsip, only the secrets the files use
      4. -SkipVpx -From Objects -PinnedPublicKey: only the object files, no stub
      5. wrong pin: stopped before the login
      6. wrong -Credential: stopped at the login check, nothing written
      7. certificates mode acme: certKey present -> continues with the objects, prints the pinned acme-ns command
#>
$ErrorActionPreference = 'Stop'

# --- TLS certificate of the fake + its pin ---------------------------------------------------------------------------
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$csr = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=ns-test', $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$tmpCert = $csr.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(1))
# Windows SChannel needs a key from a key store, not the ephemeral one -> round trip through PKCS#12
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $tmpCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12), [string]$null,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
$sha = [System.Security.Cryptography.SHA256]::Create()
$pin = 'sha256//' + [Convert]::ToBase64String($sha.ComputeHash($cert.PublicKey.ExportSubjectPublicKeyInfo()))
$otherPin = 'sha256//' + [Convert]::ToBase64String($sha.ComputeHash([byte[]](1..32)))

# --- fake NITRO over HTTPS -------------------------------------------------------------------------------------------
$state = [hashtable]::Synchronized(@{
    objects  = [hashtable]::Synchronized(@{})
    requests = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    connections = 0
})
$tcp = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tcp.Start()
$port = $tcp.LocalEndpoint.Port

$server = Start-ThreadJob -ArgumentList $tcp, $cert, $state -ScriptBlock {
    param($tcp, $cert, $state)
    function Read-Line($s) {
        $b = [System.Collections.Generic.List[byte]]::new()
        while (($c = $s.ReadByte()) -ge 0) { if ($c -eq 10) { break }; if ($c -ne 13) { $b.Add([byte]$c) } }
        if ($c -lt 0 -and -not $b.Count) { return $null }
        [Text.Encoding]::ASCII.GetString($b.ToArray())
    }
    while ($true) {
        try { $client = $tcp.AcceptTcpClient() } catch { break }
        try {
            $state.connections++
            $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
            $ssl.AuthenticateAsServer($cert, $false, [System.Security.Authentication.SslProtocols]::None, $false)
            $first = Read-Line $ssl
            if (-not $first) { continue }                                   # Get-NitroPin: handshake only
            $method, $target, $null = $first -split ' '
            $len = 0
            while ($h = Read-Line $ssl) { if ($h -match '^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
            $buf = [byte[]]::new($len); $got = 0
            while ($got -lt $len) { $n = $ssl.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
            $text = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
            $uri = [uri]"https://fake$target"
            $path = $uri.AbsolutePath -replace '^/nitro/v1/config/', ''
            $res, $key = $path -split '/', 2
            if ($key) { $key = [uri]::UnescapeDataString($key) }
            [void]$state.requests.Add("$method $path $text")
            $data = if ($text) { ($text | ConvertFrom-Json -AsHashtable)[$res] } else { $null }
            $code = 200; $out = @{ errorcode = 0; message = 'Done' }
            if ($res -eq 'login') {
                if ($data.password -eq 'right-test-password') { $out.sessionid = 'test-session' }
                else { $code = 401; $out = @{ errorcode = 354; message = 'Invalid username or password' } }
            }
            elseif ($res -in 'logout', 'nsconfig', 'systembackup', 'hafiles') { }
            elseif ($method -eq 'GET' -and $key) {
                if ($state.objects.ContainsKey("$res|$key")) { $out[$res] = @($state.objects["$res|$key"]) }
                else { $code = 404; $out = @{ errorcode = 258; message = "No such resource [$key]" } }
            }
            elseif ($method -eq 'POST') {
                $k = $data.name ?? $data.certkey ?? $data.filename ?? $data.labelname
                $state.objects["$res|$k"] = $data; $code = 201
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 10 -Compress))
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code X`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $ssl.Write($head, 0, $head.Length); $ssl.Write($bytes, 0, $bytes.Length); $ssl.Flush()
        }
        catch { }
        finally { $client.Dispose() }
    }
}

# --- test setup --------------------------------------------------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) "nitro-site-test-$port"
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..' 'scripts' '*.ps*1') $work
$site = Join-Path $work 'Deploy-NsSite.ps1'
$fileNsip = 'https://192.0.2.10'   # inside the files: must never be used
function Write-Json([string]$Name, $Object) { $p = Join-Path $work $Name; $Object | ConvertTo-Json -Depth 10 | Set-Content $p; $p }
Write-Json 'base.json' @{ nsip = $fileNsip; steps = @(@{ resource = 'server'; data = @{ name = 'srv_base'; ipaddress = '192.0.2.20' } }) } | Out-Null
Write-Json 'objects.json' @{ nsip = $fileNsip; steps = @(
    @{ resource = 'lbvserver'; data = @{ name = 'lb_site'; servicetype = 'SSL' } }
    @{ resource = 'server'; data = @{ name = 'srv_secret'; ipaddress = '192.0.2.21'; comment = '${env:TEST_SITE_SECRET}' } }
) } | Out-Null
Set-Content (Join-Path $work 'site.crt') $cert.ExportCertificatePem()
Set-Content (Join-Path $work 'site.key') $rsa.ExportPkcs8PrivateKeyPem()
Write-Json 'certs.json' @{ nsip = $fileNsip; certificates = @(@{ name = 'site_cert'; certFile = 'site.crt'; keyFile = 'site.key' }) } | Out-Null
# Deploy-NsVpx.ps1 stand-in: records what it was called with
$stubLog = Join-Path $work 'vpx-args.json'
$stub = Join-Path $work 'Fake-NsVpx.ps1'
@"
param(`$EsxHost, `$VmName, `$Datastore, `$Nsip, `$Snip, [string[]]`$DnsServer, [switch]`$NoProxy, [switch]`$WhatIf)
@{ EsxHost = `$EsxHost; VmName = `$VmName; Datastore = `$Datastore; Nsip = `$Nsip; Snip = `$Snip; DnsServer = `$DnsServer
   NoProxy = [bool]`$NoProxy; WhatIf = [bool]`$WhatIf } | ConvertTo-Json | Set-Content '$stubLog' -WhatIf:`$false
"@ | Set-Content $stub
function New-Site([string]$Name, [hashtable]$Change = @{}) {
    $s = [ordered]@{
        nsip = "https://127.0.0.1:$port"; noProxy = $true
        vpx = @{ script = 'Fake-NsVpx.ps1'; parameters = @{ EsxHost = 'esx01.example.org'; VmName = 'ns01'; Datastore = 'datastore1'
                                                            Snip = '192.0.2.11'; DnsServer = @('192.0.2.53') } }
        base = @('base.json'); certificates = @{ mode = 'files'; file = 'certs.json' }; objects = @('objects.json')
        secrets = @('TEST_SITE_SECRET', 'TEST_UNUSED_SECRET')
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    Write-Json $Name $s
}
$good = [pscredential]::new('nsroot', (ConvertTo-SecureString 'right-test-password' -AsPlainText -Force))
$bad  = [pscredential]::new('nsroot', (ConvertTo-SecureString 'wrong-test-password' -AsPlainText -Force))
$env:TEST_SITE_SECRET = 'site-secret-value'
Remove-Item Env:TEST_UNUSED_SECRET -ErrorAction SilentlyContinue
# no prompt may happen: these functions win over the cmdlets inside the scripts
$global:SitePrompts = [System.Collections.ArrayList]::new()
function global:Get-Credential { [void]$global:SitePrompts.Add("Get-Credential $args"); throw "unexpected prompt: Get-Credential $args" }
function global:Read-Host      { [void]$global:SitePrompts.Add("Read-Host $args");      throw "unexpected prompt: Read-Host $args" }

$failures = 0
function Assert($Condition, $Text) {
    if ($Condition) { Write-Host "  PASS  $Text" -ForegroundColor Green }
    else            { Write-Host "  FAIL  $Text" -ForegroundColor Red; $script:failures++ }
}
function Invoke-Site([hashtable]$Params) {
    $err = $null
    $buf = [System.Collections.Generic.List[string]]::new()
    try { & $site @Params *>&1 | ForEach-Object { $buf.Add("$_") } } catch { $err = $_.Exception.Message }
    [pscustomobject]@{ Out = $buf -join "`n"; Error = $err }
}
function Reset-Fake { $state.objects.Clear(); $state.requests.Clear(); $state.connections = 0; $global:SitePrompts.Clear(); Remove-Item $stubLog -ErrorAction SilentlyContinue }
function Get-Writes { @($state.requests | Where-Object { $_ -match '^(POST|PUT|DELETE) ' -and $_ -notmatch '^POST (login|logout) ' }) }
function Get-Index([string]$Pattern) { $w = Get-Writes; for ($i = 0; $i -lt $w.Count; $i++) { if ($w[$i] -match $Pattern) { return $i } }; -1 }

try {
    Write-Host "`n== 1. -WhatIf" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Site @{ SiteFile = (New-Site 'site.json'); WhatIf = $true }
    $v = if (Test-Path $stubLog) { Get-Content -Raw $stubLog | ConvertFrom-Json }
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($v.WhatIf -and $v.Nsip -eq '127.0.0.1' -and $v.EsxHost -eq 'esx01.example.org' -and $v.Snip -eq '192.0.2.11' -and $v.NoProxy) 'stub got -WhatIf, the host of nsip and the site parameters'
    Assert ($state.connections -eq 0) 'no NITRO connection'
    Assert ($global:SitePrompts.Count -eq 0) 'no prompt'
    Assert ($r.Out -match 'WhatIf: Base - base\.json' -and $r.Out -match 'Certificates \(files\) - certs\.json' -and $r.Out -match 'Objects - objects\.json') 'files listed per phase'

    Write-Host "`n== 2. site file errors" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Site @{ SiteFile = (New-Site 'bad1.json' @{ vpx = @{ script = 'Fake-NsVpx.ps1'; parameters = @{ Nsip = '192.0.2.99' } } }) }
    Assert ($r.Error -match "NSIP once in 'nsip'") "Nsip in vpx.parameters refused ($($r.Error))"
    $r = Invoke-Site @{ SiteFile = (New-Site 'bad2.json' @{ objects = @('missing.json') }) }
    Assert ($r.Error -match 'config file not found') "missing object file refused ($($r.Error))"
    $r = Invoke-Site @{ SiteFile = (New-Site 'bad3.json' @{ certificates = @{ mode = 'acme' } }) }
    Assert ($r.Error -match "needs 'certKeys'") "acme without certKeys refused ($($r.Error))"
    Assert ($global:SitePrompts.Count -eq 0 -and $state.connections -eq 0 -and -not (Test-Path $stubLog)) 'before any prompt, deploy or connection'

    Write-Host "`n== 3. full run (Vpx stub)" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Site @{ SiteFile = (New-Site 'site.json'); Credential = $good }
    $v = if (Test-Path $stubLog) { Get-Content -Raw $stubLog | ConvertFrom-Json }
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($v -and -not $v.WhatIf -and $v.Nsip -eq '127.0.0.1' -and $v.VmName -eq 'ns01' -and $v.DnsServer -contains '192.0.2.53') 'stub deployed with Nsip + parameters'
    Assert ($r.Out -match [regex]::Escape("management key pin for this run: $pin")) 'key pinned on first contact (the fake''s key)'
    $iBase = Get-Index '^POST server .*srv_base'; $iCert = Get-Index '^POST sslcertkey '; $iObj = Get-Index '^POST lbvserver .*lb_site'
    Assert ($iBase -ge 0 -and $iCert -gt $iBase -and $iObj -gt $iCert) "Base -> Certificates -> Objects in order ($iBase, $iCert, $iObj)"
    Assert ((Get-Index '^POST systemfile ') -ge 0) 'certificate files uploaded'
    Assert ((Get-Writes) -match 'site-secret-value') 'secret from the environment used'
    Assert ($global:SitePrompts.Count -eq 0) 'no prompt (unused secret not asked for, -Credential used)'
    Assert ($env:TEST_SITE_SECRET -eq 'site-secret-value') 'a secret set before the run is kept'
    Assert ($r.Out -notmatch '192\.0\.2\.10') 'nsip of the files never used'
    Assert ($r.Out -match 'Site site\.json done: Vpx -> Base -> Certificates -> Objects') 'all four phases done'

    Write-Host "`n== 4. -SkipVpx -From Objects" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Site @{ SiteFile = (New-Site 'site.json'); Credential = $good; SkipVpx = $true; From = 'Objects'; PinnedPublicKey = $pin }
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert (-not (Test-Path $stubLog)) 'no VPX deploy'
    Assert ((Get-Index 'srv_base') -lt 0 -and (Get-Index '^POST sslcertkey ') -lt 0 -and (Get-Index 'lb_site') -ge 0) 'only the object files'
    Assert ($r.Out -match 'phases: Objects') 'phase list = Objects'

    Write-Host "`n== 5. wrong pin" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Site @{ SiteFile = (New-Site 'site.json'); Credential = $good; SkipVpx = $true; PinnedPublicKey = $otherPin }
    Assert ($r.Error -match 'pinned') "stopped on the pin ($($r.Error))"
    Assert ($state.requests.Count -eq 0) 'no request got through (not even the login)'

    Write-Host "`n== 6. wrong -Credential" -ForegroundColor Cyan
    Reset-Fake
    $r = Invoke-Site @{ SiteFile = (New-Site 'site.json'); Credential = $bad; SkipVpx = $true; PinnedPublicKey = $pin }
    Assert ($r.Error -match 'Login failed') "login check failed ($($r.Error))"
    Assert ((Get-Writes).Count -eq 0 -and $global:SitePrompts.Count -eq 0) 'nothing written, no re-prompt with -Credential'

    Write-Host "`n== 7. certificates mode acme" -ForegroundColor Cyan
    Reset-Fake
    $state.objects['sslcertkey|acme_cert'] = @{ certkey = 'acme_cert' }
    $acme = New-Site 'site-acme.json' @{ certificates = @{ mode = 'acme'; certKeys = @('acme_cert'); acmeConfigs = @('le-gateway'); waitMinutes = 1 } }
    $r = Invoke-Site @{ SiteFile = $acme; Credential = $good; SkipVpx = $true; From = 'Certificates'; PinnedPublicKey = $pin }
    Assert (-not $r.Error) "no error ($($r.Error))"
    Assert ($r.Out -match [regex]::Escape("NS_PINNEDPUBKEY=$pin") -and $r.Out -match 'acme-ns run le-gateway') 'acme-ns command printed with the pin override'
    Assert ($r.Out -match 'certKey\(s\) present: acme_cert' -and (Get-Index 'lb_site') -ge 0) 'certKey found, objects deployed'
}
finally {
    $tcp.Stop()
    $server | Stop-Job -PassThru | Remove-Job -Force
    Remove-Item Function:\Get-Credential, Function:\Read-Host -ErrorAction SilentlyContinue
    Remove-Variable SitePrompts -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Env:TEST_SITE_SECRET -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    $cert.Dispose(); $tmpCert.Dispose(); $rsa.Dispose()
}

Write-Host ''
if ($failures) { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
