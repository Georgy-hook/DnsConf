#Requires -Version 5.1
[CmdletBinding()]
param(
 [ValidateSet('Install','Restart','Restore')][string]$Mode='Install',
 [Parameter(Mandatory=$true)][string]$ExpectedUserSid,
 [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'
$installRoot=Join-Path $env:ProgramFiles 'NextDNS Bridge'
$dataRoot=Join-Path $env:ProgramData 'NextDNSBridge'
$backupRoot=Join-Path $dataRoot 'backup'
$backupFile=Join-Path $backupRoot 'network.json'
$binary=Join-Path $installRoot 'NextDNSBridge.exe'
$serviceName='NextDNSBridge'
$changed=$false
function Assert-NoReparse([string]$Path) {
 $p=[IO.Path]::GetFullPath($Path)
 while($p) {
  if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Путь содержит ссылку: '+$p}
  $parent=Split-Path $p -Parent
  if($parent -eq $p){break};$p=$parent
 }
}
function Protect-Directory([string]$Path,[string]$Access) {
 Assert-NoReparse $Path
 [IO.Directory]::CreateDirectory($Path)|Out-Null
 $acl=[Security.AccessControl.DirectorySecurity]::new()
 $acl.SetAccessRuleProtection($true,$false)
 $rights=@{'S-1-5-18'='FullControl';'S-1-5-32-544'='FullControl'}
 if($Access -eq 'Program'){$rights['S-1-5-32-545']='ReadAndExecute';$rights['S-1-5-19']='ReadAndExecute'}
 if($Access -eq 'Data'){$rights['S-1-5-32-545']='ReadAndExecute';$rights['S-1-5-19']='Modify'}
 foreach($sid in $rights.Keys){$rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]$rights[$sid],([Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow);$acl.AddAccessRule($rule)}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-SetupResult([string]$Status,[string]$Message) {
 [ordered]@{Status=$Status;Mode=$Mode;At=(Get-Date).ToString('o');Message=$Message;Error=$(if($Status -eq 'error'){$Message}else{$null});AttachmentsVerified=$false}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ResultPath -Encoding UTF8
}
function Get-OwnService {
 $service=Get-CimInstance Win32_Service -Filter "Name='NextDNSBridge'"
 if($service -and $service.PathName -cne ('"'+$binary+'"')){throw 'Имя службы NextDNSBridge занято другим приложением.'}
 return $service
}
function Get-SavedAdapter($Record) {
 $adapters=@(Get-NetAdapter -IncludeHidden | Where-Object {[string]$_.InterfaceGuid -eq [string]$Record.Guid})
 if($adapters.Count -ne 1){throw 'Не найден сохранённый сетевой адаптер.'}
 return $adapters[0]
}
function Read-NetworkBackup {
 Assert-NoReparse $backupFile
 $saved=Get-Content -LiteralPath $backupFile -Raw -Encoding UTF8|ConvertFrom-Json
 if($saved.Version -ne 1 -or @($saved.Adapters).Count -lt 1 -or @($saved.Adapters).Count -gt 8){throw 'Некорректная резервная копия сети.'}
 foreach($record in $saved.Adapters){$id=[guid]::Empty;if(-not [guid]::TryParse([string]$record.Guid,[ref]$id)){throw 'Некорректный адаптер в резервной копии.'};foreach($address in $record.Servers){$ip=$null;if(-not [Net.IPAddress]::TryParse([string]$address,[ref]$ip)){throw 'Некорректный DNS в резервной копии.'}}}
 foreach($entry in @($saved.Startup)){if($entry -and $entry.Key -notin @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Run')){throw 'Некорректный раздел автозапуска в резервной копии.'}}
 return $saved
}
function Disable-LegacyDriver($Backup) {
 $key='HKLM:\SYSTEM\CurrentControlSet\Services\NextDNSEngine'
 if(-not(Test-Path -LiteralPath $key)){return}
 $start=[int](Get-ItemPropertyValue -LiteralPath $key -Name Start)
 if($Backup -is [Collections.IDictionary]){
  if(-not $Backup.Contains('LegacyDriverStart')){$Backup['LegacyDriverStart']=$start}
 } elseif(-not $Backup.PSObject.Properties['LegacyDriverStart']){$Backup|Add-Member -NotePropertyName LegacyDriverStart -NotePropertyValue $start}
 $Backup|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $backupFile -Encoding UTF8
 Set-ItemProperty -LiteralPath $key -Name Start -Value 4
}
function Restore-Network($Backup) {
 if(Get-OwnService){Stop-Service -Name $serviceName -ErrorAction SilentlyContinue}
 foreach($record in $Backup.Adapters){$adapter=Get-SavedAdapter $record;if(@($record.Servers).Count){Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($record.Servers)}else{Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses}}
 if($null -ne $Backup.LegacyDriverStart){Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\NextDNSEngine' -Name Start -Value ([int]$Backup.LegacyDriverStart)}
 if($Backup.Legacy){
  $startup=switch($Backup.Legacy.StartMode){'Auto'{'Automatic'}'Manual'{'Manual'}default{'Disabled'}}
  Set-Service -Name NextDNSService -StartupType $startup
  if($Backup.Legacy.State -eq 'Running'){Start-Service -Name NextDNSService}
 }
 foreach($entry in @($Backup.Startup)) {if($entry){New-ItemProperty -Path $entry.Key -Name NextDNS -Value ([string]$entry.Value) -PropertyType String -Force|Out-Null}}
 foreach($path in @($Backup.ExclusionPaths)) {
  if(-not $path){continue}
  $allowed=[Environment]::GetFolderPath('Desktop').TrimEnd('\')+'\'
  if(-not ([IO.Path]::GetFullPath($path)).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -notin @('list-exclude-user.txt','ipset-exclude-user.txt')){throw 'Некорректный путь исключений в резервной копии.'}
  Assert-NoReparse $path
  if(Test-Path -LiteralPath $path){$text=[IO.File]::ReadAllText($path);$text=[regex]::Replace($text,'(?m)^# BEGIN NEXTDNS BRIDGE\r?\n[\s\S]*?^# END NEXTDNS BRIDGE\r?\n?','');[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))}
 }
 Clear-DnsClientCache
}
function Test-InstalledDNS {
 $nonce='verify-'+[guid]::NewGuid().ToString('N').Substring(0,12)
 $checks=@(@{Host=($nonce+'.oaiusercontent.com');Expected=@('45.13.237.213','37.221.93.128')},@{Host=($nonce+'.chatgpt.com');Expected=@('192.255.159.241','192.255.159.240')},@{Host='example.com';Expected=@()})
 foreach($check in $checks){$task=[Net.Dns]::GetHostAddressesAsync($check.Host);if(-not $task.Wait(10000)){throw 'Проверка DNS Windows не получила ответ.'};$addresses=@($task.Result|ForEach-Object {$_.IPAddressToString});if(-not $addresses.Count){throw 'DNS вернул пустой ответ.'};if($check.Expected.Count -and @($addresses|Where-Object {$_ -notin $check.Expected}).Count){throw 'Профиль NextDNS вернул неожиданный маршрут.'}}
}
try {
 $runRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'run-results'))
 $ResultPath=[IO.Path]::GetFullPath($ResultPath)
 if([IO.Path]::GetDirectoryName($ResultPath) -ine $runRoot -or [IO.Path]::GetFileName($ResultPath) -cnotmatch '^gui-\d{8}-\d{6}-[a-f0-9]{8}\.json$'){throw 'Недопустимый путь результата.'}
 Assert-NoReparse $runRoot
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 if($sid -cne $ExpectedUserSid){throw 'Подтвердите Windows от того же пользователя.'}
 if(-not [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Для настройки службы нужны права администратора Windows.'}
 Assert-NoReparse $installRoot;Assert-NoReparse $dataRoot
 if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $backupFile)){throw 'Резервная копия сети не найдена.'}
  $backup=Read-NetworkBackup
  Restore-Network $backup
  if(Get-OwnService){Set-Service -Name $serviceName -StartupType Disabled}
  [IO.File]::WriteAllText((Join-Path $installRoot 'enabled.txt'),'0')
  Write-SetupResult 'ok' 'Предыдущие DNS и служба NextDNS восстановлены. Мост отключён; резервная копия сохранена.'
  exit 0
 }
 if($Mode -eq 'Restart'){
  if(-not(Get-OwnService)){throw 'Сначала установите восстановление NextDNS.'}
  $backup=Read-NetworkBackup
  Disable-LegacyDriver $backup
  Restart-Service -Name $serviceName
  Clear-DnsClientCache
  Test-InstalledDNS
  Write-SetupResult 'ok' 'Служба NextDNS Bridge перезапущена; DNS Windows и маршруты файлов проверены. Загрузка GIF проверяется отдельно.'
  exit 0
 }
 $source=Join-Path $PSScriptRoot 'bridge'
 Assert-NoReparse $source
 $hashes=Get-Content -LiteralPath (Join-Path $source 'runtime-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
 foreach($entry in $hashes.PSObject.Properties){$path=[IO.Path]::GetFullPath((Join-Path (Join-Path $source 'python') $entry.Name));$prefix=[IO.Path]::GetFullPath((Join-Path $source 'python'))+'\';if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Некорректный манифест runtime.'};Assert-NoReparse $path;if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.Value){throw 'Файл runtime повреждён: '+$entry.Name}}
 if(Get-OwnService){
  $backup=Read-NetworkBackup;$changed=$true
  Stop-Service -Name $serviceName
  foreach($file in @('NextDNSBridge.exe','bridge.py')){Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $installRoot $file) -Force}
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'connection-routes.json') -Destination (Join-Path $installRoot 'routes.json') -Force
  Copy-Item -LiteralPath (Join-Path $source 'python') -Destination $installRoot -Recurse -Force
  Set-Service -Name $serviceName -StartupType Automatic
  Start-Service -Name $serviceName
  if(Get-Service NextDNSService -ErrorAction SilentlyContinue){Stop-Service NextDNSService;Set-Service NextDNSService -StartupType Disabled}
  Disable-LegacyDriver $backup
  foreach($record in $backup.Adapters){$adapter=Get-SavedAdapter $record;Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('127.0.0.1','::1')}
  Clear-DnsClientCache;Test-InstalledDNS
  [IO.File]::WriteAllText((Join-Path $installRoot 'enabled.txt'),'1')
  Write-SetupResult 'ok' 'Подключение NextDNS Bridge восстановлено; DNS Windows и новые адреса файлов проверены.'
  exit 0
 }
 $adapters=@(Get-NetAdapter -Physical | Where-Object Status -eq Up)
 if(-not $adapters.Count){throw 'Не найден активный физический сетевой адаптер.'}
 $currentDNS=@(foreach($adapter in $adapters){Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex|ForEach-Object {$_.ServerAddresses}})
 $profiles=@(Get-DnsClientDohServerAddress | Where-Object {$_.ServerAddress -in $currentDNS -and $_.DohTemplate -match '^https://(?:[a-z0-9.-]+\.)?dns\.nextdns\.io/([a-f0-9]{6})(?:/|$)'} | ForEach-Object {[regex]::Match($_.DohTemplate,'/([a-f0-9]{6})(?:/|$)').Groups[1].Value} | Select-Object -Unique)
 if($profiles.Count -ne 1){throw 'Не удалось однозначно определить текущий профиль NextDNS.'}
 $legacy=Get-CimInstance Win32_Service -Filter "Name='NextDNSService'"
 $startup=@(foreach($key in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Run')){if(Test-Path $key){$value=[Microsoft.Win32.Registry]::GetValue($key.Replace('HKLM:','HKEY_LOCAL_MACHINE').Replace('HKCU:','HKEY_CURRENT_USER'),'NextDNS',$null);if($value -and $value -like '*\NextDNS\NextDNS.exe*'){[pscustomobject]@{Key=$key;Value=$value}}}})
 $exclusions=@()
 foreach($dir in @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Desktop')) -Directory -Filter 'zapret-discord-youtube*')){
  foreach($candidate in @($dir.FullName)+@(Get-ChildItem -LiteralPath $dir.FullName -Directory|ForEach-Object {$_.FullName})){
   foreach($file in @('list-exclude-user.txt','ipset-exclude-user.txt')){$path=Join-Path (Join-Path $candidate 'lists') $file;if(Test-Path -LiteralPath $path){Assert-NoReparse $path;$exclusions+=$path}}
  }
 }
 $backup=[ordered]@{Version=1;At=(Get-Date).ToString('o');Adapters=@(foreach($adapter in $adapters){[ordered]@{Guid=[string]$adapter.InterfaceGuid;Name=$adapter.Name;Servers=@(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex|ForEach-Object {$_.ServerAddresses})}});Legacy=$(if($legacy){@{StartMode=$legacy.StartMode;State=$legacy.State}}else{$null});Startup=$startup;ExclusionPaths=@($exclusions|Select-Object -Unique)}
 Protect-Directory $installRoot 'Program'
 Protect-Directory $dataRoot 'Data'
 Protect-Directory $backupRoot 'Backup'
 if(Test-Path -LiteralPath $backupFile){Assert-NoReparse $backupFile;[IO.File]::Move($backupFile,($backupFile+'.'+[guid]::NewGuid().ToString('N')+'.previous'))}
 $backup|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $backupFile -Encoding UTF8
 foreach($file in @('NextDNSBridge.exe','bridge.py')){Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $installRoot $file)}
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'connection-routes.json') -Destination (Join-Path $installRoot 'routes.json') -Force
 Copy-Item -LiteralPath (Join-Path $source 'python') -Destination $installRoot -Recurse
 [IO.File]::WriteAllText((Join-Path $installRoot 'profile.txt'),[string]$profiles[0],[Text.UTF8Encoding]::new($false))
 $changed=$true
 New-Service -Name $serviceName -DisplayName 'NextDNS Bridge' -BinaryPathName ('"'+$binary+'"') -StartupType Automatic -Description 'Local DNS to the current NextDNS profile over validated TLS 1.3; starts before Windows sign-in.' -Credential ([Management.Automation.PSCredential]::new('NT AUTHORITY\LocalService',[Security.SecureString]::new()))|Out-Null
 & sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Не удалось задать восстановление службы.'}
 & sc.exe failureflag $serviceName 1 | Out-Null
 $changed=$true
 Start-Service -Name $serviceName
 foreach($path in $backup.ExclusionPaths){$isIp=[IO.Path]::GetFileName($path) -eq 'ipset-exclude-user.txt';$entries=if($isIp){@('45.90.28.0/32','45.90.30.0/32')}else{@('nextdns.io')};$text=[IO.File]::ReadAllText($path);$missing=@($entries|Where-Object {$_ -notin @($text -split '\r?\n'|ForEach-Object {$_.Trim()})});if($missing.Count){$text=$text.TrimEnd()+"`r`n# BEGIN NEXTDNS BRIDGE`r`n"+($missing -join "`r`n")+"`r`n# END NEXTDNS BRIDGE`r`n";[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))}}
 if($legacy){Stop-Service -Name NextDNSService;Set-Service -Name NextDNSService -StartupType Disabled}
 Disable-LegacyDriver $backup
 foreach($entry in $startup){Remove-ItemProperty -Path $entry.Key -Name NextDNS}
 $legacyExe=Join-Path ${env:ProgramFiles(x86)} 'NextDNS\NextDNS.exe'
 Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -ieq $legacyExe -and $_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId} | ForEach-Object {Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue}
 foreach($adapter in $adapters){Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('127.0.0.1','::1')}
 Clear-DnsClientCache
 Test-InstalledDNS
 [IO.File]::WriteAllText((Join-Path $installRoot 'enabled.txt'),'1')
 Write-SetupResult 'ok' 'NextDNS восстановлен: локальная служба работает через TLS 1.3 и запускается с Windows до входа. Проверены DNS Windows, общий интернет и новые адреса файлов. Резервная копия сети сохранена.'
} catch {
 $message=$_.Exception.Message
 if($changed -and $backup){try{Restore-Network $backup;if(Get-OwnService){Set-Service -Name $serviceName -StartupType Disabled};[IO.File]::WriteAllText((Join-Path $installRoot 'enabled.txt'),'0');$message+=' Предыдущая настройка сети возвращена.'}catch{$message+=' Автоматический возврат требует проверки: '+$_.Exception.Message}}
 try{Write-SetupResult 'error' $message}catch{}
 exit 1
}
