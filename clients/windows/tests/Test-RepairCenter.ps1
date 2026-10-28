$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\_service\RepairFunctions.ps1')
$count=0
function Assert-Repair($Condition,[string]$Label){if(-not $Condition){throw $Label};$script:count++}
$fixture="# BEGIN CHATGPT-US-WINDOWS`n192.255.159.241 chatgpt.com`n45.13.237.213 sdmntprwestus.oaiusercontent.com`n# END CHATGPT-US-WINDOWS`n"
$bytes=[Text.Encoding]::UTF8.GetBytes($fixture)
$plan=New-RepairPlan $fixture $bytes @('sdmntpreastus2.oaiusercontent.com','bank.example','sdmntprwestus.oaiusercontent.com') ''
Assert-Repair ($plan.Domains.Count -eq 1 -and $plan.Domains[0] -eq 'sdmntpreastus2.oaiusercontent.com') 'Only missing regional hosts'
Assert-Repair ($plan.Map.Count -eq 2) 'Planning must not mutate input map'
Assert-Repair ($plan.RouteAddress -eq '45.13.237.213') 'Use active regional route'
$url='https://sdmntpreastus2.oaiusercontent.com/private/path?sig=TEST_SECRET&token=hidden'
Assert-Repair ((Convert-RepairHost $url) -eq 'sdmntpreastus2.oaiusercontent.com') 'Discard secret URL parts'
$plan2=New-RepairPlan $fixture $bytes @('sdmntpreastus2.oaiusercontent.com') $url
Assert-Repair ($plan2.Domains.Count -eq 1 -and ($plan2|ConvertTo-Json -Depth 5) -notmatch 'TEST_SECRET|private/path') 'Deduplicate and avoid URL retention'
foreach($bad in @('sdmntpreastus2.oaiusercontent.com.attacker.test','evil.test','127.0.0.1','sdmntpr*.oaiusercontent.com','https://user:pass@sdmntpreastus2.oaiusercontent.com','https://evil.test/sdmntpreastus2.oaiusercontent.com')) {
    $rejected=$false;try {Convert-RepairHost $bad|Out-Null} catch {$rejected=$true}
    Assert-Repair $rejected ('Reject '+$bad)
}
$rejected=$false;try {New-RepairPlan ($fixture+$fixture) $bytes @() ''|Out-Null} catch {$rejected=$true}
Assert-Repair $rejected 'Reject duplicate managed blocks'
$rejected=$false;try {New-RepairPlan ($fixture.Replace('45.13.237.213','127.0.0.1')) $bytes @() ''|Out-Null} catch {$rejected=$true}
Assert-Repair $rejected 'Reject unsupported route'
$rejected=$false;try {New-RepairPlan $fixture $bytes @() ((1..65|ForEach-Object {'sdmntprtest'+$_+'.oaiusercontent.com'}) -join ' ')|Out-Null} catch {$rejected=$true}
Assert-Repair $rejected 'Bound candidate count'
$changed=[Text.Encoding]::UTF8.GetBytes($fixture+'# changed')
Assert-Repair ((Get-RepairHash $changed) -cne $plan.HostsHash) 'Detect changed hosts'
$empty=New-RepairPlan $fixture $bytes @('sdmntprwestus.oaiusercontent.com') ''
Assert-Repair ($empty.Domains.Count -eq 0) 'No-change state'
Write-Output ('Passed '+$count+' repair planning checks; no system settings changed.')
