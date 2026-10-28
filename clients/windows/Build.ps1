#Requires -Version 5.1
[CmdletBinding()]
param([string]$PythonExe='python.exe',[ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$Version='2026.10.28-preview')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Build with Windows PowerShell 5.1.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$clientRoot=[IO.Path]::GetFullPath($PSScriptRoot)
$buildRoot=Join-Path $clientRoot '.build'
$stage=[IO.Path]::GetFullPath((Join-Path $buildRoot ('package-'+[guid]::NewGuid().ToString('N'))))
if(-not $stage.StartsWith(($buildRoot+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid staging path.'}
$temporary=Join-Path $buildRoot ([IO.Path]::GetFileName($stage)+'.zip')
$package=Join-Path $stage 'NextDNS'
$service=Join-Path $package '_service'
$source=Join-Path $clientRoot '_service'
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
 [IO.Directory]::CreateDirectory($service)|Out-Null
 $files=Get-Content -LiteralPath (Join-Path $clientRoot 'package-files.json') -Raw -Encoding UTF8|ConvertFrom-Json
 foreach($relative in $files){
  $path=[IO.Path]::GetFullPath((Join-Path $source $relative))
  if(-not $path.StartsWith(($source+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid package source.'}
  $target=Join-Path $service $relative
  [IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null
  Copy-Item -LiteralPath $path -Destination $target
 }
 foreach($name in @('Начать здесь.txt','Совместимость с Discord Fix.txt')){Copy-Item -LiteralPath (Join-Path $clientRoot $name) -Destination (Join-Path $package $name)}
 & $PythonExe -I (Join-Path $clientRoot 'tools\prepare_runtime.py') --destination (Join-Path $service 'bridge\python')
 if($LASTEXITCODE -ne 0){throw 'Python runtime packaging failed.'}
 & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $service 'Build-Launcher.ps1')
 if($LASTEXITCODE -ne 0){throw 'Launcher build failed.'}
 & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $service 'bridge\Build.ps1')
 if($LASTEXITCODE -ne 0){throw 'Service build failed.'}
 $output=Join-Path $clientRoot 'dist'
 [IO.Directory]::CreateDirectory($output)|Out-Null
 $archive=Join-Path $output ('NextDNS-Windows-'+$Version+'.zip')
 [IO.Compression.ZipFile]::CreateFromDirectory($stage,$temporary,[IO.Compression.CompressionLevel]::Optimal,$false)
 & $PythonExe -I (Join-Path $clientRoot 'tests\verify_package.py') $temporary
 if($LASTEXITCODE -ne 0){throw 'Package validation failed.'}
 Move-Item -LiteralPath $temporary -Destination $archive -Force
 $hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
 [IO.File]::WriteAllText(($archive+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($archive)+"`n"),[Text.Encoding]::ASCII)
 Write-Output ('Built '+$archive)
} finally {
 # Delete only this newly generated workspace staging directory.
 $resolved=[IO.Path]::GetFullPath($stage)
 if(-not $resolved.StartsWith(($buildRoot+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^package-[a-f0-9]{32}$'){throw 'Refusing to remove an unexpected staging directory.'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
 if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
}
