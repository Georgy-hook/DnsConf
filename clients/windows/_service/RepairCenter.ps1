#Requires -Version 5.1
[CmdletBinding()]
param([switch]$SmokeTest,[string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $PSScriptRoot 'RepairFunctions.ps1')
. (Join-Path $PSScriptRoot 'Connection.ps1')
. (Join-Path $PSScriptRoot 'BrowserRecovery.ps1')
. (Join-Path $PSScriptRoot 'BridgeStatus.ps1')
[xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'RepairCenter.xaml') -Raw -Encoding UTF8
$reader=[Xml.XmlNodeReader]::new($xaml)
try {$window=[Windows.Markup.XamlReader]::Load($reader)} finally {$reader.Close()}
$ui=@{}
foreach($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')){
    $name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($name){$ui[$name]=$window.FindName($name)}
}
$script:connectionRun=$null
$script:browserRun=$null
$script:browserAt=[datetime]::MinValue
$script:networkProcess=$null
$script:networkMode='Install'
$script:networkResult=$null
$script:repairLogBase=Join-Path (Join-Path $PSScriptRoot 'run-results') ('gui-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot 'assets\app.ico'))
function Add-RepairEvent([string]$Message) {
    $ui.StatusText.Text=$Message
    $line=(Get-Date -Format 'HH:mm:ss')+'  '+$Message
    $ui.RepairLog.Text=(@(($ui.RepairLog.Text -split "`r?`n") | Where-Object {$_} | Select-Object -Last 49)+$line) -join "`r`n"
    try {
        [IO.Directory]::CreateDirectory((Split-Path $script:repairLogBase -Parent))|Out-Null
        $path=$script:repairLogBase+'.log'
        if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 128KB){[IO.File]::WriteAllText($path,'',[Text.UTF8Encoding]::new($true))}
        [IO.File]::AppendAllText($path,(Get-Date -Format 'yyyy-MM-dd')+' '+$line+[Environment]::NewLine,[Text.UTF8Encoding]::new($true))
        @{At=(Get-Date).ToString('o');Mode='Восстановление';Status='info';Message=$Message;AttachmentsVerified=$false}|ConvertTo-Json|Set-Content -LiteralPath ($script:repairLogBase+'.json') -Encoding UTF8
    } catch {}
}
function Start-RepairDiagnosis {
    if($script:connectionRun){return}
    try {
        $script:connectionRun=Start-ConnectionCheck $PSScriptRoot
        $ui.ControlButton.IsEnabled=$false
        $ui.DiagnosisTitle.Text='Проверяю DNS…'
        $ui.ControlStatus.Text='Проверка новых поддоменов занимает до 12 секунд. Окно остаётся доступным.'
    } catch {Add-RepairEvent ('Не удалось запустить проверку: '+$_.Exception.Message)}
}
function Update-RepairBrowserState {
    $script:browserAt=Get-Date
    $processes=@(Get-RecoveryChromeProcesses)
    $ui.BrowserStatus.Text=if(-not $processes.Count){'Chrome сейчас закрыт. Перезапуск не требуется — можно открыть его заново.'}elseif(@($processes|Where-Object {$_.MainWindowHandle -ne [IntPtr]::Zero}).Count){'Chrome запущен. Перезапуск обновит его сетевые соединения.'}else{'Chrome работает в фоне без видимых окон. Для полного выхода используйте его меню ⋮ → Выход.'}
    $ui.RestartButton.IsEnabled=$processes.Count -gt 0 -and -not $script:browserRun
    $bridge=Get-BridgeStatus
    $ui.BridgeStatus.Text=$bridge.Text
    if(-not $script:networkProcess){$ui.BridgeRestartButton.IsEnabled=$bridge.Active;$ui.BridgeRestoreButton.IsEnabled=$bridge.Active;$ui.BridgeInstallButton.IsEnabled=-not $bridge.Active}
}
function Show-NetworkConfirmation([string]$Mode) {
    $script:networkMode=$Mode
    $ui.NetworkConfirmText.Text=switch($Mode){
        Install {'Будет установлена служба подключения к вашему профилю NextDNS. Она запускается до входа в Windows и использует защищённое соединение TLS 1.3. Сетевые настройки сохранятся для возврата. Прежний клиент NextDNS будет отключён; GUI можно закрывать.'}
        Restart {'Будет перезапущена только служба подключения NextDNS. Во время перезапуска DNS может ненадолго не отвечать.'}
        Restore {'Вернутся DNS и прежняя служба NextDNS из резервной копии. NextDNS Bridge будет отключён. Это возврат предыдущей конфигурации сети.'}
    }
    $ui.NetworkConfirm.Visibility='Visible';$ui.NetworkConfirm.BringIntoView()
}
$ui.BridgeInstallButton.Add_Click({Show-NetworkConfirmation 'Install'})
$ui.BridgeRestartButton.Add_Click({Show-NetworkConfirmation 'Restart'})
$ui.BridgeRestoreButton.Add_Click({Show-NetworkConfirmation 'Restore'})
$ui.NetworkCancelButton.Add_Click({$ui.NetworkConfirm.Visibility='Collapsed'})
$ui.NetworkConfirmButton.Add_Click({
    if($script:networkProcess -or $script:repairProcess){return}
    try {
        $runRoot=Join-Path $PSScriptRoot 'run-results';[IO.Directory]::CreateDirectory($runRoot)|Out-Null
        if((Get-Item -LiteralPath $runRoot).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Папка результатов не должна быть ссылкой.'}
        $script:networkResult=Join-Path $runRoot ('gui-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'NetworkSetup.ps1')+'"'),'-Mode',$script:networkMode,'-ExpectedUserSid',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'-ResultPath',('"'+$script:networkResult+'"'))
        Add-RepairEvent 'Windows запросит подтверждение настройки службы NextDNS. Отмена оставит текущую сеть.'
        $script:networkProcess=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
        $ui.NetworkConfirm.Visibility='Collapsed'
        foreach($name in @('BridgeInstallButton','BridgeRestartButton','BridgeRestoreButton','NetworkConfirmButton','ApplyButton')){$ui[$name].IsEnabled=$false}
        Add-RepairEvent 'Выполняется настройка службы. Ожидаю результат проверки DNS Windows.'
    } catch {Add-RepairEvent $(if($_.Exception.ToString() -match '1223|cancel|отмен'){'Подтверждение Windows отменено. Сеть не изменена.'}else{$_.Exception.Message})}
})
$script:repairPlan=$null
$script:repairProcess=$null
$script:repairResult=$null
$script:repairChanging=$false
function Show-RepairPlan {
    try {
        $plan=Get-RepairPlan $ui.ManualBox.Text
        $script:repairChanging=$true
        $ui.ManualBox.Text=''
        $script:repairChanging=$false
        $script:repairPlan=$plan
        $ui.PlanLabel.Text='Добавится адресов: '+$plan.Domains.Count+'. Маршрут текущего профиля: '+$plan.RouteAddress
        $ui.PlanBox.Text=(@($plan.Domains | ForEach-Object {$plan.RouteAddress+'  '+$_}) -join "`r`n")
        $ui.ApplyButton.IsEnabled=$plan.Domains.Count -gt 0
        Add-RepairEvent $(if($plan.Domains.Count){'Проверьте список. Нажатие «Применить» откроет системный запрос Windows.'}elseif(-not $plan.CacheAvailable){'DNS-кеш недоступен. Общая диагностика выше не зависит от этого поиска.'}else{'Новых адресов нет — добавлять hosts не требуется по результату поиска. Если DNS настроен, попробуйте перезапуск Chrome выше.'})
    } catch {$ui.ManualBox.Clear();$script:repairPlan=$null;$ui.ApplyButton.IsEnabled=$false;$ui.PlanBox.Clear();$ui.StatusText.Text=$_.Exception.Message}
}
$ui.ScanButton.Add_Click({Show-RepairPlan})
$ui.ManualBox.Add_TextChanged({if(-not $script:repairChanging){$script:repairPlan=$null;$ui.ApplyButton.IsEnabled=$false}})
$ui.ControlButton.Add_Click({Start-RepairDiagnosis})
$ui.DnsSettingsButton.Add_Click({Start-Process 'https://my.nextdns.io'|Out-Null})
$ui.ChromeButton.Add_Click({
    try {
        Start-Process -FilePath (Get-ManagerChrome) -ArgumentList 'https://chatgpt.com/dots/home'|Out-Null
        Add-RepairEvent 'Открыта веб-версия Dot в Chrome. Это не настольное приложение. Если нужного Dot здесь нет, вернитесь в приложение.'
    } catch {$ui.StatusText.Text=$_.Exception.Message}
})
$ui.OpenChromeButton.Add_Click({try {Start-Process -FilePath (Get-ManagerChrome) -ArgumentList '--restore-last-session'|Out-Null;Add-RepairEvent 'Chrome запущен с запросом восстановления обычных вкладок.'}catch{Add-RepairEvent $_.Exception.Message}})
$ui.DesktopButton.Add_Click({
    try {
        $apps=@(Get-StartApps | Where-Object {$_.AppID -match '^OpenAI\.' -and $_.Name -match 'ChatGPT|Codex'} | Sort-Object @{Expression={if($_.Name -eq 'ChatGPT'){0}else{1}}})
        if(-not $apps.Count){throw 'Зарегистрированное приложение ChatGPT не найдено. Откройте свой Dot обычным ярлыком.'}
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('shell:AppsFolder\'+$apps[0].AppID)|Out-Null
        Add-RepairEvent 'Отправлен запрос на открытие приложения. Если оно уже запущено, это не перезапуск.'
    } catch {Add-RepairEvent $_.Exception.Message}
})
$ui.RestartButton.Add_Click({$ui.SavedWork.IsChecked=$false;$ui.RestartConfirm.Visibility='Visible';$ui.RestartConfirm.BringIntoView()})
$ui.RestartCancelButton.Add_Click({$ui.RestartConfirm.Visibility='Collapsed';$ui.SavedWork.IsChecked=$false})
$ui.SavedWork.Add_Checked({$ui.RestartConfirmButton.IsEnabled=$true})
$ui.SavedWork.Add_Unchecked({$ui.RestartConfirmButton.IsEnabled=$false})
$ui.RestartConfirmButton.Add_Click({
    if($script:browserRun -or $ui.SavedWork.IsChecked -ne $true){return}
    try {
        $script:browserRun=Start-BrowserRecovery
        foreach($name in @('RestartButton','RestartConfirmButton','ChromeButton','OpenChromeButton')){$ui[$name].IsEnabled=$false}
        $ui.RestartConfirm.Visibility='Collapsed'
        Add-RepairEvent 'Запрошено обычное закрытие Chrome. Ожидаю завершения всех его процессов.'
    } catch {Add-RepairEvent $_.Exception.Message}
})
$ui.ApplyButton.Add_Click({
    if(-not $script:repairPlan -or $script:repairProcess){return}
    try {
        $runRoot=Join-Path $PSScriptRoot 'run-results'
        [IO.Directory]::CreateDirectory($runRoot)|Out-Null
        if(((Get-Item -LiteralPath $runRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Папка результатов не должна быть ссылкой.'}
        $id='gui-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $request=Join-Path $runRoot ($id+'.request.json')
        $script:repairResult=Join-Path $runRoot ($id+'.json')
        @{Domains=@($script:repairPlan.Domains);RouteAddress=$script:repairPlan.RouteAddress;HostsHash=$script:repairPlan.HostsHash;ExpectedUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;ResultPath=$script:repairResult}|ConvertTo-Json|Set-Content -LiteralPath $request -Encoding UTF8
        $ui.StatusText.Text='Ожидается подтверждение в системном окне Windows. Отмена не применяет настройки.'
        $ui.ApplyButton.IsEnabled=$false;$ui.ScanButton.IsEnabled=$false;$ui.ManualBox.IsEnabled=$false
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'RepairWorker.ps1')+'"'),'-RequestPath',('"'+$request+'"'))
        $script:repairProcess=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        $ui.StatusText.Text='Подтверждение получено. Сохраняются профиль и резервная копия; затем проверяются hosts и DNS.'
    } catch {
        $ui.StatusText.Text=if($_.Exception.ToString() -match '1223|cancel|отмен'){'Запрос Windows отменён. Настройки не применены. Можно повторить.'}else{$_.Exception.Message}
        $ui.ScanButton.IsEnabled=$true;$ui.ManualBox.IsEnabled=$true;$ui.ApplyButton.IsEnabled=$null -ne $script:repairPlan -and $script:repairPlan.Domains.Count -gt 0
    }
})
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({
    if($script:networkProcess -and $script:networkProcess.HasExited){
        try {
            if(-not(Test-Path -LiteralPath $script:networkResult)){throw 'Отчёт настройки не получен. Применение не подтверждено.'}
            $result=Get-Content -LiteralPath $script:networkResult -Raw -Encoding UTF8|ConvertFrom-Json
            Add-RepairEvent ([string]$result.Message)
            Start-RepairDiagnosis
        } catch {Add-RepairEvent $_.Exception.Message}
        finally {$script:networkProcess.Dispose();$script:networkProcess=$null;$ui.NetworkConfirmButton.IsEnabled=$true;Update-RepairBrowserState}
    }
    if($script:connectionRun) {
        $report=Receive-ConnectionCheck $script:connectionRun
        if($report) {
            $script:connectionRun=$null;$ui.ControlButton.IsEnabled=$true
            $ui.DiagnosisTitle.Text=$report.Title;$ui.ControlStatus.Text=$report.Next
            $details=@('Проверено '+([datetime]$report.At).ToString('dd.MM HH:mm:ss'))
            foreach($check in $report.Checks){$details+=$check.Label+' · '+$check.Domain+': '+$(if($check.Addresses.Count){$check.Addresses -join ', '}else{'ответ не получен'})}
            $details+='Проверены новые имена через DNS Windows. Воспроизведение GIF и соединения внутри Dot эта проверка не видит.'
            $ui.RouteDetails.Text=$details -join "`r`n"
            Add-RepairEvent ($report.Title+'. Воспроизведение GIF не проверялось.')
        }
    }
    if($script:browserRun) {
        try {
            $result=Update-BrowserRecovery $script:browserRun
            $ui.BrowserStatus.Text=$result.Message
            if($result.Done) {
                Add-RepairEvent $result.Message;$script:browserRun=$null
                foreach($name in @('RestartButton','ChromeButton','OpenChromeButton')){$ui[$name].IsEnabled=$true}
                $ui.SavedWork.IsChecked=$false
                if($result.Success){Start-RepairDiagnosis}
            }
        } catch {$script:browserRun=$null;Add-RepairEvent ('Перезапуск не подтверждён: '+$_.Exception.Message);foreach($name in @('RestartButton','ChromeButton','OpenChromeButton')){$ui[$name].IsEnabled=$true}}
    } elseif(((Get-Date)-$script:browserAt).TotalSeconds -ge 3) {Update-RepairBrowserState}
    if(('NextDNS.Desktop.DesktopInstance' -as [type]) -and [NextDNS.Desktop.DesktopInstance]::ConsumeActivation()) {$window.WindowState='Normal';$window.Show();[void]$window.Activate();$window.Topmost=$true;$window.Topmost=$false}
    if($script:repairProcess -and $script:repairProcess.HasExited) {
        try {
            if(-not(Test-Path -LiteralPath $script:repairResult)){throw 'Отчёт не получен. Изменение не подтверждено; повторите поиск адресов.'}
            $result=Get-Content -LiteralPath $script:repairResult -Raw -Encoding UTF8|ConvertFrom-Json
            $ui.StatusText.Text=[string]$result.Message
            if($result.Status -ne 'ok'){$ui.StatusText.Text+=' Если профиль появился в списке, он мог остаться неприменённым.'}
        } catch {$ui.StatusText.Text=$_.Exception.Message}
        finally {$script:repairProcess.Dispose();$script:repairProcess=$null;$script:repairPlan=$null;$ui.ApplyButton.IsEnabled=$false;$ui.ScanButton.IsEnabled=$true;$ui.ManualBox.IsEnabled=$true}
    }
})
$window.Add_Closing({param($sender,$eventArgs) if($script:repairProcess -or $script:browserRun -or $script:networkProcess){$eventArgs.Cancel=$true;$ui.StatusText.Text='Дождитесь завершения текущего действия.'}})
$window.Add_Closed({$timer.Stop();Stop-ConnectionCheck $script:connectionRun})
if($SmokeTest) {
    $window.Content.Measure([Windows.Size]::new(792,740));$window.Content.Arrange([Windows.Rect]::new(0,0,792,740));$window.Content.UpdateLayout()
    if($PreviewPath){$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(792,740,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($window.Content);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create($PreviewPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}}
    Write-Output 'Repair UI smoke: OK';exit 0
}
$window.MaxHeight=[Windows.SystemParameters]::WorkArea.Height
Update-RepairBrowserState
$window.Add_Loaded({Start-RepairDiagnosis})
$timer.Start();[void]$window.ShowDialog()
