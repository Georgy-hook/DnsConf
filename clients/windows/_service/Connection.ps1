#Requires -Version 5.1
function New-ConnectionReport([object[]]$Checks) {
    $state=if(@($Checks|Where-Object State -eq 'mismatch').Count){'mismatch'}elseif($Checks.Count -ne 4 -or @($Checks|Where-Object State -ne 'ready').Count){'unavailable'}else{'ready'}
    $title=switch($state){ready{'DNS для файлов настроен'}mismatch{'DNS-маршрут отличается'}default{'DNS-проверка не завершена'}}
    $next=switch($state){
        ready{'Новые адреса хранилищ покрыты общими правилами. Если GIF зависла в Chrome, перезапустите Chrome: очистка DNS Windows не закрывает соединения браузера.'}
        mismatch{'Ответы DNS отличаются от маршрутов в каталоге проверки. Перезапуск браузера не меняет правила DNS. Проверьте NextDNS и закрепление маршрутов в DnsConf; адреса также могли измениться у провайдера.'}
        default{'За 12 секунд не получены все DNS-ответы. Проверьте подключение и повторите проверку. Это не означает, что hosts удалились или что конкретная GIF недоступна.'}
    }
    [pscustomobject]@{State=$state;Title=$title;Next=$next;At=(Get-Date).ToString('o');Checks=@($Checks);AttachmentsVerified=$false}
}
function Start-ConnectionCheck([string]$Root) {
    $runRoot=Join-Path $Root 'run-results'
    [IO.Directory]::CreateDirectory($runRoot)|Out-Null
    if(((Get-Item -LiteralPath $runRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Папка результатов не должна быть ссылкой.'}
    $path=Join-Path $runRoot ('health-route-'+[guid]::NewGuid().ToString('N')+'.result.json')
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $Root 'ConnectionWorker.ps1')+'"'),'-ResultPath',('"'+$path+'"'))
    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
    [pscustomobject]@{Process=$process;Path=$path;At=(Get-Date)}
}
function Receive-ConnectionCheck($Run) {
    if(-not $Run){return $null}
    if(-not $Run.Process.HasExited -and ((Get-Date)-$Run.At).TotalSeconds -lt 20){return $null}
    try {
        if(-not $Run.Process.HasExited){$Run.Process.Kill()}
        if(Test-Path -LiteralPath $Run.Path){return (Get-Content -LiteralPath $Run.Path -Raw -Encoding UTF8 | ConvertFrom-Json)}
        return (New-ConnectionReport @())
    } catch {
        return (New-ConnectionReport @())
    } finally {
        $Run.Process.Dispose()
        if(Test-Path -LiteralPath $Run.Path){Remove-Item -LiteralPath $Run.Path -Force -ErrorAction SilentlyContinue}
    }
}
function Stop-ConnectionCheck($Run) {
    if($Run) {
        try {if(-not $Run.Process.HasExited){$Run.Process.Kill()};$Run.Process.Dispose()} catch {}
        if(Test-Path -LiteralPath $Run.Path){Remove-Item -LiteralPath $Run.Path -Force -ErrorAction SilentlyContinue}
    }
}
function Get-ManagerLauncher([string]$Root) {
    $current=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if([IO.Path]::GetFileName($current) -ieq 'NextDNS.exe'){return $current}
    foreach($path in @((Join-Path (Split-Path $Root -Parent) 'NextDNS.exe'),(Join-Path $Root 'bin\NextDNS.exe'))) {
        if(Test-Path -LiteralPath $path){return $path}
    }
    throw 'Не найден NextDNS.exe рядом с интерфейсом.'
}
function Get-ManagerChrome {
    foreach($path in @((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),(Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))) {
        if(Test-Path -LiteralPath $path){return $path}
    }
    throw 'Chrome не найден. Откройте нужный браузер самостоятельно.'
}
