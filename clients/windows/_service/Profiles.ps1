#Requires -Version 5.1
<#
OpenAI hosts profile manager. Check/List are read-only; Import writes this package only.
Apply/Restore require elevation. Existing managed markers remain compatible.
Never changes DNS servers, NextDNS, proxy enable/server, certificates, VPN or browser data.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','Apply','ClearCache','Restore','Import','List')][string]$Mode='Check',
    [string]$ProfileId,
    [string]$SourcePath,
    [string]$Name,
    [ValidatePattern('^$|^[A-Za-z]{2}$')][string]$CountryCode,
    [string]$Region,
    [string]$ExpectedUserSid,
    [string]$ResultPath,
    [string]$ExpectedHostsHash
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$taskRoot=$PSScriptRoot
$taskCatalogPath=Join-Path $taskRoot 'profiles.json'
$taskProfilesRoot=Join-Path $taskRoot 'profiles'
$taskHostsPath=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$taskStatePath=Join-Path $taskRoot 'ChatGPT-US-state.json'
$taskLegacyState=Join-Path ([Environment]::GetFolderPath('Desktop')) 'NextDNS\_service\ChatGPT-US-state.json'
$taskProxyKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$taskEncoding=[Text.Encoding]::GetEncoding(28591)
$taskUtf8=New-Object Text.UTF8Encoding($false)
$taskBlockPattern='(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)'
$taskResult=[ordered]@{Status='error';Message=$null;Error=$null;ProfileId=$ProfileId;Address=$null;Addresses=@();VerifiedCount=0;ExpectedCount=0;Mode=$Mode;At=(Get-Date).ToString('o');Checks=@{}}
$taskCode=0
$taskSettingsLock=$null

