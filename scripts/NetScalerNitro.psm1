# NetScalerNitro.psm1
# Shared NITRO helpers used by Deploy-NsCertificates.ps1, Deploy-NsObjects.ps1 and Undo-NsObjects.ps1.
# Keep this file in the same folder as the scripts.

# Errors inside module functions must stop the run (the caller's preference doesn't reach in here)
$ErrorActionPreference = 'Stop'

$script:Base     = $null
$script:Headers  = @{}
$script:SkipCert = $false
$script:NoProxy  = $false

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
    if ($null -ne $Body) { $p.Body = $Body | ConvertTo-Json -Depth 20 -Compress }
    # -ErrorAction Stop: connection/TLS errors must stop the run (the caller's
    # $ErrorActionPreference does not reach into module scope)
    $resp = Invoke-RestMethod @p -ErrorAction Stop
    $code = 0
    if ($resp -isnot [string] -and $null -ne $resp.errorcode) { $code = [int]$resp.errorcode }
    if ($httpStatus -ge 400 -and $code -eq 0) { $code = -1 }
    [pscustomobject]@{ Http = $httpStatus; ErrorCode = $code; Message = $resp.message; Data = $resp }
}

function Connect-Nitro {
    param(
        [Parameter(Mandatory)][string]$NsIp,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$SkipCertificateCheck,
        [switch]$NoProxy          # connect directly, bypass the system/corporate proxy
    )
    $script:Base     = "$($NsIp.TrimEnd('/'))/nitro/v1/config"
    $script:SkipCert = $SkipCertificateCheck.IsPresent
    $script:NoProxy  = $NoProxy.IsPresent
    $script:Headers  = @{}
    Write-Host "Connecting to $NsIp as $($Credential.UserName)..."
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

function Get-NitroUndoEntry {
    <# Describes how to undo one successful step: delete an object, delete a binding, or 'manual' (not reversible). #>
    param([string]$Resource, [string]$Method, [string]$Action, $Data)
    $d = ConvertTo-NitroHashtable $Data
    $isBinding = $Resource -like '*_binding'

    if ($Action -or ($Method -eq 'PUT' -and -not $isBinding)) {
        $what = if ($Action) { "?action=$Action" } else { '(update/set)' }
        return [ordered]@{ type = 'manual'; resource = $Resource; note = "not reversed automatically: $Resource $what" }
    }

    $primary = 'name','servicegroupname','monitorname','certkey','vservername','servicename','labelname','policyname' |
               Where-Object { $d.Contains($_) } | Select-Object -First 1
    if (-not $primary) {
        return [ordered]@{ type = 'manual'; resource = $Resource; note = "not reversed automatically: $Resource (no key found)" }
    }

    $delArgs = [ordered]@{}
    if ($isBinding) {
        foreach ($k in 'policy','policyname','servicename','servername','servicegroupname','port','ip',
                       'certkeyname','staserver','monitor_name','bindpoint','ca','snicert') {
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
    $removedObjects = @{}
    foreach ($e in $Entries) { if ($e.type -eq 'object') { $removedObjects["$($e.resource)|$($e.key)"] = $true } }
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
                              Get-NitroUndoEntry, Invoke-NitroUndo
