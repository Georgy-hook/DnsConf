#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $root 'Connection.ps1')
. (Join-Path $root 'BrowserRecovery.ps1')
$script:passed=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message};$script:passed++}
$all=@(1..4 | ForEach-Object {[pscustomobject]@{State='ready'}})
Assert ((New-ConnectionReport $all).State -eq 'ready') 'Full DNS match'
Assert (-not (New-ConnectionReport $all).AttachmentsVerified) 'DNS is not attachment evidence'
Assert ((New-ConnectionReport @()).State -eq 'unavailable') 'Empty probe must not be green'
Assert ((New-ConnectionReport $all[0..2]).State -eq 'unavailable') 'Partial probe must not be green'
$all[2].State='unavailable'
Assert ((New-ConnectionReport $all).State -eq 'unavailable') 'Timeout must not be green'
$all[1].State='mismatch'
Assert ((New-ConnectionReport $all).State -eq 'mismatch') 'Changed route must be visible'

# Replace external boundaries; no real browser is closed or started by this test.
$script:fake=@();$script:closed=0;$script:starts=@();$script:command='chrome.exe --profile-directory="Profile 1"';$script:binary='C:\test\chrome.exe'
function Get-RecoveryChromeProcesses {return $script:fake}
function Get-ManagerChrome {return 'C:\test\chrome.exe'}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{CommandLine=$script:command;ExecutablePath=$script:binary}}
function Start-Process {param($FilePath,$ArgumentList) $script:starts+=@{File=$FilePath;Args=$ArgumentList}}
function MustThrow([scriptblock]$Action,[string]$Hint) {$caught=$false;try{& $Action}catch{$caught=$_.Exception.Message -like ('*'+$Hint+'*')};Assert $caught $Hint}
MustThrow {Start-BrowserRecovery} 'уже закрыт'
$proc=[pscustomobject]@{Id=1;MainWindowHandle=[IntPtr]101}
$proc|Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value {$script:closed++;return $false}
$script:fake=@($proc);$script:command='chrome.exe --user-data-dir="C:\isolated"'
MustThrow {Start-BrowserRecovery} 'отдельной папкой'
Assert ($script:closed -eq 0) 'Custom profile is untouched'
$script:binary='C:\other\chrome.exe'
MustThrow {Start-BrowserRecovery} 'другой папки'
Assert ($script:closed -eq 0) 'Other browser installation is untouched'
$script:binary='C:\test\chrome.exe'
$script:command='chrome.exe --profile-directory="Profile 1"'
$run=Start-BrowserRecovery
Assert ($script:closed -eq 1) 'Normal close requested once'
Assert ($run.Profiles[0] -eq 'Profile 1') 'Explicit profile preserved'
$result=Update-BrowserRecovery $run
Assert (-not $result.Done -and $script:closed -eq 1) 'Do not repeatedly close a confirmation window'
$run.At=(Get-Date).AddSeconds(-30)
$result=Update-BrowserRecovery $run
Assert ($result.Done -and -not $result.Success -and $script:starts.Count -eq 0) 'Blocked close never reports success or starts another session'
$script:fake=@();$run.At=Get-Date
$result=Update-BrowserRecovery $run
Assert (-not $result.Done -and $script:starts.Count -eq 1 -and $script:starts[0].Args -contains '--restore-last-session') 'Open only after complete exit'
Assert ($script:starts[0].Args -contains '--profile-directory="Profile 1"') 'Restore requested profile'
$script:fake=@($proc)
$result=Update-BrowserRecovery $run
Assert ($result.Done -and $result.Success) 'Report observed new window'
Assert ($result.Message -like '*GIF ещё не проверено*') 'Restart is not GIF verification'
$script:fake=@();$run.At=(Get-Date).AddSeconds(-20)
$result=Update-BrowserRecovery $run
Assert ($result.Done -and -not $result.Success) 'Missing new window is not success'
Write-Output ('Passed '+$script:passed+' connection/recovery checks; no browser or system settings changed.')
