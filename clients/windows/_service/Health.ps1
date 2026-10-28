#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','ClearLogs','Probe')][string]$Mode='Check',
    [string]$ResultPath,
    [ValidateSet('Historical','All','Current')][string]$Scope='Historical',
    [string[]]$PreservePaths=@(),
    [string]$CurrentLogPath,
    [ValidateSet('chat','file','filecentral','filewest','cloud')][string]$ProbeName,
    [ValidateRange(0,86400)][int]$MinimumAgeSeconds=120
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath($PSScriptRoot)
$taskRunRoot=Join-Path $taskRoot 'run-results'
$taskUtf8=New-Object Text.UTF8Encoding($false)
$taskRunRootUnsafe=$false
$taskReport=[ordered]@{status='ok';mode=$Mode;at=(Get-Date).ToString('o');health=@{status='unknown';summary='Проверка не завершена.'};attachmentsVerified=$false}
$taskTargets=@{chat=@('ChatGPT','chatgpt.com');file=@('Файлы South','sdmntprsouthcentralus.oaiusercontent.com');filecentral=@('Изображения Central','sdmntprcentralus.oaiusercontent.com');filewest=@('Вложения West','sdmntprwestcentralus.oaiusercontent.com');cloud=@('Облако','codex-cloud-backend.chatgpt.com')}

