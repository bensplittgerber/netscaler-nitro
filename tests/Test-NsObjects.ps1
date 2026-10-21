#Requires -Version 7.0
<#
.SYNOPSIS
    Offline test of Deploy-NsObjects.ps1 / Undo-NsObjects.ps1 against a fake NITRO API (no NetScaler needed).

.DESCRIPTION
    Starts a small NITRO imitation on http://127.0.0.1:<random port> that behaves like NetScaler 14.1 in finding F11:
    re-adding an existing authenticationpolicylabel or re-binding an existing policy answers SUCCESS instead of
    "already exists". Then it checks:
      1. -WhatIf sends no change and reports existing objects as [EXISTS]
      2. a deploy over partly existing config journals ONLY the objects it really created
      3. a re-run creates nothing and writes no journal
      4. an undo of the first journal removes exactly the created objects, pre-existing ones stay
    The scripts are copied to a temp folder, so no journal lands in scripts/journals.

.EXAMPLE
    ./tests/Test-NsObjects.ps1
#>
$ErrorActionPreference = 'Stop'

# --- fake NITRO -----------------------------------------------------------------------------------------------
$state = [hashtable]::Synchronized(@{
    # objects: "<resource>|<key>" -> data;  bindings: list of @{ resource; key; data }
    objects  = [hashtable]::Synchronized(@{
        'lbvserver|lb_test'                          = @{ name = 'lb_test' }
        'authenticationpolicylabel|lbl_test'         = @{ labelname = 'lbl_test' }
        'authenticationpolicy|auth_pol_existing'     = @{ name = 'auth_pol_existing' }
        'vpnvserver|gw_test'                         = @{ name = 'gw_test' }
        'vpnsessionpolicy|sess_pol_test'             = @{ name = 'sess_pol_test' }
    })
    bindings = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]@(
        @{ resource = 'authenticationpolicylabel_authenticationpolicy_binding'; key = 'lbl_test'
           data = @{ labelname = 'lbl_test'; policyname = 'auth_pol_existing'; priority = 100 } }
        @{ resource = 'vpnvserver_vpnsessionpolicy_binding'; key = 'gw_test'
           data = @{ name = 'gw_test'; policy = 'sess_pol_test'; priority = 100 } }
    ))
    requests = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
})
$keyOf = @{ authenticationpolicylabel = 'labelname'; sslcipher = 'ciphergroupname' }

$tcp = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tcp.Start()
$port = $tcp.LocalEndpoint.Port; $tcp.Stop()
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

