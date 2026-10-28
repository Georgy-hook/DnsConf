# Read-only planning. Never stores URLs, browser history or credentials.
function Convert-RepairHost([string]$Value) {
    $value=$Value.Trim()
    if($value -match '^https?://') {
        $uri=$null
        if(-not [Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri) -or $uri.UserInfo){throw 'Нужен адрес хранилища без имени пользователя.'}
        $value=$uri.DnsSafeHost
    }
    $value=$value.TrimEnd('.').ToLowerInvariant()
    if($value -cnotmatch '^sdmntpr[a-z0-9]{1,40}\.oaiusercontent\.com$'){throw 'Допускаются только региональные хранилища sdmntpr…oaiusercontent.com.'}
    return $value
}
function Get-RepairHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')} finally {$sha.Dispose()}
}
function Get-RepairMap([string]$Text) {
    $matches=[regex]::Matches($Text,'(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)')
    if($matches.Count -ne 1){throw 'Сначала подключите один профиль на странице «Серверы».'}
    $map=[ordered]@{}
    foreach($line in ($matches[0].Value -split '\r?\n')) {
        $clean=($line -split '#',2)[0].Trim()
        if(-not $clean){continue}
        $parts=@($clean -split '\s+')
        if($parts.Count -ne 2 -or $map.Contains($parts[1])){throw 'Неоднозначные записи hosts. Используйте проверку основного окна.'}
        $map[$parts[1].ToLowerInvariant()]=$parts[0]
    }
    return ,$map
}
function New-RepairPlan([string]$HostsText,[byte[]]$HostsBytes,[string[]]$CachedNames=@(),[string]$ManualText='') {
    $map=Get-RepairMap $HostsText
    $routes=@($map.Keys | Where-Object {$_ -cmatch '^sdmntpr[a-z0-9]{1,40}\.oaiusercontent\.com$'} | ForEach-Object {$map[$_]} | Select-Object -Unique)
    if($routes.Count -ne 1){throw 'Хранилища профиля используют разные адреса. Сначала выберите «США + EU для вложений».'}
    $route=[string]$routes[0]
    if($route -notin @('45.13.237.213','37.221.93.128')){throw 'Для восстановления сначала выберите профиль с европейским маршрутом вложений.'}
    $names=@($CachedNames | Where-Object {$_ -cmatch '^sdmntpr[a-z0-9]{1,40}\.oaiusercontent\.com$'})
    foreach($value in @($ManualText -split '\s+' | Where-Object {$_})) {$names+=Convert-RepairHost $value}
    $names=@($names | Sort-Object -Unique)
    if($names.Count -gt 64){throw 'Слишком много адресов: допускается не больше 64.'}
    $missing=@($names | Where-Object {-not $map.Contains($_)})
    [pscustomobject]@{HostsHash=(Get-RepairHash $HostsBytes);RouteAddress=$route;Domains=$missing;Map=$map;ExistingCount=$map.Count}
}
function Get-RepairPlan([string]$ManualText='') {
    $path=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $bytes=[IO.File]::ReadAllBytes($path)
    $cached=@()
    $cacheAvailable=$true
    try {$cached=@(Get-DnsClientCache -ErrorAction Stop | ForEach-Object {$_.Entry} | Where-Object {$_})} catch {$cacheAvailable=$false}
    $plan=New-RepairPlan ([Text.Encoding]::GetEncoding(28591).GetString($bytes)) $bytes $cached $ManualText
    $plan|Add-Member -NotePropertyName CacheAvailable -NotePropertyValue $cacheAvailable
    return $plan
}
function Get-ControlDiagnostics {
    $chrome=@(Get-Process -Name chrome -ErrorAction SilentlyContinue).Count -gt 0
    $pluginRoot=Join-Path $env:USERPROFILE '.codex\plugins\cache\openai-bundled'
    $cu=Test-Path -LiteralPath (Join-Path $pluginRoot 'computer-use')
    $native=@()
    foreach($key in @('HKCU:\Software\Google\Chrome\NativeMessagingHosts','HKLM:\Software\Google\Chrome\NativeMessagingHosts','HKLM:\Software\WOW6432Node\Google\Chrome\NativeMessagingHosts')) {
        if(Test-Path -LiteralPath $key) {
            foreach($item in @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue | Where-Object {$_.PSChildName -match 'openai|chatgpt|codex'})) {
                $manifest=[string]$item.GetValue('')
                $ok=$false
                try {$data=Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop|ConvertFrom-Json; $ok=Test-Path -LiteralPath ([string]$data.path)} catch {}
                $native+=('{0}: {1}' -f $item.PSChildName,$(if($ok){'файл подключения найден'}else{'файл подключения отсутствует'}))
            }
        }
    }
    $lines=@()
    $lines+='Chrome: '+$(if($chrome){'запущен'}else{'закрыт'})
    $lines+='Плагин управления компьютером: '+$(if($cu){'файлы найдены'}else{'не найден на этом компьютере'})
    $lines+=$(if($native.Count){$native -join "`n"}else{'Подключение расширения Chrome: регистрация не найдена.'})
    $lines+='Это проверка установки. Доступ агента и разрешение конкретного действия проверяются в ChatGPT.'
    $lines -join "`n"
}

function Get-DotRouteDiagnostics {
    $lines=@('Облачный компьютер Dot и файлы используют сетевые ресурсы OpenAI.')
    $domains=@{'oaiusercontent.com'='45.13.237.213';'chatgpt.com'='192.255.159.241';'openai.com'='192.255.159.241';'oaistatic.com'='192.255.159.241'}
    foreach($domain in @('oaiusercontent.com','chatgpt.com','openai.com','oaistatic.com')) {
        try {
            $probe='route-check.'+$domain
            $ips=@(Resolve-DnsName $probe -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object {$_.IPAddress} | Select-Object -ExpandProperty IPAddress -Unique)
            $status=if($ips.Count -eq 1 -and $ips[0] -eq $domains[$domain]){'соответствует проверенному маршруту'}else{'отличается от проверенного маршрута'}
            $lines+=('Все поддомены '+$domain+': '+($ips -join ', ')+' — '+$status)
        } catch {$lines+=('Все поддомены '+$domain+': общее правило не подтверждено.')}
    }
    $lines+='Это проверка общего DNS-правила без hosts. GIF и трансляция проверяются открытием в Dot.'
    $lines+='Если после обновления DnsConf адреса меняются, проверьте PINNED_REDIRECTS в GitHub → Environment DNS.'
    $lines -join "`n"
}
