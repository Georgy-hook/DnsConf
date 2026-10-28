#Requires -Version 5.1
$ErrorActionPreference='Stop'
$compiler=[CodeDom.Compiler.CompilerParameters]::new()
$compiler.CompilerOptions='/target:exe /optimize+ /platform:x64'
$compiler.OutputAssembly=Join-Path $PSScriptRoot 'NextDNSBridge.exe'
$compiler.GenerateExecutable=$true;$compiler.GenerateInMemory=$false
$compiler.ReferencedAssemblies.AddRange(@('System.dll','System.Core.dll','System.ServiceProcess.dll'))
if(Test-Path -LiteralPath $compiler.OutputAssembly){Remove-Item -LiteralPath $compiler.OutputAssembly -Force}
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NextDNSBridge.cs'))) -Language CSharp -CompilerParameters $compiler
Write-Output ('Built '+$compiler.OutputAssembly)
