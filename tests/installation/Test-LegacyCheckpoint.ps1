param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach($name in @('Workflow','Configuration','Credentials')){Import-Module "$repo/src/shared/NetCrate.$name.psm1"}
Import-Module "$repo/install/NetCrate.Repositories.psm1"
$null=New-Item -ItemType Directory -Path "$TestRoot/Projects/Earlier", "$TestRoot/Storage"
$source="$TestRoot/Source";$worker="$TestRoot/Worker";$project="$TestRoot/Projects/Earlier"
$null=New-NetCrateIdentity $source ('1'*32) Source;$null=New-NetCrateIdentity $worker ('2'*32) Worker
$binding=Initialize-NetCrateRepositories $worker "$TestRoot/Storage" $ResticExe
Protect-NetCrateRecord $source paired-secrets (Get-NetCrateRepositorySecrets $worker)
[IO.File]::WriteAllText("$project/notes.txt",'known earlier originals')
$settings=[pscustomobject]@{Role='Source';SourceComputer='SOURCE';ActiveRoot=([IO.Path]::GetFullPath("$TestRoot/Projects"));SnapshotRoot=(Get-NetCrateSnapshotRoot "$TestRoot/Projects");StateRoot=$source;Tools=@{Restic=$ResticExe};Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri=$binding.ResultsPath;Id=$binding.ResultsId}}}
$output=Invoke-WorkflowRestic $source $settings Primary @('backup','--json','--host','SOURCE','--tag','netcrate-originals','--time','2024-02-03 04:05:06','--',$project)
$summary=@($output -split '\r?\n' | Where-Object {$_} | ForEach-Object {$_|ConvertFrom-Json} | Where-Object message_type -CEQ summary)[0]
$expected=([DateTime]::SpecifyKind([DateTime]'2024-02-03T04:05:06',[DateTimeKind]::Local)).ToUniversalTime()
$queue="$source/Queue/legacy.json"
Write-NetCrateJson $queue @{Version=1;Id='legacy';Project=([IO.Path]::GetFullPath($project));State='Queued';Sample=$false;SnapshotId=$summary.snapshot_id;RequestId='';CreatedUtc='2024-02-03T04:00:00Z';UpdatedUtc='2024-02-03T04:00:00Z';RetryAfterUtc='2024-02-03T04:00:00Z'}
$completion=Invoke-NetCrateOriginals $source $settings $project $queue Media
if(([DateTimeOffset]$completion.BackupCompletedUtc).UtcDateTime -ne $expected){throw 'Legacy retry replaced the known earlier snapshot date with the current date.'}
$again=Invoke-NetCrateOriginals $source $settings $project $queue Media
if($again.SnapshotId -cne $summary.snapshot_id -or ([DateTimeOffset]$again.BackupCompletedUtc).UtcDateTime -ne $expected){throw 'A second legacy retry changed the original identity or date.'}
$receipts=@(Invoke-WorkflowRestic $source $settings Primary @('snapshots','--json','--tag','netcrate-backup-receipt') | ConvertFrom-Json)
if($receipts.Count -ne 1){throw 'Legacy receipt retry duplicated its completion.'}
$receipt=Read-NetCrateJson "$source/BackupReceipts/$($summary.snapshot_id).json"
if(([DateTimeOffset]$receipt.BackupCompletedUtc).UtcDateTime -ne $expected){throw 'Legacy completion receipt invented a newer date.'}
# Even an old checkpoint must bind the exact source snapshot before borrowing its time.
$bad=Read-NetCrateJson $queue;$bad.PSObject.Properties.Remove('BackupCompletedUtc');Write-NetCrateJson $queue $bad
$settings.SourceComputer='OTHER';$rejected=$false
try{Invoke-NetCrateOriginals $source $settings $project $queue Media|Out-Null}catch{$rejected=$true}
if(-not $rejected -or (Read-NetCrateJson $queue).BackupCompletedUtc){throw 'Legacy date recovery accepted a snapshot from the wrong source.'}
Write-Output 'PASS: legacy checkpoint recovers the known earlier date, preserves it across retries, deduplicates receipt and rejects source mismatch.'
