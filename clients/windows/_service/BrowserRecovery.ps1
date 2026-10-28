#Requires -Version 5.1
# Request a normal close only. Never bypass a browser prompt or kill its processes.
function Get-RecoveryChromeProcesses {
    @(Get-Process -Name chrome -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId})
}
function Start-BrowserRecovery {
    $exe=Get-ManagerChrome
    $processes=@(Get-RecoveryChromeProcesses)
    if(-not $processes.Count){throw 'Chrome уже закрыт. Нажмите «Открыть Chrome», чтобы создать новые соединения.'}
    $windows=@($processes|Where-Object {$_.MainWindowHandle -ne [IntPtr]::Zero})
    if(-not $windows.Count){throw 'Chrome работает только в фоне. Откройте его и выберите меню ⋮ → Выход, затем запустите снова. Принудительное завершение не применяется.'}
    $profiles=@()
    foreach($proc in $windows) {
        $details=Get-CimInstance Win32_Process -Filter ('ProcessId='+$proc.Id) -ErrorAction Stop
        if(-not $details.ExecutablePath -or [IO.Path]::GetFullPath($details.ExecutablePath) -ine [IO.Path]::GetFullPath($exe)){throw 'Открыт Chrome из другой папки. Закройте его отдельно, чтобы восстановление запустило правильную версию браузера.'}
        $command=$details.CommandLine
        if($command -match '--user-data-dir(?:=|\s)'){throw 'Открыт Chrome с отдельной папкой профиля (например, тестовый). Закройте его отдельно, чтобы восстановление не затронуло чужой сеанс.'}
        if($command -match '--profile-directory=(?:"([^"]+)"|(\S+))'){
            $profile=if($Matches[1]){$Matches[1]}else{$Matches[2]}
            if($profile -match '^(Default|Profile \d+)$'){$profiles+=$profile}
        }
    }
    $run=[pscustomobject]@{Exe=$exe;At=(Get-Date);Profiles=@($profiles|Select-Object -Unique);Handles=[Collections.Generic.HashSet[long]]::new();Stage='closing';DeadlineSeconds=25}
    foreach($proc in $windows){[void]$run.Handles.Add($proc.MainWindowHandle.ToInt64());[void]$proc.CloseMainWindow()}
    return $run
}
function Update-BrowserRecovery($Run) {
    $processes=@(Get-RecoveryChromeProcesses)
    if($Run.Stage -eq 'opening'){
        if(@($processes|Where-Object {$_.MainWindowHandle -ne [IntPtr]::Zero}).Count){return [pscustomobject]@{Done=$true;Success=$true;Message='Chrome закрылся и открылся заново. Запрошено восстановление обычных вкладок. Соединения обновлены; воспроизведение GIF ещё не проверено.'}}
        if(((Get-Date)-$Run.At).TotalSeconds -gt 15){return [pscustomobject]@{Done=$true;Success=$false;Message='Chrome завершился, запрос на запуск отправлен, но окно пока не обнаружено. Запустите Chrome обычным способом.'}}
        return [pscustomobject]@{Done=$false;Message='Chrome завершился. Ожидаю новое окно…'}
    }
    if(-not $processes.Count){
        $args=@('--restore-last-session')
        if($Run.Profiles.Count -eq 1){$args+=('--profile-directory="'+$Run.Profiles[0]+'"')}
        Start-Process -FilePath $Run.Exe -ArgumentList $args | Out-Null
        $Run.Stage='opening';$Run.At=Get-Date
        return [pscustomobject]@{Done=$false;Message='Все процессы Chrome завершились. Открываю сохранённый сеанс…'}
    }
    if(((Get-Date)-$Run.At).TotalSeconds -gt $Run.DeadlineSeconds){
        return [pscustomobject]@{Done=$true;Success=$false;Message='Chrome не завершился: возможно, он ждёт подтверждения закрытия страницы или работает в фоне. Завершите через меню Chrome ⋮ → Выход и нажмите «Открыть Chrome». Принудительно процессы не закрывались.'}
    }
    foreach($proc in @($processes|Where-Object {$_.MainWindowHandle -ne [IntPtr]::Zero})){
        if($Run.Handles.Add($proc.MainWindowHandle.ToInt64())){[void]$proc.CloseMainWindow()}
    }
    [pscustomobject]@{Done=$false;Message='Ожидаю обычного закрытия Chrome… Если браузер спрашивает о несохранённых данных, решите в его окне.'}
}
