# NetScalerNitro.psm1
# Shared NITRO helpers used by Deploy-NsCertificates.ps1, Deploy-NsObjects.ps1 and Undo-NsObjects.ps1.
# Keep this file in the same folder as the scripts.

# Errors inside module functions must stop the run (the caller's preference doesn't reach in here)
$ErrorActionPreference = 'Stop'

$script:Base     = $null
$script:Headers  = @{}
$script:SkipCert = $false
$script:NoProxy  = $false
$script:Pin      = $null    # 'sha256//<base64 SPKI hash>' when -PinnedPublicKey is used
$script:Client   = $null    # HttpClient used for pinned connections

# Pinning: the TLS callback runs on .NET worker threads, where PowerShell script blocks cannot run.
# A tiny C# validator is compiled once per session. Needs PowerShell 7.2+ (.NET 6: ExportSubjectPublicKeyInfo).
if (-not ('NetScalerNitro.PinValidator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
namespace NetScalerNitro {
    public static class PinValidator {
        public static string Spki(X509Certificate2 cert) {
            using (var sha = SHA256.Create())
                return "sha256//" + Convert.ToBase64String(sha.ComputeHash(cert.PublicKey.ExportSubjectPublicKeyInfo()));
        }
        public static HttpClient NewClient(string pin, bool noProxy) {
            var h = new HttpClientHandler();
            h.UseProxy = !noProxy;
            h.UseCookies = false;
            h.ServerCertificateCustomValidationCallback = (msg, cert, chain, errors) =>
                cert != null && string.Equals(Spki(cert), pin, StringComparison.Ordinal);
            return new HttpClient(h) { Timeout = TimeSpan.FromSeconds(120) };
        }
    }
}
'@
}

function Get-NitroPin {
    <# Returns 'sha256//<base64>' of the management certificate's public key (same format as acme-ns pin and
       curl --pinnedpubkey). Reads the certificate WITHOUT trusting it: compare the value out of band (console,
       'acme-ns pin' from another host) before you use it. #>
    param([Parameter(Mandatory)][string]$NsIp)
    $u = [uri]$NsIp
    $port = if ($u.Port -gt 0) { $u.Port } else { 443 }
    $tcp = [System.Net.Sockets.TcpClient]::new($u.Host, $port)
    try {
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($u.Host)
        [NetScalerNitro.PinValidator]::Spki([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate))
    } finally { $tcp.Dispose() }
}

function Import-NitroConfig {
    <# Loads a JSON config and replaces ${env:NAME} placeholders with environment variable values. #>
    param([Parameter(Mandatory)][string]$Path)
    $full = (Resolve-Path $Path).Path
    $raw  = Get-Content -Raw $full
    $raw  = [regex]::Replace($raw, '\$\{env:([A-Za-z0-9_]+)\}', {
        param($m)
        $name = $m.Groups[1].Value
        $val  = [Environment]::GetEnvironmentVariable($name)
        if ($null -eq $val) { throw "Environment variable '$name' is referenced in the config but not set." }
        $json = ConvertTo-Json $val -Compress
        $json.Substring(1, $json.Length - 2)
    })
    try   { $cfg = $raw | ConvertFrom-Json }
    catch { throw "Config file '$full' is not valid JSON: $($_.Exception.Message)" }
    if (-not $cfg.nsip) { throw "Config file '$full' has no ""nsip"" value." }
    [pscustomobject]@{
        Config = $cfg
        Dir    = Split-Path -Parent $full
    }
}

function Invoke-Nitro {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Resource,
        [hashtable]$Query,
        $Body
    )
    if (-not $script:Base) { throw 'Not connected. Call Connect-Nitro first.' }
    $uri = "$script:Base/$Resource"
    if ($Query) {
        $uri += '?' + (($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&')
    }
    $p = @{
        Method               = $Method
        Uri                  = $uri
        Headers              = $script:Headers
        ContentType          = 'application/json'
        SkipHttpErrorCheck   = $true
        StatusCodeVariable   = 'httpStatus'
        SkipCertificateCheck = $script:SkipCert
        NoProxy              = $script:NoProxy
    }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { $null }
    if ($script:Client) {
        # pinned: the HttpClient handler checks every TLS handshake against the pin
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $uri)
        foreach ($h in $script:Headers.GetEnumerator()) { [void]$req.Headers.TryAddWithoutValidation($h.Key, [string]$h.Value) }
        if ($null -ne $json) {
            $req.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8)
            # NITRO rejects 'application/json; charset=utf-8' ("Possible encoding values in Content-Type can be xml or json only")
            $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
        }
        try   { $res = $script:Client.SendAsync($req).GetAwaiter().GetResult() }
        catch { throw "NITRO request to $uri failed (pinned $($script:Pin)): $($_.Exception.GetBaseException().Message)" }
        $httpStatus = [int]$res.StatusCode
        $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $resp = if ($text) { try { $text | ConvertFrom-Json } catch { $text } } else { $null }
    } else {
        if ($null -ne $json) { $p.Body = $json }
        # -ErrorAction Stop: connection/TLS errors must stop the run (the caller's
        # $ErrorActionPreference does not reach into module scope)
        $resp = Invoke-RestMethod @p -ErrorAction Stop
    }
    $code = 0
    if ($null -ne $resp -and $resp -isnot [string] -and $null -ne $resp.errorcode) { $code = [int]$resp.errorcode }
    if ($httpStatus -ge 400 -and $code -eq 0) { $code = -1 }
    [pscustomobject]@{ Http = $httpStatus; ErrorCode = $code; Message = $(if ($resp -isnot [string]) { $resp.message }); Data = $resp }
}

