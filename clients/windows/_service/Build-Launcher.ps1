#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Bin)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'Собирайте launcher через системный Windows PowerShell 5.1.' }
$taskService = $PSScriptRoot
$taskOutputDirectory = if($Bin){Join-Path $taskService 'bin'}else{Split-Path $taskService -Parent}
New-Item -ItemType Directory -Path $taskOutputDirectory -Force | Out-Null
$taskOutput = Join-Path $taskOutputDirectory 'NextDNS.exe'
$taskCompiler = [CodeDom.Compiler.CompilerParameters]::new()
$taskCompiler.CompilerOptions = '/target:winexe /optimize+ /platform:x64 /win32icon:"' + (Join-Path $taskService 'assets\app.ico') + '" /win32manifest:"' + (Join-Path $taskService 'NextDNS.manifest') + '"'
$taskCompiler.GenerateExecutable = $true
$taskCompiler.GenerateInMemory = $false
$taskCompiler.OutputAssembly = $taskOutput
$taskReferences = @([Management.Automation.PSObject].Assembly.Location,'System.dll','System.Core.dll','System.Windows.Forms.dll')
$taskCompiler.ReferencedAssemblies.AddRange($taskReferences)
if (Test-Path -LiteralPath $taskOutput) { Remove-Item -LiteralPath $taskOutput -Force }
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $taskService 'NextDNS.Launcher.cs'))) -Language CSharp -CompilerParameters $taskCompiler
Copy-Item -LiteralPath (Join-Path $taskService 'NextDNS.runtime.config') -Destination ($taskOutput + '.config') -Force
Write-Output ('Built ' + $taskOutput)
