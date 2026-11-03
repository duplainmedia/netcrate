param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach($n in @('Configuration','Credentials','Restore')){Import-Module "$repo/src/shared/NetCrate.$n.psm1"}
$root=[IO.Path]::GetFullPath("$TestRoot/Engine");$active=[IO.Path]::GetFullPath("$TestRoot/Files")
$null=New-NetCrateIdentity $root ('a'*32) Source
$binding=@{Primary=@{Id=('a'*64);Uri='rest:https://127.0.0.1:8200/editing/originals/'};Results=@{Id=('b'*64);Uri='rest:https://127.0.0.1:8200/editing/results/'}}
$settings=@{Version=1;Role='Source';InstallationId=('a'*32);BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='WORKER';ActiveRoot=$active;StateRoot=$root;PollSeconds=5;Recipe='half-prores-v2';Tools=@{Restic=$ResticExe;PowerShell=(Get-Process -Id $PID).Path};Repositories=$binding}
Write-NetCrateJson "$root/settings.json" $settings
$cert='synthetic pinned certificate';$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($cert))).ToLowerInvariant()
Protect-NetCrateRecord $root paired-secrets @{SourceComputer='SOURCE';ProjectRoot=$active;Repositories=$binding;Certificate=$cert;CertificateSHA256=$hash;PrimaryPassword='synthetic';TransportPassword='synthetic'}
[IO.File]::WriteAllText("$root/server.pem",'replaced certificate')
$module=Get-Module NetCrate.Restore
& $module {function script:Invoke-RestoreNative($Context,[string[]]$Arguments){if($Arguments[0] -eq 'cat'){return ('{"id":"'+('a'*64)+'"}')};return '[]'}}
$failed=$false;try{Invoke-NetCrateRestoreAction ListBackups ([pscustomobject]@{InstallationId=('a'*32)}) $root $ResticExe|Out-Null}catch{$failed=$true}
if(-not $failed){throw 'Installed restore accepted a certificate replaced after pairing.'}
[IO.File]::WriteAllText("$root/server.pem",$cert)
$result=Invoke-NetCrateRestoreAction ListBackups ([pscustomobject]@{InstallationId=('a'*32)}) $root $ResticExe
if(-not $result.Succeeded){throw 'Valid installed binding failed.'}
$settings.SourceComputer='OTHER';Write-NetCrateJson "$root/settings.json" $settings
$failed=$false;try{Invoke-NetCrateRestoreAction ListBackups ([pscustomobject]@{InstallationId=('a'*32)}) $root $ResticExe|Out-Null}catch{$failed=$true}
if(-not $failed){throw 'Installed restore accepted settings changed from their protected source binding.'}
Write-Output 'PASS: installed restore checks owner, protected source binding and pinned certificate before native access.'
