#requires -Version 7.4
param([Parameter(Mandatory)][string]$ToolsRoot,[string]$TestRoot=(Join-Path $env:TEMP ('NC-net-ui-'+[guid]::NewGuid().ToString('N').Substring(0,8))))
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Choose a new disposable TestRoot.'}
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$root=Join-Path $TestRoot Engine
$folder=Join-Path $TestRoot Storage
$setup=Join-Path $TestRoot Setup
$app=Join-Path $TestRoot App
Import-Module (Join-Path $repo 'src/shared/NetCrate.Credentials.psm1')
Import-Module (Join-Path $repo 'src/shared/NetCrate.Configuration.psm1')
$null=New-NetCrateIdentity $root ('1'*32) Worker
Protect-NetCrateRecord $root inbound-request @{Confirmed=$false;Request=@{RequestId=('2'*32)}}
Write-NetCrateJson (Join-Path $root prepared.json) @{Role='Worker';Folder=$folder;BackupMode='Folder';InstallationId='1'*32}
$null=[IO.Directory]::CreateDirectory((Join-Path $root Tools))
Copy-Item -LiteralPath (Join-Path $ToolsRoot PowerShell) -Recurse -Destination (Join-Path $root Tools)
$null=[IO.Directory]::CreateDirectory((Join-Path $app src))
Copy-Item -LiteralPath (Join-Path $repo install) -Destination $app -Recurse
Copy-Item -LiteralPath (Join-Path $repo src/shared) -Destination (Join-Path $app src) -Recurse
$test=Join-Path $TestRoot 'NetworkSetupTests.exe'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$sources=@((Join-Path $repo tests/desktop/NetworkSetupTests.cs),(Join-Path $repo src/desktop/setup/SetupState.cs))
$sources+=@(Get-ChildItem (Join-Path $repo src/desktop/setup) -Filter 'NetworkSetup*.cs' | ForEach-Object FullName)
$manifest=& (Join-Path $repo src/desktop/Build-NetworkSetupManifest.ps1) -Repo $repo -OutputPath (Join-Path $TestRoot NetworkSetupTrust.txt)
& $compiler /nologo /r:System.Web.Extensions.dll "/resource:$manifest,NetCrate.NetworkSetupTrust" "/out:$test" @sources
if($LASTEXITCODE){throw 'Compilation failed.'}
& $test (Join-Path $app install) $setup $folder
if($LASTEXITCODE){throw 'Desktop network smoke failed.'}
