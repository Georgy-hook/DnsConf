#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RepairFunctions.ps1')
$result=$null
$inputPath=$null
$importPath=$null
try {
    $runRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'run-results'))+'\'
    $requestFull=[IO.Path]::GetFullPath($RequestPath)
    if(-not $requestFull.StartsWith($runRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Недопустимый путь запроса.'}
    if(((Get-Item -LiteralPath $runRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Папка результатов не должна быть ссылкой.'}
    $request=Get-Content -LiteralPath $requestFull -Raw -Encoding UTF8|ConvertFrom-Json
    $result=[IO.Path]::GetFullPath([string]$request.ResultPath)
    if(-not $result.StartsWith($runRoot,[StringComparison]::OrdinalIgnoreCase)){ $result=$null;throw 'Недопустимый путь отчёта.' }
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($request.ExpectedUserSid -cne $sid){throw 'Подтвердите UAC от того же пользователя Windows.'}
    $principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Нужны права администратора Windows.'}
    $domains=@($request.Domains | ForEach-Object {Convert-RepairHost ([string]$_)} | Sort-Object -Unique)
    if($domains.Count -lt 1 -or $domains.Count -gt 64){throw 'Нет проверенного списка изменений.'}
    $plan=Get-RepairPlan ($domains -join "`n")
    if($plan.HostsHash -cne $request.HostsHash -or $plan.RouteAddress -cne $request.RouteAddress){throw 'Профиль изменился после просмотра. Нажмите «Найти адреса» ещё раз.'}
    # Only the exact domains approved in the dialog; newly observed cache entries are not applied.
    foreach($domain in $domains){if($plan.Map.Contains($domain)){throw 'Адрес уже добавлен. Повторите проверку.'};$plan.Map[$domain]=$plan.RouteAddress}
    $base=Join-Path $runRoot ('repair-'+[guid]::NewGuid().ToString('N'))
    $inputPath=$base+'.hosts'
    [IO.File]::WriteAllLines($inputPath,@($plan.Map.Keys|ForEach-Object {$plan.Map[$_]+' '+$_}),[Text.UTF8Encoding]::new($false))
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $backend=Join-Path $PSScriptRoot 'Profiles.ps1'
    $importPath=$base+'.import.json'
    & $shell -NoProfile -ExecutionPolicy Bypass -File $backend -Mode Import -SourcePath $inputPath -Name ('Вложения '+(Get-Date -Format 'dd.MM HH:mm:ss')) -CountryCode EU -Region 'Восстановление вложений' -ExpectedUserSid $sid -ResultPath $importPath | Out-Null
    $import=Get-Content -LiteralPath $importPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($import.Status -ne 'ok'){throw $import.Error}
    & $shell -NoProfile -ExecutionPolicy Bypass -File $backend -Mode Apply -ProfileId $import.ProfileId -ExpectedUserSid $sid -ExpectedHostsHash $request.HostsHash -ResultPath $result | Out-Null
    $applied=Get-Content -LiteralPath $result -Raw -Encoding UTF8|ConvertFrom-Json
    if($applied.Status -eq 'ok') {
        $applied.Message='Адреса добавлены; hosts и DNS проверены. Старый профиль сохранён для возврата. Откройте вложение заново; его загрузка ещё не подтверждена.'
        $applied|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $result -Encoding UTF8
    }
} catch {
    if($result){[ordered]@{Status='error';Message=$_.Exception.Message;Error=$_.Exception.Message;At=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $result -Encoding UTF8}
    $failed=$true
} finally {
    foreach($temporary in @($inputPath,$importPath)) {if($temporary -and (Test-Path -LiteralPath $temporary)){Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue}}
}
if($failed){exit 1}
