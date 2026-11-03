#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach($name in @('Configuration','Credentials')){Import-Module "$repo/src/shared/NetCrate.$name.psm1"}
$root=Assert-NetCrateLocalPath $TestRoot
if(Test-Path -LiteralPath $root){throw 'Use a fresh fixture root.'}
if($root -match '(?i)OneDrive' -or $root -notmatch '(?i)[\\/](temp|_temp)[\\/]'){throw 'Use an ordinary Temp fixture.'}
$null=Set-NetCratePrivateDirectory $root
$setup=Join-Path $root 'Setup';$storage=Join-Path $root 'Storage'
$null=[IO.Directory]::CreateDirectory($setup);$null=[IO.Directory]::CreateDirectory($storage)
$inputFile=Join-Path $setup ('action-'+[guid]::NewGuid().ToString('N')+'.json')
$state=@{Version=1;InstallationId=[guid]::NewGuid().ToString('N');Role='BackupServer';BackupMode='Folder';Folder=$storage}
$script:actionScript="$repo/install/Invoke-SetupAction.ps1"
function Invoke-Action([string]$Action){
 Write-NetCrateJson $inputFile $state
 $text=& "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:actionScript -Action $Action -InputFile $inputFile 2>&1
 try{return ($text -join "`n")|ConvertFrom-Json}catch{throw ('The '+$Action+' action did not return its bounded setup result before bootstrap.')}
}
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++}
$script:count=0
$review=Invoke-Action ReviewSoftware
Check ($review.Succeeded -and $review.PreparationPlan.Packages.Count -eq 6) 'Server software review did not show bootstrap and exact Folder tools.'
Check (-not [IO.Directory]::Exists((Join-Path $setup 'Bootstrap'))) 'Software review acquired bootstrap software.'
Check (-not [IO.Directory]::Exists((Join-Path $root 'Engine'))) 'Software review created an installation.'
foreach($action in @('Prepare','Network','InstallRecoveryTools')) {
 $denied=Invoke-Action $action
 Check (-not $denied.Succeeded -and $denied.Code -ceq 'approval-needed') ($action+' accepted missing software approval.')
 Check (-not [IO.Directory]::Exists((Join-Path $setup 'Bootstrap'))) ($action+' acquired tools without approval.')
}
$state.AcceptedPlanId=$review.PreparationPlan.PlanId
$state.BackupMode='Media'
$denied=Invoke-Action Prepare
Check (-not $denied.Succeeded -and $denied.Code -ceq 'approval-needed') 'Changed software choices retained old approval.'
Check (-not [IO.Directory]::Exists((Join-Path $setup 'Bootstrap'))) 'Stale approval acquired bootstrap software.'
$state.Remove('AcceptedPlanId');$state.BackupMode='Folder'
$recovery=Invoke-Action ReviewRecoveryTools
Check ($recovery.Succeeded -and $recovery.PreparationPlan.Packages.Count -eq 2) 'Independent recovery review did not show only PowerShell and Restic.'
Check (-not [IO.Directory]::Exists((Join-Path $setup 'Bootstrap'))) 'Recovery review downloaded software.'
$state.AcceptedPlanId=$review.PreparationPlan.PlanId
$denied=Invoke-Action InstallRecoveryTools
Check (-not $denied.Succeeded -and $denied.Code -ceq 'approval-needed') 'Setup approval was accepted for a different recovery plan.'
$network=Invoke-Action ReviewNetwork
Check ($network.Succeeded -and $network.NetworkPlanId -cmatch '^[a-f0-9]{64}$') 'Network software review is unavailable before bootstrap.'
Check (-not [IO.Directory]::Exists((Join-Path $root 'Engine'))) 'Read-only reviews created engine state.'
$packageRoot=Join-Path $root 'Package'
$null=[IO.Directory]::CreateDirectory((Join-Path $packageRoot 'install'));$null=[IO.Directory]::CreateDirectory((Join-Path $packageRoot 'src/shared'))
foreach($file in @('Invoke-SetupAction.ps1','NetCrate.SoftwarePlan.psm1','NetCrate.Dependencies.psm1','NetCrate.NetworkPlan.psm1','NetCrate.Version.psm1','dependencies.json')){[IO.File]::Copy((Join-Path $repo "install/$file"),(Join-Path $packageRoot "install/$file"))}
[IO.File]::Copy((Join-Path $repo 'src/shared/NetCrate.Configuration.psm1'),(Join-Path $packageRoot 'src/shared/NetCrate.Configuration.psm1'))
[IO.File]::WriteAllText((Join-Path $packageRoot 'VERSION'),'0.2.0')
$script:actionScript=Join-Path $packageRoot 'install/Invoke-SetupAction.ps1'
$application=Join-Path $root 'Engine/App';$null=[IO.Directory]::CreateDirectory($application)
[IO.File]::WriteAllText((Join-Path $application 'VERSION'),'0.1.3')
$upgrade=Invoke-Action ReviewSoftware
Check ($upgrade.PreparationPlan.ApplicationVersion -ceq '0.2.0' -and $upgrade.PreparationPlan.ApplicationUpdateNeeded) 'Software review concealed a required application update.'
[IO.File]::WriteAllText((Join-Path $application 'VERSION'),'0.2.0')
$same=Invoke-Action ReviewSoftware
Check (-not $same.PreparationPlan.ApplicationUpdateNeeded) 'Matching installed application was reported stale.'
[IO.File]::WriteAllText((Join-Path $packageRoot 'VERSION'),'0.2.1')
$changed=Invoke-Action ReviewSoftware
Check ($changed.PreparationPlan.PlanId -cne $same.PreparationPlan.PlanId) 'Application version changes retained old approval.'
$state.AcceptedPlanId=$same.PreparationPlan.PlanId
$denied=Invoke-Action Prepare
Check (-not $denied.Succeeded -and $denied.Code -ceq 'approval-needed') 'An older application review authorized a changed application.'
Write-Output ('PASS: '+$script:count+' actual PS5 bootstrap consent assertions; no software acquired.')
