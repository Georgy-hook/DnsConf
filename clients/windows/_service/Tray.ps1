#Requires -Version 5.1
$script:taskTray=$null
$script:taskTrayMenu=$null
$script:taskExitRequested=$false
$script:taskConnectionRun=$null
$script:taskConnectionReport=$null
$script:taskConnectionAttempt=[datetime]::MinValue
$script:taskStartupSync=$false
$script:taskStartupKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:taskStartupName='NextDNS Connection Manager'
. (Join-Path $PSScriptRoot 'BridgeStatus.ps1')
$script:taskBridgeAt=[datetime]::MinValue

function Show-TaskManager {
    $script:taskWindow.ShowInTaskbar=$true
    $script:taskWindow.Show()
    $script:taskWindow.WindowState='Normal'
    [void]$script:taskWindow.Activate()
    $script:taskWindow.Topmost=$true;$script:taskWindow.Topmost=$false
    Start-TaskHeroMotion
}
function Hide-TaskManager {
    if(-not $script:taskTray){return}
    $script:taskWindow.Hide()
    # An invisible window should not keep rendering an animated illustration.
    if($script:taskUi.HeroImage.RenderTransform -is [Windows.Media.TranslateTransform]) {
        $script:taskUi.HeroImage.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
    }
}
function Open-TaskRepair {
    try {
        Start-Process -FilePath (Get-ManagerLauncher $script:taskRoot) -ArgumentList '-Repair' | Out-Null
        Add-TaskLog 'Открыто восстановление вложений: диагностика, перезапуск Chrome и дополнительные настройки.'
    } catch {Add-TaskLog ('Не удалось открыть помощь: '+$_.Exception.Message)}
}
function Get-TaskStartupCommand { '"'+(Get-ManagerLauncher $script:taskRoot)+'" -Tray' }
function Get-TaskStartupValue { [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run',$script:taskStartupName,'') }
function Set-TaskStartup([bool]$Enabled) {
    if($script:taskStartupSync){return}
    try {
        if($Enabled) {
            New-Item -Path $script:taskStartupKey -Force | Out-Null
            New-ItemProperty -Path $script:taskStartupKey -Name $script:taskStartupName -Value (Get-TaskStartupCommand) -PropertyType String -Force | Out-Null
        } else {
            $value=Get-TaskStartupValue
            if($value -eq (Get-TaskStartupCommand)){Remove-ItemProperty -LiteralPath $script:taskStartupKey -Name $script:taskStartupName}
        }
        Add-TaskLog $(if($Enabled){'Менеджер будет запускаться с Windows в трее.'}else{'Автозапуск менеджера отключён. Настройки DNS и hosts сохраняются.'})
    } catch {
        Add-TaskLog ('Автозапуск не изменён: '+$_.Exception.Message) -Kind Problems
        $script:taskStartupSync=$true
        $script:taskUi.StartWithWindows.IsChecked=((Get-TaskStartupValue) -eq (Get-TaskStartupCommand))
        $script:taskStartupSync=$false
    }
}
function Start-TaskConnection {
    if($script:taskConnectionRun -or $SmokeTest -or $RenderPreview){return}
    $script:taskConnectionAttempt=Get-Date
    try {
        $script:taskConnectionRun=Start-ConnectionCheck $script:taskRoot
        if($script:taskTray){$script:taskTray.Text='NextDNS · менеджер работает · проверка DNS';$script:taskTrayStatus.Text='Проверяю DNS в фоне…'}
    } catch {
        $script:taskConnectionReport=New-ConnectionReport @()
        Set-TaskConnectionView
        Add-TaskLog ('DNS-проверка недоступна: '+$_.Exception.Message) -Kind Problems
    }
}
function Set-TaskConnectionView {
    $report=$script:taskConnectionReport
    if(-not $report){return}
    $ready=$report.State -eq 'ready'
    $script:taskUi.HealthTitle.Text=$report.Title
    $script:taskUi.HealthDescription.Text=$report.Next
    $script:taskUi.HealthBadge.Text=if($ready){'DNS НАСТРОЕН · GIF НЕ ПРОВЕРЕНА'}else{'НУЖНО ВНИМАНИЕ · DNS'}
    $script:taskUi.HealthBadge.Foreground=Get-TaskBrush $(if($ready){'#98EFD5'}else{'#F1D19B'})
    $script:taskUi.HealthPill.Background=Get-TaskBrush $(if($ready){'#244C43'}else{'#4A3D2A'})
    $at=([datetime]$report.At).ToString('HH:mm:ss')
    if($script:taskTray) {
        $script:taskTray.Text='NextDNS · '+$(if($ready){'DNS настроен'}else{'DNS требует проверки'})+' · '+$at
        $script:taskTrayStatus.Text='Менеджер работает · '+$report.Title
        $script:taskTrayTime.Text='DNS: '+$at+' · повтор каждые 5 минут'
        $script:taskTray.Icon=if($ready){$script:taskTrayIcon}else{[Drawing.SystemIcons]::Warning}
    }
}
function Poll-TaskConnection {
    if(((Get-Date)-$script:taskBridgeAt).TotalSeconds -ge 5){$script:taskBridgeAt=Get-Date;$script:taskUi.TransportStatusText.Text=(Get-BridgeStatus).Text}
    if($script:taskConnectionRun) {
        $report=Receive-ConnectionCheck $script:taskConnectionRun
        if($report) {
            $script:taskConnectionRun=$null
            $old=$script:taskConnectionReport
            $script:taskConnectionReport=$report
            Set-TaskConnectionView
            if(-not $old -or $old.State -ne $report.State) {
                Add-TaskLog ($report.Title+'. '+$report.Next) -Kind $(if($report.State -eq 'ready'){'Info'}else{'Problems'})
                try {
                    $path=Join-Path (Join-Path $script:taskRoot 'run-results') ('gui-health-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
                    @{At=$report.At;Mode='DNS';Status='ok';Message=($report.Title+'. '+$report.Next);AttachmentsVerified=$false}|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
                } catch {Add-TaskLog 'Не удалось сохранить историю DNS-проверки.' -Kind Problems}
            }
        }
    } elseif(((Get-Date)-$script:taskConnectionAttempt).TotalSeconds -ge 300) {Start-TaskConnection}
    if($script:taskConnectionReport) {
        $script:taskUi.HealthAtText.Text='DNS · '+([datetime]$script:taskConnectionReport.At).ToString('HH:mm:ss')+$(if($script:taskConnectionRun){' · обновляется…'}else{' · авто: 5 мин'})
    }
    if(('NextDNS.Desktop.DesktopInstance' -as [type]) -and [NextDNS.Desktop.DesktopInstance]::ConsumeActivation()) {Show-TaskManager}
}
function Initialize-TaskTray {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    $script:taskTrayIcon=[Drawing.Icon]::new((Join-Path $script:taskRoot 'assets\app.ico'))
    $script:taskTray=[Windows.Forms.NotifyIcon]::new()
    $script:taskTray.Icon=$script:taskTrayIcon
    $script:taskTray.Text='NextDNS · менеджер работает · проверка DNS'
    $script:taskTrayMenu=[Windows.Forms.ContextMenuStrip]::new()
    $script:taskTrayStatus=$script:taskTrayMenu.Items.Add('Менеджер работает · проверка DNS…');$script:taskTrayStatus.Enabled=$false
    $script:taskTrayTime=$script:taskTrayMenu.Items.Add('Проверка каждые 5 минут');$script:taskTrayTime.Enabled=$false
    [void]$script:taskTrayMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    $open=$script:taskTrayMenu.Items.Add('Открыть NextDNS');$open.Add_Click({Show-TaskManager})
    $check=$script:taskTrayMenu.Items.Add('Проверить подключение');$check.Add_Click({Show-TaskManager;Start-TaskConnection;Start-TaskHealth 'Check'})
    $repair=$script:taskTrayMenu.Items.Add('GIF / вложения не работают…');$repair.Add_Click({Open-TaskRepair})
    [void]$script:taskTrayMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    $quit=$script:taskTrayMenu.Items.Add('Выйти из менеджера');$quit.Add_Click({$script:taskExitRequested=$true;$script:taskWindow.Close()})
    $script:taskTray.ContextMenuStrip=$script:taskTrayMenu
    $script:taskTray.Add_MouseClick({param($sender,$eventArgs) if($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left){Show-TaskManager}})
    $script:taskTray.Visible=$true
    $script:taskUi.ManagerStatusText.Text='● Менеджер работает'
    $script:taskUi.StartWithWindows.IsChecked=((Get-TaskStartupValue) -eq (Get-TaskStartupCommand))
    $script:taskUi.StartWithWindows.Add_Checked({Set-TaskStartup $true})
    $script:taskUi.StartWithWindows.Add_Unchecked({Set-TaskStartup $false})
    $script:taskUi.HideToTrayButton.Add_Click({Hide-TaskManager})
    $script:taskUi.ExitManagerButton.Add_Click({$script:taskExitRequested=$true;$script:taskWindow.Close()})
}
function Close-TaskTray {
    Stop-ConnectionCheck $script:taskConnectionRun
    if($script:taskTray){$script:taskTray.Visible=$false;$script:taskTray.Dispose();$script:taskTray=$null}
    if($script:taskTrayMenu){$script:taskTrayMenu.Dispose()}
    if($script:taskTrayIcon){$script:taskTrayIcon.Dispose()}
}