function Write-Result([string]$Path,$Value) {
    $absolute=[IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($absolute)) | Out-Null
    [IO.File]::WriteAllText($absolute,($Value | ConvertTo-Json -Depth 12),$taskUtf8)
}
function Assert-RunRoot([bool]$Create=$false) {
    $expected=[IO.Path]::GetFullPath((Join-Path $taskRoot 'run-results'))
    if ([IO.Path]::GetDirectoryName($expected) -ine $taskRoot) { $script:taskRunRootUnsafe=$true;throw 'Некорректная папка журналов.' }
    if (((Get-Item -LiteralPath $taskRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $script:taskRunRootUnsafe=$true;throw 'Служебная папка не должна быть ссылкой.' }
    if (-not (Test-Path -LiteralPath $expected)) { if ($Create) {[IO.Directory]::CreateDirectory($expected)|Out-Null} else {return} }
    if (((Get-Item -LiteralPath $expected -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $script:taskRunRootUnsafe=$true;throw 'Папка журналов не должна быть ссылкой.' }
}
function Test-OwnFileName([string]$FileName) {
    return $FileName -cmatch '^(?:gui(?:-health)?-\d{8}-\d{6}-[a-fA-F0-9]{8}(?:\.(?:request|result))?|health-\d{8}-\d{6}-[a-fA-F0-9]{8}(?:\.result)?|health-probe-[a-fA-F0-9]{32}-(?:chat|file|filecentral|filewest|cloud)\.result)\.(?:json|log)$'
}
function Get-OwnFiles {
    Assert-RunRoot
    if (-not (Test-Path -LiteralPath $taskRunRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $taskRunRoot -File -Force | Where-Object {Test-OwnFileName $_.Name})
}
function Get-LogStats {
    $files=@(Get-OwnFiles)
    $bytes=0L
    foreach ($file in $files) {$bytes+=$file.Length}
    return [ordered]@{fileCount=$files.Count;bytes=$bytes;protectedCount=0;directory=$taskRunRoot;scope='Только журналы и запросы менеджера; журналы ChatGPT, резервные копии и cookies не затрагиваются.'}
}
function Get-Map([string]$Text) {
    $records=@(foreach ($line in ($Text -split '\r?\n')) {
        $clean=($line -split '#',2)[0].Trim()
        if (-not $clean) {continue}
        $parts=@($clean -split '\s+')
        if ($parts.Count -ge 2) {foreach($domain in ($parts|Select-Object -Skip 1)){if($domain -match '(^|\.)(chatgpt\.com|openai\.com|oaistatic\.com|oaiusercontent\.com)$'){($parts[0].ToLowerInvariant()+' '+$domain.ToLowerInvariant())}}}
    })
    return ,@($records | Sort-Object -Unique)
}
function Get-CacheDetails {
    $details=[ordered]@{windowsDnsRelatedEntries=$null;profileDomainCount=0;activeProfileId=$null;activeProfileName=$null;lastClearedAt=$null;folders=@();cacheProfileRoot=$null;profileEvidence=$null;detail='Размеры кешей получены только из метаданных; очистка по кнопке относится к DNS.'}
    try {$details.windowsDnsRelatedEntries=@(Get-DnsClientCache -ErrorAction Stop|Where-Object {$_.Entry -match '(^|\.)(chatgpt\.com|openai\.com|oaistatic\.com|oaiusercontent\.com)$'}).Count} catch {$details.detail='Не удалось прочитать DNS-кеш Windows.'}
    try {
        $hosts=[IO.File]::ReadAllText((Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'))
        $block=[regex]::Match($hosts,'(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)')
        if($block.Success){
            $map=Get-Map $block.Value
            $details.profileDomainCount=$map.Count
            $catalog=[IO.File]::ReadAllText((Join-Path $taskRoot 'profiles.json'))|ConvertFrom-Json
            foreach($entry in $catalog.Profiles){
                $source=[IO.Path]::GetFullPath((Join-Path $taskRoot ([string]$entry.hostsFile)))
                $allowed=[IO.Path]::GetFullPath((Join-Path $taskRoot 'profiles')).TrimEnd('\')+'\'
                if(-not $source.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($source).TrimEnd('\') -ine $allowed.TrimEnd('\')){continue}
                $item=Get-Item -LiteralPath $source -Force
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1048576){continue}
                $candidate=Get-Map ([IO.File]::ReadAllText($source))
                if(($candidate -join "`n") -ceq ($map -join "`n")){$details.activeProfileId=$entry.id;$details.activeProfileName=$entry.name;break}
            }
        }
    }catch{}
    foreach($file in @(Get-OwnFiles|Where-Object {$_.Extension -eq '.json' -and $_.Name -notlike '*.request.json' -and $_.Length -lt 131072}|Sort-Object LastWriteTime -Descending|Select-Object -First 40)){
        try{$value=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json;if($value.PSObject.Properties['Mode'] -and $value.Mode -in @('ClearCache','Apply') -and $value.Status -eq 'ok'){$details.lastClearedAt=$value.At;break}}catch{}
    }
    $folderMetadata=Get-CacheFolderMetadata
    $details.folders=@($folderMetadata.folders)
    $details.cacheProfileRoot=$folderMetadata.profileRoot
    $details.profileEvidence=$folderMetadata.profileEvidence
    return $details
}
function Test-NoReparseAncestors([string]$Path,[string]$Boundary) {
    $current=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $stop=[IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    if($current -ine $stop -and -not $current.StartsWith($stop+'\',[StringComparison]::OrdinalIgnoreCase)){return $false}
    while($current){
        if(Test-Path -LiteralPath $current){try{if(((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $false}}catch{return $false}}
        if($current -ieq $stop){return $true}
        $current=[IO.Path]::GetDirectoryName($current)
    }
    return $false
}
function Get-CacheFolderMetadata {
    $roaming=[Environment]::GetFolderPath('ApplicationData')
    $root=$null;$evidence=$null
    try{
        foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -OperationTimeoutSec 2 -ErrorAction Stop)){
            if([string]$process.ExecutablePath -notmatch '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$'){continue}
            $match=[regex]::Match([string]$process.CommandLine,'--user-data-dir(?:=|\s+)(?:"([^"]+)"|(\S+))')
            if(-not $match.Success){continue}
            $candidate=[IO.Path]::GetFullPath($(if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value}))
            $knownParent=Join-Path $roaming 'Codex'
            if($candidate.StartsWith($knownParent+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $candidate -PathType Container) -and (Test-NoReparseAncestors $candidate $roaming)){$root=$candidate;$evidence='Путь --user-data-dir работающего установленного ChatGPT.exe';break}
        }
    }catch{}
    if(-not $root){
        $candidate=Join-Path $roaming 'Codex\web\Codex'
        if((Test-Path -LiteralPath $candidate -PathType Container) -and (Test-NoReparseAncestors $candidate $roaming)){$root=$candidate;$evidence='Известный существующий профиль установленного приложения; процесс не подтвердил путь'}
    }
    if(-not $root){return [pscustomobject]@{profileRoot=$null;profileEvidence='Профиль приложения недоступен';folders=@()}}
    return Measure-CacheProfile $root $roaming $evidence
}
function Measure-CacheProfile([string]$Root,[string]$Boundary,[string]$Evidence) {
    $watch=[Diagnostics.Stopwatch]::StartNew();$visited=0
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($context in @(@('application','Приложение','codex-browser-app'),@('browser','Встроенный браузер','Default'))){
        foreach($folderName in @('Cache','Code Cache','GPUCache')){
            $path=Join-Path (Join-Path $root $context[2]) $folderName
            $row=[ordered]@{id=($context[0]+'-'+($folderName -replace ' ','').ToLowerInvariant());name=($context[1]+': '+$folderName);context=$context[0];path=$path;available=$false;bytes=$null;fileCount=$null;measuredAt=(Get-Date).ToString('o');complete=$false;skippedReparseCount=0;detail=$null}
            if(-not (Test-Path -LiteralPath $path -PathType Container)){$row.detail='Папка отсутствует или недоступна';$rows.Add([pscustomobject]$row);continue}
            if(-not (Test-NoReparseAncestors $path $Boundary)){$row.detail='Папка или один из её родителей является ссылкой; обход пропущен';$rows.Add([pscustomobject]$row);continue}
            $row.available=$true
            if($watch.ElapsedMilliseconds -ge 1500 -or $visited -ge 20000){$row.detail='Измерение не начато: достигнуто ограничение общего обхода';$rows.Add([pscustomobject]$row);continue}
            $bytes=0L;$files=0;$limited=$false;$failed=$false
            $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($path)
            while($stack.Count -gt 0){
                if($watch.ElapsedMilliseconds -ge 1500 -or $visited -ge 20000){$limited=$true;break}
                $directory=$stack.Pop()
                try{
                    $directoryInfo=New-Object IO.DirectoryInfo($directory)
                    if(($directoryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$row.skippedReparseCount++;continue}
                    $enumerator=$directoryInfo.EnumerateFileSystemInfos().GetEnumerator()
                    try{
                        while($enumerator.MoveNext()){
                            if($watch.ElapsedMilliseconds -ge 1500 -or $visited -ge 20000){$limited=$true;break}
                            $info=$enumerator.Current;$visited++
                            if(($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$row.skippedReparseCount++;continue}
                            if(($info.Attributes -band [IO.FileAttributes]::Directory) -ne 0){$stack.Push($info.FullName)}else{try{$bytes+=$info.Length;$files++}catch{$failed=$true}}
                        }
                    }finally{if($enumerator -is [IDisposable]){$enumerator.Dispose()}}
                    if($limited){break}
                }catch{$failed=$true}
            }
            $row.bytes=$bytes;$row.fileCount=$files;$row.complete=(-not $limited -and -not $failed -and $row.skippedReparseCount -eq 0)
            if($failed -and $files -eq 0){$row.available=$false;$row.bytes=$null;$row.fileCount=$null}
            $row.detail=if($limited){'Показан измеренный минимум: общий обход ограничен 1,5 секунды и 20 000 элементов'}elseif($failed){'Показан измеренный минимум: часть метаданных недоступна'}elseif($row.skippedReparseCount){'Показан измеренный минимум: ссылки пропущены'}else{'Только метаданные файлов; размер не указывает на неисправность кеша'}
            $row.measuredAt=(Get-Date).ToString('o');$rows.Add([pscustomobject]$row)
        }
    }
    return [pscustomobject]@{profileRoot=$root;profileEvidence=$evidence;folders=@($rows.ToArray())}
}
function Get-AppDetails {
    $running=@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
    $result=[ordered]@{displayName='ChatGPT';running=($running.Count -gt 0);processCount=$running.Count;version=$null;launchTarget=$null;appUserModelId=$null}
    try{$package=Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop|Select-Object -First 1;if($package){$result.version=[string]$package.Version}}catch{}
    try{$app=Get-StartApps -Name 'ChatGPT' -ErrorAction Stop|Where-Object {$_.AppID -like 'OpenAI.Codex_*!*'}|Select-Object -First 1;if($app){$result.appUserModelId=$app.AppID;$result.launchTarget='shell:AppsFolder\'+$app.AppID}}catch{}
    return $result
}
function Invoke-Probe([string]$Id) {
    $hostName=$taskTargets[$Id][1]
    $record=[ordered]@{id=$Id;name=$taskTargets[$Id][0];host=$hostName;status='unknown';ok=$false;latencyMs=$null;httpStatus=$null;tlsValid=$null;actualIP=$null;dnsIPs=@();error=$null;detail=$null;route='Windows';attachmentsVerified=$false}
    try {
        $lookup=[Net.Dns]::BeginGetHostAddresses($hostName,$null,$null)
        if($lookup.AsyncWaitHandle.WaitOne(1000)){$record.dnsIPs=@([Net.Dns]::EndGetHostAddresses($lookup)|ForEach-Object {$_.IPAddressToString})}
    }catch{}
    try {
        $uri=[uri]('https://'+$hostName+'/')
        $proxy=[Net.WebRequest]::DefaultWebProxy
        $proxyUrl=$null
        if($null -eq $proxy -or $proxy.IsBypassed($uri)){$record.route='direct (Windows proxy settings)'}else{
            $selected=$proxy.GetProxy($uri)
            if($selected.AbsoluteUri -eq $uri.AbsoluteUri){$record.route='direct (Windows proxy settings)'}else{
                $safeProxy=New-Object UriBuilder($selected);$safeProxy.UserName='';$safeProxy.Password='';$proxyUrl=$safeProxy.Uri.AbsoluteUri;$record.route='Windows proxy '+$safeProxy.Host+':'+$safeProxy.Port
            }
        }
        $curl=Get-Command curl.exe -ErrorAction Stop
        $format='HTTP=%{http_code}|IP=%{remote_ip}|TLS=%{ssl_verify_result}|SECONDS=%{time_total}|CF=%header{cf-mitigated}'
        $arguments=@('-q','--connect-timeout','2','--max-time','3','--silent','--show-error','--head','--output','NUL','--write-out',$format,$uri.AbsoluteUri)
        if($proxyUrl){$arguments+=@('--proxy',$proxyUrl,'--noproxy','')}else{$arguments+=@('--noproxy','*')}
        $savedPreference=$ErrorActionPreference
        try{$ErrorActionPreference='Continue';$output=@(& $curl.Source @arguments 2>&1|ForEach-Object {"$_"});$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$savedPreference}
        $wireLine=@($output|Where-Object {$_ -match '^HTTP=\d+\|IP='})|Select-Object -Last 1
        $wire=@{}
        if($wireLine){foreach($part in ($wireLine -split '\|')){$pair=$part -split '=',2;$wire[$pair[0]]=$pair[1]};$record.httpStatus=[int]$wire.HTTP;$record.actualIP=$wire.IP;$record.latencyMs=[int]([double]::Parse($wire.SECONDS,[Globalization.CultureInfo]::InvariantCulture)*1000);if($exit -eq 0 -and $record.httpStatus -gt 0){$record.tlsValid=($wire.TLS -eq '0')}}
        if($exit -ne 0){
            $record.status='error'
            $record.error=switch($exit){28{'timeout'}35{'tls_handshake_failed'}60{'certificate_failed'}6{'dns_failed'}5{'proxy_dns_failed'}7{'connection_failed'}default{'transport_failed_'+$exit}}
            $record.detail='Не удалось установить проверенное HTTPS-соединение за отведённое время.'
        }elseif(-not $wireLine){$record.status='unknown';$record.error='probe_parse_failed';$record.detail='Ответ диагностического клиента не удалось прочитать.'}
        elseif($record.httpStatus -eq 403){$record.status='warning';$record.error=if($wire.CF -eq 'challenge'){'cloudflare_challenge'}else{'http_403'};$record.detail=if($wire.CF -eq 'challenge'){'Cloudflare требует проверку. Доступ к приложению и вложениям не подтверждён.'}else{'Сервер ответил 403 на корневой запрос; доступ к приложению не подтверждён.'}}
        elseif($record.httpStatus -eq 400 -and $Id -in @('file','filecentral','filewest')){$record.status='ok';$record.detail='Маршрут и TLS доступны. Хранилище отклонило корневой запрос без файла (HTTP 400); скачивание вложения не проверено.'}
        elseif($record.httpStatus -ge 200 -and $record.httpStatus -lt 400){$record.status='ok';$record.detail='Корневой HTTPS-маршрут доступен. Авторизация, сообщения и вложения не проверены.'}
        else{$record.status='warning';$record.error='http_'+$record.httpStatus;$record.detail='HTTPS-соединение установлено, но корневой HTTP-ответ не подтверждает работу приложения.'}
        $record.ok=$record.status -eq 'ok'
    }catch{$record.status='unknown';$record.error='probe_unavailable';$record.detail='Проверку текущего маршрута завершить не удалось.'}
    return $record
}

try {
    if($Mode -eq 'Probe'){
        if(-not $ProbeName -or -not $ResultPath){throw 'Для внутренней проверки нужны ProbeName и ResultPath.'}
        Write-Result $ResultPath (Invoke-Probe $ProbeName)
        exit 0
    }
    Assert-RunRoot ($Mode -eq 'Check')
    if(-not $ResultPath){$ResultPath=Join-Path $taskRunRoot ('health-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.result.json')}
    if($Mode -eq 'ClearLogs'){
        $resultAbsolute=[IO.Path]::GetFullPath($ResultPath)
        if([IO.Path]::GetDirectoryName($resultAbsolute) -ine [IO.Path]::GetFullPath($taskRunRoot) -or -not (Test-OwnFileName ([IO.Path]::GetFileName($resultAbsolute)))){$ResultPath=$null;throw 'Результат очистки должен сохраняться в run-results под служебным именем.'}
        if((Test-Path -LiteralPath $resultAbsolute) -and (((Get-Item -LiteralPath $resultAbsolute -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){$ResultPath=$null;throw 'Файл результата не должен быть ссылкой.'}
        $protected=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($path in @($PreservePaths)+@($ResultPath)){if($path){[void]$protected.Add([IO.Path]::GetFullPath($path))}}
        $current=if($CurrentLogPath){[IO.Path]::GetFullPath($CurrentLogPath)}else{$null}
        $deleted=0;$bytes=0L;$skipped=0;$failures=0
        foreach($file in @(Get-OwnFiles)){
            $full=[IO.Path]::GetFullPath($file.FullName)
            if([IO.Path]::GetDirectoryName($full) -ine [IO.Path]::GetFullPath($taskRunRoot)){throw 'Удаление за пределами папки журналов запрещено.'}
            if($Scope -eq 'Current' -and $full -ine $current){continue}
            if($protected.Contains($full) -or ((Get-Date)-$file.LastWriteTime).TotalSeconds -lt $MinimumAgeSeconds -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$skipped++;continue}
            try{
                $handle=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$handle.Dispose()
                $again=Get-Item -LiteralPath $full -Force
                if(($again.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$skipped++;continue}
                [IO.File]::Delete($full);$deleted++;$bytes+=$file.Length
            }catch{$failures++}
        }
        $taskReport.logs=Get-LogStats;$taskReport.logs.protectedCount=$skipped
        $taskReport.maintenance=@{deletedCount=$deleted;deletedBytes=$bytes;skippedCount=$skipped;failureCount=$failures;minimumAgeSeconds=$MinimumAgeSeconds}
        $taskReport.health.summary='Удалены только завершённые журналы и запросы менеджера; активные и недавние файлы сохранены.'
    }else{
        $children=New-Object System.Collections.Generic.List[object]
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $nonce=[guid]::NewGuid().ToString('N')
        foreach($id in @('chat','file','filecentral','filewest','cloud')){
            $probePath=Join-Path $taskRunRoot ('health-probe-'+$nonce+'-'+$id+'.result.json')
            $start=New-Object Diagnostics.ProcessStartInfo
            $start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode Probe -ProbeName '+$id+' -ResultPath "'+$probePath+'"'
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $process=[Diagnostics.Process]::Start($start)
            $children.Add([pscustomobject]@{Process=$process;Id=$id;Path=$probePath})
        }
        $taskReport.app=Get-AppDetails
        $taskReport.cache=Get-CacheDetails
        $probes=New-Object System.Collections.Generic.List[object]
        foreach($child in $children){
            $remaining=[Math]::Max(0,8000-[int]$watch.ElapsedMilliseconds)
            $finished=$child.Process.WaitForExit($remaining)
            if(-not $finished){try{$child.Process.Kill()}catch{}}
            if($finished -and (Test-Path -LiteralPath $child.Path -PathType Leaf)){
                try{$probes.Add(([IO.File]::ReadAllText($child.Path)|ConvertFrom-Json))}catch{$finished=$false}
            }else{$finished=$false}
            if(-not $finished){$probes.Add([pscustomobject]@{id=$child.Id;name=$taskTargets[$child.Id][0];host=$taskTargets[$child.Id][1];status='unknown';ok=$false;latencyMs=$null;httpStatus=$null;tlsValid=$null;actualIP=$null;dnsIPs=@();error='probe_deadline';detail='Проверка не завершилась за 8 секунд.';attachmentsVerified=$false})}
            $child.Process.Dispose()
        }
        $taskReport.probes=@($probes.ToArray())
        $errors=@($probes|Where-Object {$_.status -eq 'error'}).Count
        $warnings=@($probes|Where-Object {$_.status -in @('warning','unknown')}).Count
        $overall=if($errors -eq $taskTargets.Count){'offline'}elseif($errors -gt 0 -or $warnings -gt 0){'limited'}else{'online'}
        $summary=switch($overall){offline{'Проверяемые HTTPS-маршруты недоступны.'}limited{'Часть маршрутов ограничена или не подтверждена. Это не проверка скачивания вложений.'}default{'Проверяемые HTTPS-маршруты доступны. Сообщения и скачивание вложений не проверены.'}}
        $taskReport.health=@{status=$overall;summary=$summary;elapsedMs=[int]$watch.ElapsedMilliseconds}
        $taskReport.logs=Get-LogStats
    }
}catch{$taskReport.status='error';$taskReport.error=$_.Exception.Message;$taskReport.health=@{status='unknown';summary=$_.Exception.Message};if($Mode -eq 'ClearLogs' -or $taskRunRootUnsafe){$ResultPath=$null}}
if($ResultPath){Write-Result $ResultPath $taskReport}
Write-Output ($taskReport|ConvertTo-Json -Depth 12)
if($taskReport.status -eq 'error'){exit 1}
exit 0
