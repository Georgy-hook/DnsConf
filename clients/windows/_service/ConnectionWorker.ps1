#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$ResultPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Connection.ps1')
try {
    $config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'connection-routes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $nonce='manager-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $pending=@(foreach($route in $config.routes) {
        # A unique name tests inherited DNS routing without a cached or hosts-specific entry.
        [pscustomobject]@{Route=$route;Task=[Net.Dns]::GetHostAddressesAsync($nonce+'.'+$route.domain)}
    })
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(@($pending | Where-Object {-not $_.Task.IsCompleted}).Count -and $watch.Elapsed.TotalSeconds -lt 12) {Start-Sleep -Milliseconds 100}
    $checks=@(foreach($item in $pending) {
        $addresses=@();$state='unavailable'
        if($item.Task.Status -eq 'RanToCompletion') {
            $addresses=@($item.Task.Result | ForEach-Object {$_.IPAddressToString} | Sort-Object -Unique)
            if($addresses.Count) {$state=if(@($addresses|Where-Object {$_ -notin $item.Route.addresses}).Count -eq 0){'ready'}else{'mismatch'}}
        }
        [pscustomobject]@{Domain=$item.Route.domain;Label=$item.Route.label;State=$state;Addresses=$addresses;Expected=@($item.Route.addresses)}
    })
    $report=New-ConnectionReport $checks
} catch {$report=New-ConnectionReport @()}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
