param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach ($name in @('Workflow','Configuration','Credentials','Protocol','Pairing')) { Import-Module "$repo/src/shared/NetCrate.$name.psm1" }
Import-Module "$repo/install/NetCrate.Repositories.psm1"
$script:assertions = 0
function Assert($value,$message) { if (-not $value) { throw $message }; $script:assertions++ }
function Reject([scriptblock]$action) { $bad=$false; try { & $action | Out-Null } catch { $bad=$true }; Assert $bad 'Unsafe or incomplete input was accepted.' }
$null = New-Item -ItemType Directory -Path $TestRoot
$source=Join-Path $TestRoot 'Engine'; $worker=Join-Path $TestRoot 'Worker'; $active=Join-Path $TestRoot 'Files'
$null=New-Item -ItemType Directory -Path "$active/Notes/Proxies/NetCrate", "$TestRoot/Storage"
$null=New-NetCrateIdentity $source ('1'*32) Source
$null=New-NetCrateIdentity $worker ('2'*32) Worker
$binding=Initialize-NetCrateRepositories $worker "$TestRoot/Storage" $ResticExe
Protect-NetCrateRecord $source paired-secrets (Get-NetCrateRepositorySecrets $worker)
$settings=[pscustomobject]@{Version=1; Role='Source'; InstallationId=('1'*32); BackupMode='Folder'; SourceComputer='SOURCE'; WorkerComputer='SERVER'; ActiveRoot=$active; StateRoot=$source
 SnapshotRoot=(Get-NetCrateSnapshotRoot $active); Recipe='half-prores-v2'; PollSeconds=2; Tools=@{Restic=$ResticExe;PowerShell=(Get-Process -Id $PID).Path}; Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri="$TestRoot/offline";Id=$binding.ResultsId}}}