$server = Start-ThreadJob -ArgumentList $listener, $state, $keyOf -ScriptBlock {
    param($listener, $state, $keyOf)
    # Resources that answer a re-add with success (F11 behaviour seen on 14.1)
    $silent = 'authenticationpolicylabel', 'authenticationpolicylabel_authenticationpolicy_binding', 'vpnvserver_vpnsessionpolicy_binding'
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        $req  = $ctx.Request
        $path = $req.Url.AbsolutePath -replace '^/nitro/v1/config/', ''
        $res, $key = $path -split '/', 2
        if ($key) { $key = [uri]::UnescapeDataString($key) }
        $body = if ($req.HasEntityBody) { [IO.StreamReader]::new($req.InputStream).ReadToEnd() | ConvertFrom-Json -AsHashtable } else { $null }
        [void]$state.requests.Add("$($req.HttpMethod) $path")
        $code = 200; $out = @{ errorcode = 0; message = 'Done' }

        $data = if ($body) { $body[$res] } else { $null }
        if ($res -eq 'login') { $out.sessionid = 'test-session' }
        elseif ($res -in 'logout', 'nsconfig') { }
        elseif ($res -like '*_binding') {
            $parentKey = if ($key) { $key } else { $data[$keyOf[($res -split '_')[0]] ?? 'name'] ?? $data.labelname ?? $data.name }
            $mine = @($state.bindings | Where-Object { $_.resource -eq $res -and $_.key -eq $parentKey })
            switch ($req.HttpMethod) {
                'GET' {
                    $parentType = ($res -split '_')[0]
                    if (-not $state.objects.ContainsKey("$parentType|$parentKey")) { $code = 404; $out = @{ errorcode = 258; message = "No such resource [$parentKey]" } }
                    elseif ($mine.Count) { $out[$res] = @($mine | ForEach-Object { $_.data }) }
                }
                'PUT' {
                    $dup = $mine | Where-Object { ($_.data.policyname ?? $_.data.policy ?? $_.data.ciphername) -eq ($data.policyname ?? $data.policy ?? $data.ciphername) }
                    if ($dup -and $res -notin $silent) { $code = 409; $out = @{ errorcode = 273; message = 'Resource already exists' } }
                    elseif (-not $dup) { [void]$state.bindings.Add(@{ resource = $res; key = $parentKey; data = $data }) }
                }
                'DELETE' {
                    $argText = [uri]::UnescapeDataString(($req.Url.Query -replace '^\?args=', ''))
                    $val = ($argText -split ',' | ForEach-Object { ($_ -split ':', 2)[1] }) | Select-Object -First 1
                    $hit = $mine | Where-Object { ($_.data.policyname ?? $_.data.policy ?? $_.data.ciphername) -eq $val } | Select-Object -First 1
                    if ($hit) { $state.bindings.Remove($hit) } else { $code = 404; $out = @{ errorcode = 258; message = 'No such resource' } }
                }
            }
        }
        else {
            $k = if ($key) { $key } else { $data[$keyOf[$res] ?? 'name'] }
            $id = "$res|$k"
            switch ($req.HttpMethod) {
                'GET'    { if ($state.objects.ContainsKey($id)) { $out[$res] = @($state.objects[$id]) } else { $code = 404; $out = @{ errorcode = 258; message = "No such resource [$k]" } } }
                'POST'   {
                    if ($state.objects.ContainsKey($id) -and $res -notin $silent) { $code = 409; $out = @{ errorcode = 273; message = 'Resource already exists' } }
                    else { $state.objects[$id] = $data; $code = 201 }
                }
                'DELETE' {
                    $inUse = $res -eq 'sslcipher' -and ($state.bindings | Where-Object { $_.resource -eq 'sslprofile_sslcipher_binding' -and $_.data.ciphername -eq $k })
                    if ($inUse) { $code = 599; $out = @{ errorcode = 3672; message = 'Cipher group has bound entities or is referenced by an SSL vserver or SSL service' } }
                    elseif ($state.objects.ContainsKey($id)) {
                        $state.objects.Remove($id)
                        foreach ($b in @($state.bindings | Where-Object { $_.key -eq $k -and ($_.resource -split '_')[0] -eq $res })) { $state.bindings.Remove($b) }
                    } else { $code = 404; $out = @{ errorcode = 258; message = 'No such resource' } }
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

# --- test setup -----------------------------------------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) "nitro-test-$port"
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..' 'scripts' '*.ps*1') $work
$config = Join-Path $work 'rerun-test.json'
@{
    nsip  = "http://127.0.0.1:$port"
    steps = @(
        @{ resource = 'lbvserver';                 data = @{ name = 'lb_test'; servicetype = 'SSL' } }
        @{ resource = 'authenticationpolicylabel'; data = @{ labelname = 'lbl_test'; loginschema = 'LSCHEMA_INT' } }
        @{ resource = 'authenticationpolicy';      data = @{ name = 'auth_pol_new'; rule = 'true'; action = 'act_new' } }
        @{ resource = 'authenticationpolicylabel_authenticationpolicy_binding'; data = @{ labelname = 'lbl_test'; policyname = 'auth_pol_existing'; priority = 100 } }
        @{ resource = 'authenticationpolicylabel_authenticationpolicy_binding'; data = @{ labelname = 'lbl_test'; policyname = 'auth_pol_new'; priority = 110 } }
        @{ resource = 'vpnvserver_vpnsessionpolicy_binding'; data = @{ name = 'gw_test'; policy = 'sess_pol_test'; priority = 100 } }
        @{ resource = 'sslprofile';                data = @{ name = 'ssl_prof_test' } }
        @{ resource = 'sslcipher';                 data = @{ ciphergroupname = 'cg_test' } }
        @{ resource = 'sslcipher_sslciphersuite_binding'; data = @{ ciphergroupname = 'cg_test'; ciphername = 'TLS1.3-AES256-GCM-SHA384'; cipherpriority = 1 } }
        @{ resource = 'sslprofile_sslcipher_binding'; data = @{ name = 'ssl_prof_test'; ciphername = 'cg_test'; cipherpriority = 1 } }
    )
} | ConvertTo-Json -Depth 10 | Set-Content $config -Encoding utf8

# dummy credential for the fake API only
$cred = [pscredential]::new('nitro-test', (ConvertTo-SecureString 'fake-nitro-test' -AsPlainText -Force))
$failures = 0
function Assert($Condition, $Text) {
    if ($Condition) { Write-Host "  PASS  $Text" -ForegroundColor Green }
    else            { Write-Host "  FAIL  $Text" -ForegroundColor Red; $script:failures++ }
}
function Get-Journals { @(Get-ChildItem (Join-Path $work 'journals') -Filter 'rerun-test-*.json' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.undone.json') }
function Invoke-Quiet([scriptblock]$Block) { & $Block 6>&1 | Out-String }   # keeps Write-Host output for the asserts

try {
    Write-Host "`n== 1. -WhatIf" -ForegroundColor Cyan
    $state.requests.Clear()
    $out = Invoke-Quiet { & (Join-Path $work 'Deploy-NsObjects.ps1') -ConfigFile $config -Credential $cred -WhatIf }
    $changes = @($state.requests | Where-Object { $_ -notmatch '^(GET|POST login|POST logout)' })
    Assert ($changes.Count -eq 0) "no change requests sent ($($changes -join '; '))"
    Assert (([regex]::Matches($out, '\[EXISTS\]')).Count -eq 4) '4 existing objects/bindings reported as [EXISTS]'
    Assert ((Get-Journals).Count -eq 0) 'no journal written'

    Write-Host "`n== 2. deploy over partly existing config" -ForegroundColor Cyan
    $out = Invoke-Quiet { & (Join-Path $work 'Deploy-NsObjects.ps1') -ConfigFile $config -Credential $cred }
    $j = Get-Journals
    Assert ($j.Count -eq 1) 'one journal written'
    $entries = @((Get-Content -Raw $j[0].FullName | ConvertFrom-Json).entries)
    $names = @($entries | ForEach-Object { "$($_.resource)|$($_.key)|$($_.args.policyname)$($_.args.ciphername)" })
    Assert ($entries.Count -eq 6) "6 journal entries (got $($entries.Count): $($names -join '; '))"
    Assert (-not ($names -match '^authenticationpolicylabel\|lbl_test')) 'pre-existing label NOT journaled (F11)'
    Assert (-not ($names -match 'auth_pol_existing')) 'pre-existing label binding NOT journaled (F11)'
    Assert (-not ($names -match '^vpnvserver_vpnsessionpolicy_binding')) 'pre-existing (silent) vserver binding NOT journaled (F11)'
    Assert ($names -contains 'sslcipher_sslciphersuite_binding|cg_test|TLS1.3-AES256-GCM-SHA384') 'cipher binding journaled with group key + ciphername'

    Write-Host "`n== 3. re-run" -ForegroundColor Cyan
    $out = Invoke-Quiet { & (Join-Path $work 'Deploy-NsObjects.ps1') -ConfigFile $config -Credential $cred }
    Assert ((Get-Journals).Count -eq 1) 're-run wrote no second journal'
    Assert ($out -match 'No journal written') 're-run says "No journal written"'
    Assert (([regex]::Matches($out, '\[EXISTS\]')).Count -eq 10) 'all 10 steps [EXISTS]'

    Write-Host "`n== 4. undo of the first journal" -ForegroundColor Cyan
    $out = Invoke-Quiet { & (Join-Path $work 'Undo-NsObjects.ps1') -Journal $j[0].FullName -Credential $cred -Confirm:$false }
    Assert ($out -notmatch '\[FAILED\]') "undo without [FAILED] lines"
    Assert ($out -match 'remove sslprofile_sslcipher_binding') 'profile cipher binding removed explicitly (cipher group is removed before the profile)'
    Assert (-not $state.objects.ContainsKey('authenticationpolicy|auth_pol_new')) 'created policy removed'
    Assert (-not $state.objects.ContainsKey('sslcipher|cg_test')) 'created cipher group removed'
    Assert (-not $state.objects.ContainsKey('sslprofile|ssl_prof_test')) 'created SSL profile removed'
    Assert ($state.objects.ContainsKey('authenticationpolicylabel|lbl_test')) 'pre-existing label kept'
    $left = @($state.bindings | ForEach-Object { "$($_.resource)|$($_.data.policyname)$($_.data.policy)" })
    Assert ($left -contains 'authenticationpolicylabel_authenticationpolicy_binding|auth_pol_existing') 'pre-existing label binding kept'
    Assert ($left -contains 'vpnvserver_vpnsessionpolicy_binding|sess_pol_test') 'pre-existing vserver binding kept'
    Assert (-not ($left -match 'auth_pol_new')) 'created label binding removed'
}
finally {
    $listener.Stop()
    $server | Stop-Job -PassThru | Remove-Job -Force
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures) { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