function Connect-Nitro {
    param(
        [Parameter(Mandatory)][string]$NsIp,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$SkipCertificateCheck,
        [switch]$NoProxy,         # connect directly, bypass the system/corporate proxy
        [string]$PinnedPublicKey  # 'sha256//<base64>': accept only this management certificate key (no CA trust needed)
    )
    if ($PinnedPublicKey -and $SkipCertificateCheck) { throw 'Use either -PinnedPublicKey or -SkipCertificateCheck, not both.' }
    if ($PinnedPublicKey -and $PinnedPublicKey -notmatch '^sha256//[A-Za-z0-9+/]{43}=$') {
        throw "-PinnedPublicKey must look like 'sha256//<44 base64 characters>' (output of 'acme-ns pin' or Get-NitroPin)."
    }
    $script:Base     = "$($NsIp.TrimEnd('/'))/nitro/v1/config"
    $script:SkipCert = $SkipCertificateCheck.IsPresent
    $script:NoProxy  = $NoProxy.IsPresent
    $script:Headers  = @{}
    $script:Pin      = $null
    if ($script:Client) { $script:Client.Dispose(); $script:Client = $null }
    if ($PinnedPublicKey) {
        $script:Pin    = $PinnedPublicKey
        $script:Client = [NetScalerNitro.PinValidator]::NewClient($PinnedPublicKey, $script:NoProxy)
    }
    $how = if ($script:Pin) { " (pinned $($script:Pin))" } elseif ($script:SkipCert) { ' (certificate NOT checked)' } else { '' }
    Write-Host "Connecting to $NsIp as $($Credential.UserName)$how..."
    $r = Invoke-Nitro -Method POST -Resource 'login' -Body @{ login = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    } }
    if ($r.ErrorCode -ne 0 -or -not $r.Data.sessionid) {
        $script:Base = $null
        throw "Login failed: $($r.Message)"
    }
    $script:Headers.Cookie = "NITRO_AUTH_TOKEN=$($r.Data.sessionid)"
}

function Disconnect-Nitro {
    if ($script:Base -and $script:Headers.Cookie) {
        [void](Invoke-Nitro -Method POST -Resource 'logout' -Body @{ logout = @{} })
        Write-Host 'Logged out.'
    }
    $script:Base = $null
    $script:Headers = @{}
    if ($script:Client) { $script:Client.Dispose(); $script:Client = $null }
}

function Write-NitroResult {
    <# Prints the result and returns 'ok', 'exists' or 'failed'. Throws on failure unless -ContinueOnError. #>
    param([string]$Label, $Result, [switch]$ContinueOnError)
    if ($Result.ErrorCode -eq 0) {
        Write-Host "  [OK]      $Label" -ForegroundColor Green
        return 'ok'
    }
    if ($Result.Message -match 'already') {
        Write-Host "  [EXISTS]  $Label  ($($Result.Message))" -ForegroundColor Yellow
        return 'exists'
    }
    Write-Host "  [FAILED]  $Label  -> $($Result.ErrorCode): $($Result.Message)" -ForegroundColor Red
    if (-not $ContinueOnError) { throw "Stopping at failed step: $Label" }
    return 'failed'
}

function New-NitroBackup {
    $name = 'pre-nitro-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $r = Invoke-Nitro -Method POST -Resource 'systembackup' -Query @{ action = 'create' } `
                      -Body @{ systembackup = @{ filename = $name; level = 'basic' } }
    Write-NitroResult "backup $name" $r
}

function Save-NitroConfig {
    $r = Invoke-Nitro -Method POST -Resource 'nsconfig' -Query @{ action = 'save' } -Body @{ nsconfig = @{} }
    Write-NitroResult 'save ns config' $r
}