$file="$active/Notes/Proxies/NetCrate/ordinary.txt"; [IO.File]::WriteAllText($file,'ordinary proxy-named folder bytes 日本語')
# Exercise the actual file-only desktop action bridge. Queueing does not contact
# transport; use syntactically valid private endpoints and then run the queued job
# against this fixture's local repositories below.
$bridge=$settings.PSObject.Copy();$bridge.Repositories=@{Primary=@{Uri='rest:https://backup.example:8200/editing/originals/';Id=$binding.PrimaryId};Results=@{Uri='rest:https://backup.example:8200/editing/results/';Id=$binding.ResultsId}}
Write-NetCrateJson "$source/settings.json" $bridge
Write-NetCrateJson "$source/prepared.json" @{Version=1;Role='Source';InstallationId=('1'*32);Folder=$active;BackupMode='Folder'}
$inputFile="$TestRoot/Setup/action.json"
$inputState=@{Version=1;Role='EditingComputer';InstallationId=('3'*32);Folder=$active;BackupMode='Folder';Path="$active/Notes"}
Write-NetCrateJson $inputFile $inputState
$result=& $settings.Tools.PowerShell -NoLogo -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action QueueBackup -InputFile $inputFile | ConvertFrom-Json
Assert (-not $result.Succeeded -and -not [IO.Directory]::Exists("$source/Queue")) 'The action bridge accepted another installation identity.'
$inputState.InstallationId='1'*32;Write-NetCrateJson $inputFile $inputState
$result=& $settings.Tools.PowerShell -NoLogo -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action QueueBackup -InputFile $inputFile | ConvertFrom-Json
Assert $result.Succeeded 'The ordinary manual folder could not be queued through the desktop action bridge.'
$queue=@([IO.Directory]::EnumerateFiles("$source/Queue",'*.json'))[0]
Invoke-NetCrateQueue $source $settings
$status=Read-NetCrateJson $queue
Assert ($status.State -ceq 'Ready' -and $status.BackupMode -ceq 'Folder' -and $status.MediaState -ceq 'Off') 'An ordinary manual backup did not complete with Results offline.'
Assert ($status.SnapshotId -cmatch '^[a-f0-9]{64}$' -and $status.BackupCompletedUtc) 'Ordinary completion lacks a durable full snapshot and time.'
Assert (-not [IO.Directory]::Exists("$source/Requests")) 'Folder mode published a media request.'
$snapshots=@(Invoke-WorkflowRestic $source $settings Primary @('snapshots','--json','--tag','netcrate-folder-originals') | ConvertFrom-Json)
Assert ($snapshots.Count -eq 1) 'Folder originals cannot be discovered separately.'
$restore="$TestRoot/Restored"
$null=Invoke-WorkflowRestic $source $settings Primary @('restore',($status.SnapshotId+':'+(Get-NetCrateSnapshotRoot "$active/Notes")),'--target',$restore,'--verify')
Assert ([IO.File]::ReadAllText("$restore/Proxies/NetCrate/ordinary.txt") -ceq 'ordinary proxy-named folder bytes 日本語') 'An ordinary Proxies folder lost its original bytes.'
$receipts=@(Invoke-WorkflowRestic $source $settings Primary @('snapshots','--json','--tag','netcrate-backup-receipt') | ConvertFrom-Json)
Assert ($receipts.Count -eq 1) 'Completion receipt was not stored in Primary.'
$receipt=Invoke-WorkflowRestic $source $settings Primary @('dump',$receipts[0].id, (Get-NetCrateSnapshotRoot $receipts[0].paths[0])) | ConvertFrom-Json
Assert ($receipt.SnapshotId -ceq $status.SnapshotId -and $receipt.JobId -ceq $status.Id -and $receipt.RepositoryId -ceq $binding.PrimaryId -and $receipt.Project -ceq $status.Project -and $receipt.SourceComputer -ceq 'SOURCE') 'Completion receipt is not bound to its backup.'
# Retry an already checkpointed backup; no duplicate logical receipt or originals.
$status.State='Queued'; Write-NetCrateJson $queue $status; Invoke-NetCrateQueue $source $settings
Assert (@(Invoke-WorkflowRestic $source $settings Primary @('snapshots','--json','--tag','netcrate-backup-receipt') | ConvertFrom-Json).Count -eq 1) 'Retry duplicated its receipt.'
$sample=Add-NetCrateBackupQueue $source $settings -Sample; Invoke-NetCrateQueue $source $settings
Assert ((Read-NetCrateJson $sample).State -ceq 'Ready') 'The ordinary generated sample did not pass restored-byte verification.'
Assert (@([IO.Directory]::EnumerateDirectories("$source/SampleVerification")).Count -eq 0) 'Successful sample verification left its disposable restore behind.'
$failedSample=Add-NetCrateBackupQueue $source $settings "$active/Notes";$failedStatus=Read-NetCrateJson $failedSample;$failedStatus.Sample=$true;Write-NetCrateJson $failedSample $failedStatus
Invoke-NetCrateQueue $source $settings
Assert ((Read-NetCrateJson $failedSample).State -ceq 'NeedsAttention' -and @([IO.Directory]::EnumerateDirectories("$source/SampleVerification")).Count -eq 0) 'Failed sample verification left its disposable restore behind.'
$rootQueue=Add-NetCrateBackupQueue $source $settings $active; Invoke-NetCrateQueue $source $settings
Assert ((Read-NetCrateJson $rootQueue).State -ceq 'Ready') 'Folder mode rejected backing up the configured root itself.'
[IO.File]::SetAttributes($active,([IO.File]::GetAttributes($active) -bor [IO.FileAttributes]::Offline))
try { Reject { Assert-WorkflowTree $active } } finally { [IO.File]::SetAttributes($active,[IO.FileAttributes]::Directory) }
$offlineAncestor="$TestRoot/OfflineAncestor";$null=New-Item -ItemType Directory -Path "$offlineAncestor/Selected"
[IO.File]::SetAttributes($offlineAncestor,([IO.File]::GetAttributes($offlineAncestor) -bor [IO.FileAttributes]::Offline))
try { Reject { Assert-WorkflowTree "$offlineAncestor/Selected" } } finally { [IO.File]::SetAttributes($offlineAncestor,[IO.FileAttributes]::Directory) }
Reject { Add-NetCrateBackupQueue $source $settings ($active+' sibling') }
$link="$active/Linked"; $null=New-Item -ItemType Junction -Path $link -Target "$active/Notes"
Reject { Add-NetCrateBackupQueue $source $settings $link }
[IO.Directory]::Delete($link)
$offline="$active/Notes/offline.txt";[IO.File]::WriteAllText($offline,'not fully local')
[IO.File]::SetAttributes($offline,[IO.FileAttributes]::Offline)
try { $q=Add-NetCrateBackupQueue $source $settings "$active/Notes";Invoke-NetCrateQueue $source $settings;$bad=Read-NetCrateJson $q;Assert ($bad.State -ceq 'NeedsAttention' -and -not $bad.SnapshotId -and $bad.FailureCategory -ceq 'unsupported-entry') 'An offline input did not preserve its safe category.' } finally { [IO.File]::SetAttributes($offline,[IO.FileAttributes]::Normal);[IO.File]::Delete($offline) }
$capable=$settings.PSObject.Copy();$capable.BackupMode='Media';$capable | Add-Member SourceBackupMode Folder
# No worker identity or Results credentials are available here. Folder requests
# must not invoke the media poll even on a media-capable server.
Invoke-NetCrateWorker "$TestRoot/no-worker" $capable
$locked="$active/Notes/locked.txt"; [IO.File]::WriteAllText($locked,'locked bytes')
$handle=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { $q=Add-NetCrateBackupQueue $source $settings "$active/Notes"; Invoke-NetCrateQueue $source $settings; $bad=Read-NetCrateJson $q; Assert ($bad.State -ceq 'NeedsAttention' -and -not $bad.SnapshotId -and -not $bad.BackupCompletedUtc) 'A locked input became a completed backup.' } finally { $handle.Dispose() }
# Exercise the native-process boundary: exit 3 accompanied by a valid-looking summary.
$workflow=Get-Module NetCrate.Workflow
& $workflow {
 param($root,$settings,$path)
 $saved=(Get-Command Invoke-NetCrateProcess).ScriptBlock
 try {
  function script:Invoke-NetCrateProcess { [pscustomobject]@{ExitCode=3;Output=('{"message_type":"summary","snapshot_id":"'+('a'*64)+'"}');Diagnostic='incomplete read'} }
  $q=Add-NetCrateBackupQueue $root $settings $path; $retry=Read-NetCrateJson $q; $retry.RetryAfterUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o'); Write-NetCrateJson $q $retry; Invoke-NetCrateQueue $root $settings
  $bad=Read-NetCrateJson $q
  if ($bad.State -cne 'NeedsAttention' -or $bad.SnapshotId -or $bad.BackupCompletedUtc -or $bad.FailureCategory -cne 'source-incomplete') { throw 'Restic exit 3 did not preserve a safe incomplete-source category.' }
 } finally { Set-Item Function:script:Invoke-NetCrateProcess $saved }
} $source $settings "$active/Notes"
# A matching tag alone cannot establish completion: validate remote receipt data.
$originalStatus=Read-NetCrateJson $queue
$forged="$TestRoot/forged.json"
$wrong=[ordered]@{Version=1;Kind='backup-receipt';RepositoryId=$binding.PrimaryId;SourceComputer='SOURCE';Project="$active/Other";SnapshotId=$originalStatus.SnapshotId;BackupMode='Folder';JobId=$originalStatus.Id;BackupCompletedUtc=$originalStatus.BackupCompletedUtc}
Write-NetCrateJson $forged $wrong
$null=Invoke-WorkflowRestic $source $settings Primary @('backup','--host','SOURCE','--tag','netcrate-backup-receipt','--tag',('netcrate-receipt-'+$originalStatus.SnapshotId),'--',$forged)
$originalStatus.State='Queued';Write-NetCrateJson $queue $originalStatus;Invoke-NetCrateQueue $source $settings
Assert ((Read-NetCrateJson $queue).State -ceq 'NeedsAttention') 'Receipt retry trusted a matching tag with the wrong source path.'
Write-Output "PASS: $script:assertions ordinary backup assertions plus exit-3 rejection."
