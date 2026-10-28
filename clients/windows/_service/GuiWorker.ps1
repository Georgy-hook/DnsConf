#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
try {
    $taskRequest = [IO.File]::ReadAllText($RequestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $taskParameters = @{Mode=[string]$taskRequest.Mode;ResultPath=[string]$taskRequest.ResultPath}
    $taskBackend = 'Profiles.ps1'
    if ($taskRequest.Engine -eq 'Health') {
        $taskBackend = 'Health.ps1'
        if ($taskRequest.Mode -eq 'ClearLogs') { $taskParameters.Scope = 'Historical'; $taskParameters.PreservePaths = [string[]]@($taskRequest.PreservePaths) }
    }
    else { $taskParameters.ProfileId=[string]$taskRequest.ProfileId; $taskParameters.ExpectedUserSid=[string]$taskRequest.ExpectedUserSid }
    if ($taskRequest.Engine -ne 'Health' -and $taskRequest.Mode -eq 'Import') {
        $taskParameters.SourcePath = [string]$taskRequest.SourcePath
        $taskParameters.Name = [string]$taskRequest.Name
        $taskParameters.CountryCode = [string]$taskRequest.CountryCode
        $taskParameters.Region = [string]$taskRequest.Region
    }
    & (Join-Path $taskRoot $taskBackend) @taskParameters *>&1 |
        ForEach-Object {
            $taskOutput = [string]$_
            $taskStructuredResult = $false
            if ($_ -is [string] -and $taskOutput.TrimStart().StartsWith('{')) {
                try {
                    $taskParsedOutput = $taskOutput | ConvertFrom-Json
                    $taskStructuredResult = $taskParsedOutput.Status -in @('ok','error')
                    if ($taskStructuredResult -and $taskParsedOutput.Status -eq 'error' -and $taskParsedOutput.Error) { ('Ошибка: ' + $taskParsedOutput.Error) | Add-Content -LiteralPath $taskRequest.LogPath -Encoding UTF8 }
                } catch { }
            }
            if (-not $taskStructuredResult) { $taskOutput | Add-Content -LiteralPath $taskRequest.LogPath -Encoding UTF8 }
        }
}
catch {
    $taskError = $_.Exception.Message
    if ($taskRequest) {
        ('Ошибка: ' + $taskError) | Add-Content -LiteralPath $taskRequest.LogPath -Encoding UTF8
        if (-not (Test-Path -LiteralPath $taskRequest.ResultPath)) {
            [pscustomobject]@{Status='error';Error=$taskError;Mode=$taskRequest.Mode;At=(Get-Date).ToString('o')} |
                ConvertTo-Json | Set-Content -LiteralPath $taskRequest.ResultPath -Encoding UTF8
        }
    }
    exit 1
}
