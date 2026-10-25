param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\src\shared\NetCrate.Credentials.psm1" -Force
Import-Module "$PSScriptRoot\..\..\install\NetCrate.Repositories.psm1" -Force
$engine=Join-Path $TestRoot 'Engine';$storage=Join-Path $TestRoot 'Storage'
New-Item -ItemType Directory -Path $storage -Force | Out-Null
$null=New-NetCrateIdentity $engine ('9'*32) Worker
$first=Initialize-NetCrateRepositories -Root $engine -StorageRoot $storage -ResticExe $ResticExe
if($first.PrimaryId -cnotmatch '^[a-f0-9]{64}$' -or $first.ResultsId -cnotmatch '^[a-f0-9]{64}$' -or $first.PrimaryId -ceq $first.ResultsId){throw 'Separate repositories were not initialized.'}
$retry=Initialize-NetCrateRepositories -Root $engine -StorageRoot $storage -ResticExe $ResticExe
if($retry.PrimaryId -cne $first.PrimaryId -or $retry.ResultsId -cne $first.ResultsId){throw 'Retry replaced an existing repository.'}
$changed=Join-Path $TestRoot 'OtherStorage';New-Item -ItemType Directory -Path $changed | Out-Null
$rejected=$false;try{Initialize-NetCrateRepositories -Root $engine -StorageRoot $changed -ResticExe $ResticExe | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'An existing repository binding was moved silently.'}
$payload=Get-NetCrateRepositorySecrets -Root $engine
if(-not $payload.PrimaryPassword -or -not $payload.ResultsPassword -or $payload.PrimaryPassword -ceq $payload.ResultsPassword){throw 'Repository passwords were not independently generated.'}
$recovery=Join-Path $TestRoot 'Separate recovery copy.netcrate'
Export-NetCrateRecovery -Root $engine -LiteralPath $recovery
$saved=Get-Content -LiteralPath $recovery -Raw | ConvertFrom-Json
if($saved.Primary.Id -cne $first.PrimaryId -or $saved.Primary.Password -cne $payload.PrimaryPassword){throw 'Recovery material does not unlock the initialized repository.'}
$rejected=$false;try{Export-NetCrateRecovery -Root $engine -LiteralPath (Join-Path $engine 'bad-recovery.netcrate')}catch{$rejected=$true}
if(-not $rejected){throw 'Recovery was saved only inside the application folder.'}
Write-Output 'PASS: real repository initialization, preserved retry, binding checks and independent recovery export.'