function Get-Value($Object,[string]$Property,$Default=$null) {
    if ($null -eq $Object) { return $Default }
    $value=$Object.PSObject.Properties[$Property]
    if ($null -eq $value) { return $Default }
    return $value.Value
}
function Get-Hash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') } finally { $sha.Dispose() }
}
function Read-Bytes([string]$Path) { return ,([IO.File]::ReadAllBytes($Path)) }
function Commit-AtomicFile([string]$Path,[byte[]]$Bytes,[string]$ExpectedHash,[bool]$ExpectedExists,[ref]$Committed) {
    $Committed.Value=$false
    $absolute=[IO.Path]::GetFullPath($Path)
    $stage=Join-Path ([IO.Path]::GetDirectoryName($absolute)) ('.'+[IO.Path]::GetFileName($absolute)+'.codex-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $stageCreated=$false
    $desiredHash=Get-Hash $Bytes
    try {
        $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stageCreated=$true
        try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ((Get-Hash (Read-Bytes $stage)) -cne $desiredHash) { throw 'Не удалось проверить временный файл перед заменой.' }
        if ($ExpectedExists) {
            if (-not (Test-Path -LiteralPath $absolute -PathType Leaf) -or (Get-Hash (Read-Bytes $absolute)) -cne $ExpectedHash) { throw ('Файл изменился после подготовки команды: '+$absolute) }
            # Same-directory ReplaceFile is atomic and retains destination metadata/ACLs.
            [IO.File]::Replace($stage,$absolute,[NullString]::Value)
        } else {
            if (Test-Path -LiteralPath $absolute) { throw ('Файл создан другим процессом: '+$absolute) }
            [IO.File]::Move($stage,$absolute)
        }
        $Committed.Value=$true
        if ((Get-Hash (Read-Bytes $absolute)) -cne $desiredHash) { throw ('Сохранённый файл изменён другим процессом: '+$absolute) }
    } catch {
        # A native replace can have an uncertain outcome. Only the expected before/after
        # hashes permit automatic rollback; every other version is left untouched.
        if (Test-Path -LiteralPath $absolute -PathType Leaf) {
            $currentHash=Get-Hash (Read-Bytes $absolute)
            if ($currentHash -ceq $desiredHash) { $Committed.Value=$true }
            elseif ($ExpectedExists -and $currentHash -ceq $ExpectedHash) { $Committed.Value=$false }
        }
        throw
    } finally {
        if ($stageCreated -and (Test-Path -LiteralPath $stage -PathType Leaf)) { Remove-Item -LiteralPath $stage -Force }
    }
}
function Write-Json([string]$Path,$Value) {
    $absolute=[IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($absolute)) | Out-Null
    [IO.File]::WriteAllText($absolute,($Value | ConvertTo-Json -Depth 16),$taskUtf8)
}
function Get-ProxyText([string]$Property) { return [string](Get-Item -LiteralPath $taskProxyKey).GetValue($Property,'') }
function Read-ProxyNames { return @((Get-ProxyText 'ProxyOverride') -split ';' | ForEach-Object {$_.Trim()} | Where-Object {$_}) }
function Assert-Administrator {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Для этой команды нужны права администратора. Запусти её через подтверждение Windows.' }
}
function Assert-Domain([string]$Domain) {
    if ($Domain.Length -gt 253 -or $Domain -cnotmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$') { throw ('Некорректное имя домена: '+$Domain) }
    if (@($Domain -split '\.' | Where-Object {$_.Length -gt 63}).Count) { throw ('Слишком длинная часть домена: '+$Domain) }
    if ($Domain -notmatch '(^|\.)(chatgpt\.com|openai\.com|oaistatic\.com|oaiusercontent\.com)$') { throw ('Профиль содержит посторонний домен: '+$Domain) }
}
function Convert-Address([string]$Text) {
    $address=$null
    if (-not [Net.IPAddress]::TryParse($Text,[ref]$address)) { throw ('Некорректный IP-адрес: '+$Text) }
    if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
    if ([Net.IPAddress]::IsLoopback($address)) { throw 'Адрес сервера не может быть loopback.' }
    $bytes=$address.GetAddressBytes()
    if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        if ($bytes[0] -in @(0,10,127) -or $bytes[0] -ge 224 -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127)) { throw ('Нужен публичный адрес сервера: '+$Text) }
    } else {
        if ($address.Equals([Net.IPAddress]::IPv6Any) -or $address.IsIPv6LinkLocal -or $address.IsIPv6Multicast -or $address.IsIPv6SiteLocal -or (($bytes[0] -band 254) -eq 252)) { throw ('Нужен публичный адрес сервера: '+$Text) }
    }
    return $address.ToString().ToLowerInvariant()
}
function Convert-HostsText([string]$Text) {
    if ($Text.Length -gt 1048576 -or $Text.IndexOf([char]0) -ge 0) { throw 'Файл адресов слишком велик или содержит недопустимые символы.' }
    $records=New-Object System.Collections.Generic.List[object]
    $seen=@{}
    foreach ($line in ($Text.TrimStart([char]0xFEFF) -split '\r?\n')) {
        $active=($line -split '#',2)[0].Trim()
        if (-not $active) { continue }
        $parts=@($active -split '\s+')
        if ($parts.Count -lt 2) { throw 'В строке профиля должны быть IP-адрес и домен.' }
        $ip=Convert-Address $parts[0]
        foreach ($rawName in ($parts | Select-Object -Skip 1)) {
            $domain=$rawName.ToLowerInvariant()
            Assert-Domain $domain
            if ($seen.ContainsKey($domain)) { throw ('Домен указан несколько раз: '+$domain) }
            $seen[$domain]=$true
            $records.Add([pscustomobject]@{Address=$ip;Name=$domain})
        }
    }
    if ($records.Count -lt 1 -or $records.Count -gt 512) { throw 'Профиль должен содержать от 1 до 512 разных доменов.' }
    return ,($records.ToArray())
}
function Get-MapSignature($Records) {
    return (@($Records | ForEach-Object {$_.Name+'='+$_.Address} | Sort-Object) -join "`n")
}
function New-ManagedBlock($Records,[string]$Id) {
    $lines=@('# BEGIN CHATGPT-US-WINDOWS',('# Profile ID: '+$Id),'# Exact OpenAI host mappings. Transport checks do not verify attachment downloads.')
    $lines+=@($Records | ForEach-Object {$_.Address+' '+$_.Name})
    $lines+='# END CHATGPT-US-WINDOWS'
    return ($lines -join "`r`n")+"`r`n"
}
function Convert-CatalogText([string]$Text) {
    $catalog=$Text.TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ((Get-Value $catalog 'Version' 0) -ne 1) { throw 'Неизвестная версия каталога профилей.' }
    $profiles=@(Get-Value $catalog 'Profiles' @())
    if (-not $profiles.Count) { throw 'Каталог профилей пуст.' }
    $ids=@{}
    foreach ($profile in $profiles) {
        $id=[string](Get-Value $profile 'id' '')
        if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $ids.ContainsKey($id)) { throw 'Некорректный или повторяющийся ID профиля.' }
        $ids[$id]=$true
        if (-not [string](Get-Value $profile 'name' '')) { throw 'У профиля отсутствует имя.' }
        if ([string](Get-Value $profile 'countryCode' '') -cnotmatch '^[A-Z]{2}$') { throw 'У профиля некорректный код страны.' }
    }
    return $catalog
}
function Read-Catalog {
    if (-not (Test-Path -LiteralPath $taskCatalogPath -PathType Leaf)) { throw 'Каталог профилей не найден.' }
    return Convert-CatalogText ([IO.File]::ReadAllText($taskCatalogPath))
}
function Resolve-ProfilePath([string]$Relative) {
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative)) { throw 'Путь профиля должен быть относительным.' }
    $resolved=[IO.Path]::GetFullPath((Join-Path $taskRoot $Relative))
    $allowed=[IO.Path]::GetFullPath($taskProfilesRoot).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine $allowed.TrimEnd('\') -or [IO.Path]::GetExtension($resolved) -ine '.hosts') { throw 'Файл профиля должен находиться непосредственно в папке profiles и иметь расширение .hosts.' }
    $directory=Get-Item -LiteralPath $taskProfilesRoot -Force
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Папка profiles не должна быть ссылкой.' }
    $item=Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.PSIsContainer) { throw 'Файл профиля не должен быть ссылкой или папкой.' }
    return $resolved
}
function Read-Profile($Catalog,[string]$Id) {
    $matches=@($Catalog.Profiles | Where-Object {$_.id -ceq $Id})
    if ($matches.Count -ne 1) { throw ('Профиль не найден: '+$Id) }
    $entry=$matches[0]
    $path=Resolve-ProfilePath ([string]$entry.hostsFile)
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Файл профиля слишком велик.' }
    $records=Convert-HostsText ([IO.File]::ReadAllText($path))
    $addresses=@($records | ForEach-Object {$_.Address} | Select-Object -Unique)
    return [pscustomobject]@{Entry=$entry;Records=$records;Addresses=$addresses;Names=@($records | ForEach-Object {$_.Name});Block=(New-ManagedBlock $records $Id)}
}
function Read-HostsText {
    $bytes=Read-Bytes $taskHostsPath
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) { throw 'Кодировка системного hosts требует ручной проверки.' }
    return $taskEncoding.GetString($bytes)
}
function Get-ManagedMatch([string]$Text) {
    $blocks=[regex]::Matches($Text,$taskBlockPattern)
    $beginCount=[regex]::Matches($Text,'(?m)^# BEGIN CHATGPT-US-WINDOWS\r?$').Count
    $endCount=[regex]::Matches($Text,'(?m)^# END CHATGPT-US-WINDOWS\r?$').Count
    if ($blocks.Count -gt 1 -or $beginCount -ne $blocks.Count -or $endCount -ne $blocks.Count) { throw 'В hosts обнаружен повреждённый или повторяющийся блок настройки.' }
    if ($blocks.Count -eq 1) { return $blocks[0] }
    return $null
}
function Assert-NoOutsideConflicts([string]$Text,$Managed,[string[]]$Names) {
    $outside=$Text
    if ($null -ne $Managed) { $outside=$Text.Remove($Managed.Index,$Managed.Length) }
    foreach ($line in ($outside -split '\r?\n')) {
        $clean=($line -split '#',2)[0].Trim()
        if (-not $clean) { continue }
        foreach ($domain in (($clean -split '\s+') | Select-Object -Skip 1)) {
            if ($Names -contains $domain) { throw ('Вне служебного блока уже есть запись '+$domain+'. Она сохранена; нужна ручная проверка.') }
        }
    }
}
function Read-State {
    $path=$taskStatePath
    $localExists=Test-Path -LiteralPath $path -PathType Leaf
    if (-not $localExists -and (Test-Path -LiteralPath $taskLegacyState -PathType Leaf)) { $path=$taskLegacyState }
    $sourceExists=Test-Path -LiteralPath $path -PathType Leaf
    $bytes=if ($sourceExists) {Read-Bytes $path} else {New-Object byte[] 0}
    $state=if ($sourceExists) {$taskUtf8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json} else {[pscustomobject]@{AddedProxyNames=@()}}
    foreach ($owned in @(Get-Value $state 'AddedProxyNames' @())) { Assert-Domain ([string]$owned) }
    $script:taskStateReadSnapshot=[pscustomobject]@{SourcePath=$path;SourceExisted=$sourceExists;Bytes=$bytes;Hash=(Get-Hash $bytes);LocalExisted=$localExists}
    return $state
}
function Find-ActiveProfile($Catalog) {
    $text=Read-HostsText
    $managed=Get-ManagedMatch $text
    if ($null -eq $managed) { return [pscustomobject]@{Enabled=$false;Source=$null;MatchedIds=@();DomainCount=0} }
    $records=Convert-HostsText $managed.Value
    $signature=Get-MapSignature $records
    $matches=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Catalog.Profiles) {
        $candidate=Read-Profile $Catalog $entry.id
        if ((Get-MapSignature $candidate.Records) -ceq $signature) { $matches.Add($candidate) }
    }
    $source=$null
    if ($matches.Count) { $source=$matches[0] }
    return [pscustomobject]@{Enabled=$true;Source=$source;MatchedIds=@($matches | ForEach-Object {$_.Entry.id});DomainCount=$records.Count}
}
function Refresh-Cache {
    Clear-DnsClientCache -ErrorAction Stop
    if (-not ('OpenAIProfilesWinInet' -as [type])) { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class OpenAIProfilesWinInet { [DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int n); }' }
    [void][OpenAIProfilesWinInet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)
    [void][OpenAIProfilesWinInet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)
    Write-Host 'Кеш DNS очищен, Windows уведомлена об обновлении списка исключений.'
}
function Test-Settings($Source) {
    $taskResult.ProfileId=$Source.Entry.id
    $taskResult.Address=$Source.Addresses -join ', '
    $taskResult.Addresses=@($Source.Addresses)
    $taskResult.ExpectedCount=$Source.Records.Count
    $text=Read-HostsText
    $managed=Get-ManagedMatch $text
    if ($null -eq $managed) { throw 'Служебный блок hosts не включён.' }
    Assert-NoOutsideConflicts $text $managed $Source.Names
    $active=Convert-HostsText $managed.Value
    $mapOk=(Get-MapSignature $active) -ceq (Get-MapSignature $Source.Records)
    $taskResult.Checks.ManagedMapMatches=$mapOk
    if (-not $mapOk) { throw 'В hosts выбран другой профиль или часть записей отличается от выбранного профиля.' }
    $bad=New-Object System.Collections.Generic.List[string]
    foreach ($record in $Source.Records) {
        try { $actual=@([Net.Dns]::GetHostAddresses($record.Name) | ForEach-Object {$_.IPAddressToString.ToLowerInvariant()} | Sort-Object -Unique) } catch { $actual=@() }
        if ($actual.Count -eq 1 -and $actual[0] -ceq $record.Address) { $taskResult.VerifiedCount++ } else { $bad.Add($record.Name+': '+($actual -join ', ')) }
    }
    $enabled=(Get-ProxyText 'ProxyEnable') -eq '1'
    $proxyNames=@(Read-ProxyNames)
    $missing=@($Source.Names | Where-Object {$_ -notin $proxyNames})
    $taskResult.Checks.ProxyEnabled=$enabled
    $taskResult.Checks.MissingProxyExclusions=$missing
    $taskResult.Checks.DnsMismatches=@($bad.ToArray())
    $taskResult.Checks.AttachmentDownloadVerified=$false
    if ($bad.Count) { throw 'Часть доменов не разрешается в адреса выбранного профиля. Обнови кеш и повтори проверку.' }
    if ($enabled -and $missing.Count) { throw 'Для части доменов отсутствуют исключения системного прокси. Примени профиль повторно.' }
    Write-Host ('Проверены hosts и DNS: '+$taskResult.VerifiedCount+' доменов. Скачивание вложений этой проверкой не проверяется.')
}
function Invoke-SettingsTransaction([string]$Before,[string]$After,[string]$ProxyAfter,$StateAfter,[scriptblock]$Validate,[string]$ExpectedProxyBefore,$ExpectedStateSnapshot) {
    # Compare against the same proxy/state snapshots that produced the proposed values.
    # A newer snapshot here would hide changes made by Happ or another manager instance.
    if ((Get-ProxyText 'ProxyOverride') -cne $ExpectedProxyBefore) { throw 'Исключения прокси изменились после подготовки команды. Повтори команду.' }
    if ($null -eq $ExpectedStateSnapshot) { throw 'Отсутствует исходное состояние профиля.' }
    if ($ExpectedStateSnapshot.SourceExisted) {
        if (-not (Test-Path -LiteralPath $ExpectedStateSnapshot.SourcePath -PathType Leaf) -or (Get-Hash (Read-Bytes $ExpectedStateSnapshot.SourcePath)) -cne $ExpectedStateSnapshot.Hash) { throw 'Состояние профиля изменилось после подготовки команды. Повтори команду.' }
    } elseif (Test-Path -LiteralPath $ExpectedStateSnapshot.SourcePath) { throw 'Состояние профиля создано другим процессом.' }
    if (-not $ExpectedStateSnapshot.LocalExisted -and (Test-Path -LiteralPath $taskStatePath)) { throw 'Локальное состояние профиля создано другим процессом.' }
    $backupDir=Join-Path (Join-Path $taskRoot 'backups') ('profile-'+(Get-Date -Format 'yyyyMMdd-HHmmss-ffff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    $taskResult.BackupDirectory=$backupDir
    $hostBefore=$taskEncoding.GetBytes($Before); $hostAfter=$taskEncoding.GetBytes($After)
    $stateExisted=$ExpectedStateSnapshot.LocalExisted
    $stateBefore=if ($stateExisted) { $ExpectedStateSnapshot.Bytes } else { New-Object byte[] 0 }
    $stateBytes=$taskUtf8.GetBytes(($StateAfter | ConvertTo-Json -Depth 10))
    $proxyBefore=$ExpectedProxyBefore
    $enableBefore=Get-ProxyText 'ProxyEnable'; $serverBefore=Get-ProxyText 'ProxyServer'
    $registry=Get-Item -LiteralPath $taskProxyKey
    $overrideExisted=@($registry.GetValueNames()) -contains 'ProxyOverride'
    $overrideKind=if ($overrideExisted) {$registry.GetValueKind('ProxyOverride')} else {[Microsoft.Win32.RegistryValueKind]::String}
    [IO.File]::WriteAllBytes((Join-Path $backupDir 'hosts.before.bak'),$hostBefore)
    if ((Get-Hash (Read-Bytes (Join-Path $backupDir 'hosts.before.bak'))) -cne (Get-Hash $hostBefore)) { throw 'Не удалось проверить резервную копию hosts.' }
    if ($stateExisted) { [IO.File]::WriteAllBytes((Join-Path $backupDir 'state.before.json'),$stateBefore) }
    Write-Json (Join-Path $backupDir 'snapshot.json') ([ordered]@{HostsBeforeSha256=(Get-Hash $hostBefore);HostsAfterSha256=(Get-Hash $hostAfter);StateExisted=$stateExisted;StateBeforeSha256=(Get-Hash $stateBefore);ProxyOverride=$proxyBefore;ProxyOverrideExisted=$overrideExisted;ProxyOverrideKind=[string]$overrideKind;ProxyEnable=$enableBefore;ProxyServerSha256=(Get-Hash ($taskUtf8.GetBytes($serverBefore)))})
    $hostsWritten=$false; $stateWritten=$false; $proxyWritten=$false
    try {
        if ((Read-HostsText) -cne $Before) { throw 'Файл hosts изменился во время выполнения.' }
        if ((Get-ProxyText 'ProxyOverride') -cne $proxyBefore) { throw 'Исключения прокси изменились во время выполнения.' }
        if ($stateExisted) { if ((Get-Hash (Read-Bytes $taskStatePath)) -cne (Get-Hash $stateBefore)) { throw 'Состояние профиля изменилось во время выполнения.' } } elseif (Test-Path -LiteralPath $taskStatePath) { throw 'Состояние профиля создано другим процессом.' }
        if ($Before -cne $After) { Commit-AtomicFile $taskHostsPath $hostAfter (Get-Hash $hostBefore) $true ([ref]$hostsWritten) }
        if ($proxyBefore -cne $ProxyAfter) { Set-ItemProperty -LiteralPath $taskProxyKey -Name ProxyOverride -Value $ProxyAfter; $proxyWritten=$true }
        Commit-AtomicFile $taskStatePath $stateBytes (Get-Hash $stateBefore) $stateExisted ([ref]$stateWritten)
        if ((Get-Hash (Read-Bytes $taskHostsPath)) -cne (Get-Hash $hostAfter) -or (Get-Hash (Read-Bytes $taskStatePath)) -cne (Get-Hash $stateBytes) -or (Get-ProxyText 'ProxyOverride') -cne $ProxyAfter) { throw 'Не удалось проверить сохранённые настройки.' }
        if ((Get-ProxyText 'ProxyEnable') -cne $enableBefore -or (Get-ProxyText 'ProxyServer') -cne $serverBefore) { throw 'Параллельно изменились параметры системного прокси.' }
        Refresh-Cache
        & $Validate
        $taskResult.Checks.ProxyEnableUnchanged=$true
        $taskResult.Checks.ProxyServerUnchanged=$true
        Write-Host ('Резервная копия: '+$backupDir)
    } catch {
        $failure=$_
        $rollback=New-Object System.Collections.Generic.List[string]
        if ($stateWritten) { try { if ((Get-Hash (Read-Bytes $taskStatePath)) -cne (Get-Hash $stateBytes)) { throw 'state: обнаружено параллельное изменение.' }; if ($stateExisted) {$rolledBack=$false; Commit-AtomicFile $taskStatePath $stateBefore (Get-Hash $stateBytes) $true ([ref]$rolledBack)} else {Remove-Item -LiteralPath $taskStatePath -Force} } catch {$rollback.Add($_.Exception.Message)} }
        if ($proxyWritten) { try { if ((Get-ProxyText 'ProxyOverride') -cne $ProxyAfter) {throw 'proxy: обнаружено параллельное изменение.'}; if ($overrideExisted) {(Get-Item -LiteralPath $taskProxyKey).SetValue('ProxyOverride',$proxyBefore,$overrideKind)} else {Remove-ItemProperty -LiteralPath $taskProxyKey -Name ProxyOverride} } catch {$rollback.Add($_.Exception.Message)} }
        if ($hostsWritten) { try { if ((Get-Hash (Read-Bytes $taskHostsPath)) -cne (Get-Hash $hostAfter)) {throw 'hosts: обнаружено параллельное изменение.'}; $rolledBack=$false; Commit-AtomicFile $taskHostsPath $hostBefore (Get-Hash $hostAfter) $true ([ref]$rolledBack) } catch {$rollback.Add($_.Exception.Message)} }
        try {Refresh-Cache} catch {$rollback.Add($_.Exception.Message)}
        $taskResult.RollbackErrors=@($rollback.ToArray())
        throw $failure
    }
}

try {
    if ($Mode -in @('Apply','ClearCache','Restore','Import')) {
        if (-not $ExpectedUserSid -or $ExpectedUserSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Команда должна выполняться от того же пользователя Windows, который открыл менеджер. Ожидаемый SID отсутствует или не совпадает.' }
    }
    if ($Mode -in @('Apply','Restore')) { Assert-Administrator }
    if ($Mode -in @('Apply','Restore')) {
        try { $taskSettingsLock=[IO.File]::Open((Join-Path $taskRoot '.profiles-settings.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { throw 'Другой процесс меняет профиль. Повтори команду после его завершения.' }
    }
    $catalog=Read-Catalog
    $state=Read-State
    if ($Mode -in @('Apply','Restore')) {
        $stateSid=[string](Get-Value $state 'UserSid' '')
        if ($stateSid -and $stateSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Состояние менеджера принадлежит другому пользователю Windows.' }
    }
    if (-not $ProfileId) { $ProfileId='primary' }
    $taskResult.ProfileId=$ProfileId
    switch ($Mode) {
        'List' {
            $active=Find-ActiveProfile $catalog
            $taskResult.Profiles=@($catalog.Profiles)
            $taskResult.ActiveProfileId=if ($null -ne $active.Source) {$active.Source.Entry.id} else {$null}
            $taskResult.ActiveMatchedProfileIds=@($active.MatchedIds)
            $taskResult.ActiveDomainCount=$active.DomainCount
            $taskResult.ManagedBlockEnabled=$active.Enabled
            $taskResult.Message='Каталог профилей загружен.'
        }
        'Import' {
            if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'Выбери существующий файл .hosts.' }
            if ([IO.Path]::GetExtension($SourcePath) -ine '.hosts' -or (Get-Item -LiteralPath $SourcePath).Length -gt 1048576) { throw 'Нужен файл .hosts размером не больше 1 МиБ.' }
            if (-not $Name -or $Name.Trim().Length -gt 120 -or $Name -match '[\x00-\x1f]') { throw 'Укажи имя профиля от 1 до 120 символов.' }
            if (-not $CountryCode) { throw 'Укажи двухбуквенный код страны или региона.' }
            $country=$CountryCode.ToUpperInvariant()
            if (-not $Region) { $Region=$country }
            if ($Region.Length -gt 80 -or $Region -match '[\x00-\x1f]') { throw 'Некорректное название региона.' }
            $records=Convert-HostsText ([IO.File]::ReadAllText([IO.Path]::GetFullPath($SourcePath)))
            $stem=($Name.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
            if (-not $stem) { $stem='profile' }
            if ($stem.Length -gt 42) { $stem=$stem.Substring(0,42).TrimEnd('-') }
            $newId=$stem+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
            $addresses=@($records | ForEach-Object {$_.Address} | Select-Object -Unique)
            $relative='profiles\'+$newId+'.hosts'
            $entry=[pscustomobject]@{id=$newId;name=$Name.Trim();region=$Region.Trim();countryCode=$country;hostsFile=$relative;address=$(if($addresses.Count -eq 1){$addresses[0]}else{$null});description='Импортирован пользователем. Проверен формат доменов и адресов; сетевой маршрут ещё не проверен.';verifiedAt=$null;domainCount=$records.Count}
            [IO.Directory]::CreateDirectory($taskProfilesRoot) | Out-Null
            $destination=Join-Path $taskRoot $relative
            if (Test-Path -LiteralPath $destination) { throw 'ID профиля уже существует; повтори импорт.' }
            $importLock=$null
            try {
                try { $importLock=[IO.File]::Open((Join-Path $taskRoot '.profiles-import.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { throw 'Другой процесс импортирует профиль. Повтори импорт после его завершения.' }
                $catalogBefore=Read-Bytes $taskCatalogPath
                # The parsed catalog and concurrency hash come from exactly the same snapshot.
                $importCatalog=Convert-CatalogText ($taskUtf8.GetString($catalogBefore))
                $newProfiles=@($importCatalog.Profiles)+@($entry)
                $newCatalog=[ordered]@{Version=1;Profiles=$newProfiles}
                $catalogBytes=$taskUtf8.GetBytes(($newCatalog | ConvertTo-Json -Depth 16))
                $profileBytes=$taskUtf8.GetBytes((New-ManagedBlock $records $newId))
                $backupDir=Join-Path (Join-Path $taskRoot 'backups') ('import-'+(Get-Date -Format 'yyyyMMdd-HHmmss-ffff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
                [IO.Directory]::CreateDirectory($backupDir) | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $backupDir 'profiles.before.json'),$catalogBefore)
                $catalogWritten=$false; $profileWritten=$false; $catalogRolledBack=$false
                try {
                    if ((Get-Hash (Read-Bytes $taskCatalogPath)) -cne (Get-Hash $catalogBefore)) { throw 'Каталог изменился во время импорта.' }
                    Commit-AtomicFile $destination $profileBytes '' $false ([ref]$profileWritten)
                    if ((Get-Hash (Read-Bytes $taskCatalogPath)) -cne (Get-Hash $catalogBefore)) { throw 'Каталог изменился во время импорта.' }
                    Commit-AtomicFile $taskCatalogPath $catalogBytes (Get-Hash $catalogBefore) $true ([ref]$catalogWritten)
                    if ((Get-Hash (Read-Bytes $taskCatalogPath)) -cne (Get-Hash $catalogBytes)) { throw 'После импорта каталог был изменён другим процессом.' }
                    $saved=Read-Profile (Convert-CatalogText ($taskUtf8.GetString($catalogBytes))) $newId
                    if ((Get-MapSignature $saved.Records) -cne (Get-MapSignature $records)) { throw 'Не удалось проверить импортированный профиль.' }
                } catch {
                    $importFailure=$_
                    # Never restore a stale snapshot over a concurrent edit, including guard failures.
                    if ($catalogWritten -and (Get-Hash (Read-Bytes $taskCatalogPath)) -ceq (Get-Hash $catalogBytes)) { Commit-AtomicFile $taskCatalogPath $catalogBefore (Get-Hash $catalogBytes) $true ([ref]$catalogRolledBack) }
                    if ($profileWritten -and (-not $catalogWritten -or $catalogRolledBack) -and (Test-Path -LiteralPath $destination -PathType Leaf) -and (Get-Hash (Read-Bytes $destination)) -ceq (Get-Hash $profileBytes)) { Remove-Item -LiteralPath $destination -Force }
                    throw $importFailure
                }
            } finally {
                if ($null -ne $importLock) { $importLock.Dispose() }
            }
            $taskResult.ProfileId=$newId; $taskResult.AddedProfile=$entry; $taskResult.Address=$addresses -join ', '; $taskResult.Addresses=$addresses; $taskResult.ExpectedCount=$records.Count
            $taskResult.Checks.SystemSettingsChanged=$false
            $taskResult.Message='Профиль добавлен в каталог. Для включения выбери его и нажми «Применить».'
            Write-Host $taskResult.Message
        }
        'Restore' {
            $before=Read-HostsText; $managed=Get-ManagedMatch $before
            $after=if ($null -ne $managed) {$before.Remove($managed.Index,$managed.Length)} else {$before}
            $owned=@(Get-Value $state 'AddedProxyNames' @())
            $oldProxy=Get-ProxyText 'ProxyOverride'
            $proxyAfter=@(($oldProxy -split ';' | ForEach-Object {$_.Trim()} | Where-Object {$_}) | Where-Object {$_ -notin $owned}) -join ';'
            $newState=[ordered]@{Version=2;Active=$false;ProfileId=$null;AddedProxyNames=@();UpdatedAt=(Get-Date).ToString('o');UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
            Invoke-SettingsTransaction $before $after $proxyAfter $newState { if ($null -ne (Get-ManagedMatch (Read-HostsText))) {throw 'Не удалось убрать служебный блок hosts.'} } $oldProxy $taskStateReadSnapshot
            $taskResult.ProfileId=$null; $taskResult.Message='Служебный блок hosts и добавленные менеджером исключения прокси отключены.'
        }
        default {
            if ($Mode -in @('Check','ClearCache')) {
                $requested=$ProfileId
                $active=Find-ActiveProfile $catalog
                $taskResult.Checks.ManagedBlockEnabled=$active.Enabled
                $taskResult.Checks.ActiveMatchedProfileIds=@($active.MatchedIds)
                $taskResult.ExpectedCount=$active.DomainCount
                if (-not $active.Enabled) { $taskResult.ProfileId=$null; throw 'Служебный блок hosts не включён.' }
                if ($null -eq $active.Source) { $taskResult.ProfileId=$null; throw 'Активные записи hosts не совпадают ни с одним профилем каталога.' }
                $source=$active.Source
                $taskResult.Checks.RequestedProfileId=$requested
                $taskResult.Checks.RequestedProfileIsActive=$active.MatchedIds -contains $requested
            } else { $source=Read-Profile $catalog $ProfileId }
            if ($Mode -eq 'Apply') {
                $before=Read-HostsText; $managed=Get-ManagedMatch $before
                if($ExpectedHostsHash -and (Get-Hash (Read-Bytes $taskHostsPath)) -cne $ExpectedHostsHash) { throw 'Hosts изменился после просмотра изменений. Повторите проверку в окне помощи.' }
                Assert-NoOutsideConflicts $before $managed $source.Names
                $after=if ($null -ne $managed) {$before.Substring(0,$managed.Index)+$source.Block+$before.Substring($managed.Index+$managed.Length)} else {$before+$(if($before.EndsWith("`n")){''}else{"`r`n"})+$source.Block}
                $oldProxy=Get-ProxyText 'ProxyOverride'; $oldNames=@($oldProxy -split ';' | ForEach-Object {$_.Trim()} | Where-Object {$_})
                $added=@($source.Names | Where-Object {$_ -notin $oldNames})
                $proxyAfter=$oldProxy
                if ($added.Count) { $proxyAfter=$oldProxy.TrimEnd(';')+$(if($oldProxy.TrimEnd(';')){';'}else{''})+($added -join ';') }
                $owned=@((@(Get-Value $state 'AddedProxyNames' @())+@($added)) | Select-Object -Unique)
                $newState=[ordered]@{Version=2;Active=$true;ProfileId=$ProfileId;Variant=$(if($ProfileId -in @('primary','alternate')){(Get-Culture).TextInfo.ToTitleCase($ProfileId)}else{'Custom'});Address=$(if($source.Addresses.Count -eq 1){$source.Addresses[0]}else{$null});Addresses=@($source.Addresses);DomainCount=$source.Records.Count;AddedProxyNames=$owned;UpdatedAt=(Get-Date).ToString('o');UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
                Invoke-SettingsTransaction $before $after $proxyAfter $newState {Test-Settings $source} $oldProxy $taskStateReadSnapshot
                $taskResult.Message='Профиль применён. Hosts и DNS проверены. Открытие вложения проверь в ChatGPT.'
            } elseif ($Mode -eq 'ClearCache') { Refresh-Cache; Test-Settings $source; $taskResult.Message='Кеш DNS обновлён. Активен профиль «'+$source.Entry.name+'».' }
            else { Test-Settings $source; $taskResult.Message='Активный профиль «'+$source.Entry.name+'»: hosts и DNS проверены.' }
        }
    }
    $taskResult.Status='ok'
} catch {
    $taskCode=1; $taskResult.Error=$_.Exception.Message; $taskResult.Message='Команда не завершена: '+$taskResult.Error
    Write-Host $taskResult.Message -ForegroundColor Red
} finally {
    if ($null -ne $taskSettingsLock) { $taskSettingsLock.Dispose() }
}
$taskResult.At=(Get-Date).ToString('o')
if ($ResultPath) { Write-Json $ResultPath $taskResult }
Write-Output ($taskResult | ConvertTo-Json -Depth 16)
exit $taskCode