function Sync-NitroHaFiles {
    param([string[]]$Mode = @('ssl'))
    $r = Invoke-Nitro -Method POST -Resource 'hafiles' -Query @{ action = 'sync' } -Body @{ hafiles = @{ mode = $Mode } }
    Write-NitroResult "sync ha files $($Mode -join ',')" $r
}

# ---------------------------------------------------------------------------
# Rollback support
# ---------------------------------------------------------------------------
function ConvertTo-NitroHashtable($Data) {
    if ($Data -is [System.Collections.IDictionary]) { return $Data }
    $h = [ordered]@{}
    foreach ($p in $Data.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h
}

# Key field per resource type. For "<parent>_..._binding" the parent decides (e.g. systemuser_systemcmdpolicy_binding
# is keyed by username, aaagroup_aaauser_binding by groupname). Used for the step label AND for undo (F1).
$script:NitroKeyByType = @{
    systemuser = 'username'; systemgroup = 'groupname'; aaauser = 'username'; aaagroup = 'groupname'
    vlan = 'id'; nsip = 'ipaddress'; nsip6 = 'ipv6address'; lbmonitor = 'monitorname'; sslcertkey = 'certkey'
    sslvserver = 'vservername'; sslservice = 'servicename'; servicegroup = 'servicegroupname'
    systemcmdpolicy = 'policyname'; sslprofile = 'name'; route = 'network'; sslcipher = 'ciphergroupname'
}
# Fallback order for everything else
$script:NitroKeys = 'name','servicegroupname','monitorname','certkey','vservername','servicename',
                    'labelname','policylabelname','policyname','username','groupname','id','ipaddress'
# Extra arguments a binding DELETE needs (all fields of the step except the key)
$script:NitroBindingArgs = 'policy','policyname','servicename','servername','servicegroupname','port','ip','ipaddress','netmask',
                           'ifnum','certkeyname','staserver','monitor_name','bindpoint','ca','snicert','username','groupname',
                           'ciphername','portaltheme','urlname','lbvserver'

function Test-NitroExists {
    <# F11: looks up the object or binding of an add/bind step BEFORE it is sent. NITRO answers some adds of an
       existing object (e.g. authenticationpolicylabel, vpnvserver policy bindings) with success instead of 409, so
       the response alone cannot tell "created" from "was already there".
       Returns $true (exists), $false (does not exist) or $null (cannot tell - the caller sends the step as before). #>
    param([Parameter(Mandatory)][string]$Resource, $Data)
    $d   = ConvertTo-NitroHashtable $Data
    $key = Get-NitroKey -Resource $Resource -Data $d
    if (-not $key -or $Resource -eq 'route') { return $null }

    $r = Invoke-Nitro -Method GET -Resource "$Resource/$([uri]::EscapeDataString([string]$d[$key]))"
    if ($r.ErrorCode -ne 0) {
        # 258 "No such resource" = the object (or the parent of a binding) does not exist
        if ($r.ErrorCode -eq 258 -or $r.Http -eq 404 -or $r.Message -match 'No such resource|does not exist') { return $false }
        return $null
    }
    $found = @($r.Data.$Resource | Where-Object { $_ })
    if ($Resource -notlike '*_binding') { return $found.Count -gt 0 }

    # binding: an entry must match every identifying argument of the step (bindpoint is not always returned)
    $ids = @($script:NitroBindingArgs | Where-Object { $_ -ne $key -and $_ -ne 'bindpoint' -and $d.Contains($_) })
    if (-not $ids.Count) { return $null }
    foreach ($e in $found) {
        $match = $true
        foreach ($k in $ids) {
            $v = $e.$k
            if ($null -eq $v -and $d[$k] -is [bool]) { $v = $false }   # ca / snicert are omitted when false
            if ("$v".TrimEnd('/') -ne "$($d[$k])".TrimEnd('/')) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    $false
}

function Get-NitroKey {
    <# Returns the name of the key field of a step's data, or $null. #>
    param([string]$Resource, $Data)
    $d = ConvertTo-NitroHashtable $Data
    $type = ($Resource -split '_')[0]
    $k = $script:NitroKeyByType[$type]
    if ($k -and $d.Contains($k) -and "$($d[$k])" -ne '') { return $k }
    $script:NitroKeys | Where-Object { $d.Contains($_) -and "$($d[$_])" -ne '' } | Select-Object -First 1
}

function Get-NitroUndoEntry {
    <# Describes how to undo one successful step: delete an object, delete a binding, or 'manual' (not reversible). #>
    param([string]$Resource, [string]$Method, [string]$Action, $Data)
    $d = ConvertTo-NitroHashtable $Data
    $isBinding = $Resource -like '*_binding'

    if ($Action -or ($Method -eq 'PUT' -and -not $isBinding)) {
        $what = if ($Action) { "?action=$Action" } else { '(update/set)' }
        return [ordered]@{ type = 'manual'; resource = $Resource; note = "not reversed automatically: $Resource $what" }
    }

    $primary = Get-NitroKey -Resource $Resource -Data $d
    if (-not $primary -or $Resource -eq 'route') {
        $what = if ($primary) { " [$($d[$primary])]" } else { ' (no key found)' }
        return [ordered]@{ type = 'manual'; resource = $Resource; note = "not reversed automatically: $Resource$what" }
    }

    $delArgs = [ordered]@{}
    if ($isBinding) {
        foreach ($k in $script:NitroBindingArgs) {
            if ($k -ne $primary -and $d.Contains($k)) { $delArgs[$k] = $d[$k] }
        }
    } elseif ($Resource -eq 'lbmonitor' -and $d.Contains('type')) {
        $delArgs.type = $d.type
    }
    [ordered]@{
        type     = if ($isBinding) { 'binding' } else { 'object' }
        resource = $Resource
        key      = $d[$primary]
        args     = $delArgs
    }
}

function Invoke-NitroUndo {
    <# Reverses journal entries in reverse order. Returns the number of entries that could not be removed. #>
    param([Parameter(Mandatory)][object[]]$Entries)
    $failed = 0

    # Objects removed in this undo. Their bindings disappear together with them, so those bindings
    # are not removed one by one (avoids failures on binding types with unusual delete arguments).
    # Exception: the binding references another removed object that was created AFTER the parent - that one is
    # removed first and NetScaler refuses while it is still bound (e.g. sslprofile -> sslcipher group).
    $removedObjects = @{}   # "<resource>|<key>" -> journal index
    $removedKeys    = @{}   # key -> highest journal index of a removed object with that key
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $e = $Entries[$i]
        if ($e.type -ne 'object') { continue }
        $removedObjects["$($e.resource)|$($e.key)"] = $i
        $removedKeys["$($e.key)"] = $i
    }
    $vserverTypes = 'lbvserver','vpnvserver','authenticationvserver','csvserver','gslbvserver'

    for ($i = $Entries.Count - 1; $i -ge 0; $i--) {
        $e = $Entries[$i]
        if ($e.type -eq 'manual') {
            Write-Host "  [MANUAL]  $($e.note)" -ForegroundColor Yellow
            continue
        }
        if ($e.type -eq 'binding') {
            $parent  = ($e.resource -split '_')[0]
            $parents = switch ($parent) {
                'sslvserver' { $vserverTypes }
                'sslservice' { 'service' }
                default      { $parent }
            }
            $owner = $parents | Where-Object { $removedObjects.ContainsKey("$_|$($e.key)") } | Select-Object -First 1
            if ($owner -and $e.args) {
                $ownerIdx = $removedObjects["$owner|$($e.key)"]
                $refs = @((ConvertTo-NitroHashtable $e.args).Values | Where-Object { $removedKeys.ContainsKey("$_") -and $removedKeys["$_"] -gt $ownerIdx })
                if ($refs.Count) { $owner = $null }
            }
            if ($owner) {
                Write-Host "  [SKIP]    $($e.resource) [$($e.key)]  (removed together with $owner)" -ForegroundColor DarkGray
                continue
            }
        }
        $pairs = @()
        if ($e.args) {
            foreach ($kv in (ConvertTo-NitroHashtable $e.args).GetEnumerator()) {
                $v = if ($kv.Value -is [bool]) { "$($kv.Value)".ToLower() } else { [string]$kv.Value }
                $pairs += "$($kv.Key):$([uri]::EscapeDataString($v))"
            }
        }
        $q     = if ($pairs.Count) { @{ args = ($pairs -join ',') } } else { $null }
        $label = "remove $($e.resource) [$($e.key)]"
        if ($pairs.Count) { $label += " $([uri]::UnescapeDataString($pairs -join ', '))" }
        $r = Invoke-Nitro -Method DELETE -Resource "$($e.resource)/$([uri]::EscapeDataString([string]$e.key))" -Query $q
        if ($r.ErrorCode -ne 0 -and $r.Message -match 'does not exist|No such|not found') {
            Write-Host "  [GONE]    $label  (already removed)" -ForegroundColor DarkGray
            continue
        }
        if ((Write-NitroResult $label $r -ContinueOnError) -eq 'failed') { $failed++ }
    }
    $failed
}

Export-ModuleMember -Function Import-NitroConfig, Invoke-Nitro, Connect-Nitro, Disconnect-Nitro,
                              Write-NitroResult, New-NitroBackup, Save-NitroConfig, Sync-NitroHaFiles,
                              Get-NitroKey, Get-NitroUndoEntry, Invoke-NitroUndo, Get-NitroPin, Test-NitroExists
