#Requires -Version 5.1
function Get-BridgeStatus {
    $path=Join-Path $env:ProgramData 'NextDNSBridge\status.json'
    $service=$null
    try {$service=Get-Service -Name NextDNSBridge -ErrorAction Stop} catch {}
    if(-not $service){return [pscustomobject]@{Installed=$false;Active=$false;Running=$false;Text='NextDNS Bridge ещё не установлен'}}
    $active=$false
    try {$active=([IO.File]::ReadAllText((Join-Path $env:ProgramFiles 'NextDNS Bridge\enabled.txt')).Trim() -eq '1')} catch {}
    if(-not $active){return [pscustomobject]@{Installed=$true;Active=$false;Running=($service.Status -eq 'Running');Text='NextDNS Bridge отключён. Можно восстановить подключение.'}}
    if($service.Status -ne 'Running'){return [pscustomobject]@{Installed=$true;Active=$true;Running=$false;Text='NextDNS: служба остановлена. Нажмите «Перезапустить службу».'}}
    try {
        $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
        if($state.lastError){$text='NextDNS: служба запущена, но ответа пока нет. Повторите проверку.'}
        elseif($state.lastSuccessAt){$text='NextDNS · TLS 1.3 · ответ '+([datetime]$state.lastSuccessAt).ToLocalTime().ToString('HH:mm:ss')}
        else{$text='NextDNS: служба запущена, ожидаю первый ответ.'}
    } catch {$text='NextDNS: служба запущена. Отчёт появится после первого запроса.'}
    try {
        $boot=Get-Content -LiteralPath (Join-Path $env:ProgramData 'NextDNSBridge\boot-verified.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
        if($boot.status -eq 'ok' -and $boot.afterReboot -and [Math]::Abs((([datetime]$boot.bootAt)-([datetime]$state.bootAt)).TotalSeconds) -lt 60){$text+=' · проверено после загрузки Windows'}
    } catch {}
    [pscustomobject]@{Installed=$true;Active=$true;Running=$true;Text=$text}
}
