#Requires -Version 5.1
[CmdletBinding()]
param([string]$PythonExe='python.exe')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
& $PythonExe -I (Join-Path $PSScriptRoot 'test_bridge_protocol.py')
if($LASTEXITCODE -ne 0){throw 'Bridge tests failed.'}
& (Join-Path $PSScriptRoot 'Test-RepairCenter.ps1')
& (Join-Path $PSScriptRoot 'Test-ConnectionRecovery.ps1')
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($script in @('NextDNS-GUI.ps1','RepairCenter.ps1')){
 & $shell -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path (Join-Path $root '_service') $script) -SmokeTest
 if($LASTEXITCODE -ne 0){throw ('UI smoke failed: '+$script)}
}
Write-Output 'Windows client checks passed; no network settings or browser sessions changed.'
