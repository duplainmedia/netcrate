param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$PowerShellExe,[Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& "$PSScriptRoot/Test-RecoveryTransfer.ps1" -TestRoot $TestRoot -ResticExe $ResticExe
Import-Module "$repo/src/shared/NetCrate.Process.psm1"
$binding=Get-Content "$TestRoot/Engine/repositories.json" -Raw|ConvertFrom-Json
$secret=Get-NetCrateRepositorySecrets "$TestRoot/Engine"
$project=Join-Path $TestRoot Project;$null=[IO.Directory]::CreateDirectory($project)
$null=[IO.Directory]::CreateDirectory((Join-Path $TestRoot Recovered))
[IO.File]::WriteAllText((Join-Path $project original.txt),'recover my bytes')
$native=Invoke-NetCrateProcess $ResticExe @('--repo',$binding.PrimaryPath,'--no-cache','backup','--host','OLD-SOURCE','--tag','netcrate-folder-originals','--',$project) @{RESTIC_PASSWORD=$secret.PrimaryPassword}
if($native.ExitCode){throw 'Fixture native backup failed.'}
$framework=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$sources=@("$repo/src/desktop/setup/SetupState.cs","$repo/src/desktop/setup/InspectionProcess.cs","$repo/src/desktop/RestoreView.cs")+@(Get-ChildItem "$repo/src/desktop/setup/RecoveryTransfer*.cs"|Select-Object -ExpandProperty FullName)+@("$repo/tests/desktop/RecoveryTransferTests.cs")
$sources=@($sources|ForEach-Object {[IO.Path]::GetFullPath($_)})
$exe=Join-Path $TestRoot RecoveryTransferTests.exe
& "$framework/csc.exe" /nologo /target:exe /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll "/r:$framework/WPF/WindowsBase.dll" "/r:$framework/WPF/PresentationFramework.dll" "/r:$framework/WPF/PresentationCore.dll" "/r:$framework/System.Xaml.dll" "/out:$exe" @sources
if($LASTEXITCODE){throw 'Recovery desktop test compilation failed.'}
& $exe "$repo/install" $PowerShellExe $ResticExe $TestRoot
if($LASTEXITCODE){throw 'Recovery desktop tests failed.'}
