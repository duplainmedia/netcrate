param([Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$ToolArchives)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$repo/install/NetCrate.Dependencies.psm1"
$cache=[IO.Path]::Combine($FixtureRoot,'Bridge','Setup','Bootstrap','Downloads')
$null=[IO.Directory]::CreateDirectory($cache)
foreach($package in (Get-NetCrateDependencyCatalog).Packages|Where-Object Name -CIn @('PowerShell','Restic')) {
 $source=[IO.Path]::Combine($ToolArchives,$package.SHA256+'.package');$target=[IO.Path]::Combine($cache,$package.SHA256+'.package')
 if(-not [IO.File]::Exists($target)){[IO.File]::Copy($source,$target,$false)}
}
$compiler="$env:WINDIR/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
$exe=[IO.Path]::Combine($FixtureRoot,'RestoreBridgeTests.exe')
$sources=@('src/desktop/setup/SetupState.cs','src/desktop/setup/ISetupService.cs','src/desktop/setup/JsonSetupStore.cs','src/desktop/setup/InspectionProcess.cs','src/desktop/setup/WindowsSetupService.cs','tests/desktop/RestoreBridgeTests.cs')|ForEach-Object {[IO.Path]::Combine($repo,$_.Replace('/','\'))}
& $compiler /nologo /codepage:65001 /target:exe /r:System.Web.Extensions.dll "/out:$exe" @sources
if($LASTEXITCODE){throw 'Native bridge fixture compilation failed.'}
& $exe $FixtureRoot ([IO.Path]::Combine($repo,'install'))
if($LASTEXITCODE){throw 'Native bridge fixture failed.'}
