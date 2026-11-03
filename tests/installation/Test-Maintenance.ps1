#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe,[string]$PythonExe,[string]$RestServerExe)
$ErrorActionPreference='Stop'
if([IO.Directory]::Exists($TestRoot) -or [IO.File]::Exists($TestRoot)){throw 'TestRoot must not exist.'}
$full=[IO.Path]::GetFullPath($TestRoot)
if($full -notmatch '(?i)[\\/]NC5-[a-f0-9]{8}$'){throw 'Use a unique NC5 fixture root.'}
if(-not [IO.File]::Exists($ResticExe)){throw 'Pinned Restic is missing.'}
if(-not $PythonExe){$PythonExe='C:/Users/cmdup/AppData/Local/Temp/NC1-d9e0b433/NativeTools/Tools/Python/3.14.9/python.exe'}
if(-not $RestServerExe){$RestServerExe='C:/Users/cmdup/AppData/Local/Temp/NC1-d9e0b433/NativeTools/Tools/RestServer/0.14.0/rest-server_0.14.0_windows_amd64/rest-server.exe'}
if(-not [IO.File]::Exists($PythonExe) -or -not [IO.File]::Exists($RestServerExe)){throw 'Pinned Python and rest-server are required for the loopback fixture.'}
$module=Join-Path $PSScriptRoot '../../src/shared/NetCrate.Maintenance.psm1'
if(-not [IO.File]::Exists($module)){throw 'Maintenance module missing.'}
Import-Module $module
if(-not (Get-Command Get-NetCrateMaintenanceContext -ErrorAction SilentlyContinue)){throw 'Maintenance identity boundary missing.'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach($name in @('Configuration','Credentials')){Import-Module "$repo/src/shared/NetCrate.$name.psm1"}
Import-Module "$repo/install/NetCrate.Repositories.psm1"
$null=Assert-NetCrateLocalPath $full
$null=New-Item -ItemType Directory -Path "$full/Storage", "$full/Source"
$root="$full/Engine"; $id='2'*32
$null=New-NetCrateIdentity $root $id Worker
$binding=Initialize-NetCrateRepositories $root "$full/Storage" $ResticExe
Write-NetCrateJson "$full/fixture.json" @{Version=1;Root=$full;InstallationId=$id;PrimaryId=$binding.PrimaryId;ResultsId=$binding.ResultsId}
$settings=[pscustomobject]@{Version=1;Role='Worker';InstallationId=$id;BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='SERVER';ActiveRoot="$full/Source";StateRoot=$root;Recipe='half-prores-v2';PollSeconds=2;Tools=@{Restic=$ResticExe;PowerShell=(Get-Process -Id $PID).Path;RestServer=$ResticExe;Python=$ResticExe};Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri=$binding.ResultsPath;Id=$binding.ResultsId}}}
Write-NetCrateJson "$root/settings.json" $settings
Import-Module "$repo/src/shared/NetCrate.Workflow.psm1"
Import-Module "$repo/src/shared/NetCrate.Protocol.psm1"
$source="$full/SourceEngine"; $sourceIdentity=New-NetCrateIdentity $source ('1'*32) Source
Protect-NetCrateRecord $source paired-secrets (Get-NetCrateRepositorySecrets $root)
$sourceSettings=[pscustomobject]@{Role='Source';InstallationId=('1'*32);BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='SERVER';ActiveRoot="$full/Source";StateRoot=$source;SnapshotRoot=(Get-NetCrateSnapshotRoot "$full/Source");Recipe='half-prores-v2';PollSeconds=2;Tools=@{Restic=$ResticExe};Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri=$binding.ResultsPath;Id=$binding.ResultsId}}}
$null=New-Item -ItemType Directory -Path "$full/Source/Child"
[IO.File]::WriteAllText("$full/Source/Child/version.txt",'first')
$first=Invoke-NetCrateOriginals $source $sourceSettings "$full/Source/Child" '' Folder
[IO.File]::WriteAllText("$full/Source/Child/version.txt",'second')
$second=Invoke-NetCrateOriginals $source $sourceSettings "$full/Source/Child" '' Folder
[IO.File]::WriteAllText("$full/Source/Child/version.txt",'third')
$third=Invoke-NetCrateOriginals $source $sourceSettings "$full/Source/Child" '' Folder
Protect-NetCrateRecord $root runtime-peer @{PublicKey=$sourceIdentity.PublicKey}
Protect-NetCrateRecord $root inbound-request @{Request=@{RequestId=('3'*32);RecipientId=('1'*32)}}
$ack=[ordered]@{Version=1;Kind='pairing-ack';RequestId=('3'*32);SourceId=('1'*32);ServerId=$id}
Write-WorkflowRecord $source $sourceSettings pairing-ack (Get-NetCrateHash ('3'*32)) $ack
$preview=& (Get-Module NetCrate.Maintenance) {param($r,$i) Get-MaintenanceInventory (Get-NetCrateMaintenanceContext $r $i) 1} $root $id
if(@($preview.Candidates).Count -ne 2 -or $first.SnapshotId -cnotin $preview.Candidates -or $second.SnapshotId -cnotin $preview.Candidates){throw 'Preview did not preserve the latest positively completed folder original.'}
$previewRecord=& (Get-Module NetCrate.Maintenance) {param($r,$i) New-MaintenancePreview (Get-NetCrateMaintenanceContext $r $i) 'KeepLatestPerFolder' 1} $root $id
if($previewRecord.PreviewId -cnotmatch '^[a-f0-9]{32}$' -or @($previewRecord.Candidates).Count -ne 2 -or ([DateTimeOffset]$previewRecord.ExpiresUtc-[DateTimeOffset]$previewRecord.CreatedUtc).TotalMinutes -ne 15){throw 'The worker did not persist a bounded 15-minute preview.'}
$diskPreview=Read-NetCrateJson "$root/Maintenance/Previews/$($previewRecord.PreviewId).json"
if($diskPreview.Fingerprint -cnotmatch '^[a-f0-9]{64}$'){throw 'The preview fingerprint was not saved.'}
$verified=& (Get-Module NetCrate.Maintenance) {param($r,$i,$p) Test-MaintenancePreview (Get-NetCrateMaintenanceContext $r $i) $p ([DateTimeOffset]::UtcNow)} $root $id $previewRecord.PreviewId
if(@($verified.Candidates).Count -ne 2){throw 'A valid preview could not be revalidated.'}
$previewPath="$root/Maintenance/Previews/$($previewRecord.PreviewId).json"
$forged=Read-NetCrateJson $previewPath;$forged.Items[0].Project='C:\forged';Write-NetCrateJson $previewPath $forged
$rejected=$false;try{& (Get-Module NetCrate.Maintenance) {param($r,$i,$p) Test-MaintenancePreview (Get-NetCrateMaintenanceContext $r $i) $p ([DateTimeOffset]::UtcNow)} $root $id $previewRecord.PreviewId|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'A forged displayed preview was accepted.'}
Write-NetCrateJson $previewPath $previewRecord
$rejected=$false;try{& (Get-Module NetCrate.Maintenance) {param($r,$i,$p,$t) Test-MaintenancePreview (Get-NetCrateMaintenanceContext $r $i) $p $t} $root $id $previewRecord.PreviewId ([DateTimeOffset]$previewRecord.ExpiresUtc).AddSeconds(1)|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'An expired preview was accepted.'}
$recipe=(Get-NetCrateRecipe 'half-prores-v2').FingerprintRecipe
$project=Get-NetCrateSnapshotRoot "$full/Source/Child"
$mediaRequest=[pscustomobject][ordered]@{Version=2;Kind='request';SourceComputer='SOURCE';Repository=$binding.PrimaryPath;BackupExitCode=0;SnapshotId=$third.SnapshotId;ProjectPath=$project;CompletedUtc=[DateTime]::UtcNow.ToString('o');Recipe=$recipe;FootageFingerprint=('a'*64)}
$requestId=Get-NetCrateRequestId $third.SnapshotId $project $recipe
Write-WorkflowRecord $source $sourceSettings request $requestId $mediaRequest
$rejected=$false;try{& (Get-Module NetCrate.Maintenance) {param($r,$i,$p) Test-MaintenancePreview (Get-NetCrateMaintenanceContext $r $i) $p ([DateTimeOffset]::UtcNow)} $root $id $previewRecord.PreviewId|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'A preview survived a changed signed dependency.'}
$protected=& (Get-Module NetCrate.Maintenance) {param($r,$i) Get-MaintenanceInventory (Get-NetCrateMaintenanceContext $r $i) 1} $root $id
if(@($protected.Candidates).Count -ne 2){throw 'The valid request changed unrelated candidates.'}
$settings | Add-Member -NotePropertyName SnapshotRoot -NotePropertyValue (Get-NetCrateSnapshotRoot $settings.ActiveRoot) -Force
$output="$full/Generated";$null=New-Item -ItemType Directory -Path $output
[IO.File]::WriteAllText("$output/media_index.json",'[]',[Text.UTF8Encoding]::new($false))
$indexHash=(Get-FileHash "$output/media_index.json" -Algorithm SHA256).Hash.ToLowerInvariant()
$indexBytes=([IO.FileInfo]"$output/media_index.json").Length
[IO.File]::WriteAllText("$output/Files-SHA256.csv",("Path,SHA256,Bytes`nmedia_index.json,$indexHash,$indexBytes`n"),[Text.UTF8Encoding]::new($false))
$manifestHash=(Get-FileHash "$output/Files-SHA256.csv" -Algorithm SHA256).Hash.ToLowerInvariant()
Write-NetCrateJson "$output/COMPLETE.json" @{JobId=('auto-'+('a'*64));GenerationSnapshotId=$first.SnapshotId;ProjectPath=$project;Recipe=$recipe;FootageFingerprint=('a'*64);ResultManifestSHA256=$manifestHash;Clips=0}
$completeHash=(Get-FileHash "$output/COMPLETE.json" -Algorithm SHA256).Hash.ToLowerInvariant()
$wire=Invoke-WorkflowRestic $root $settings Results @('backup','--json','--host','SERVER','--tag',('netcrate-result-auto-'+('a'*64)),'--',$output)
$resultId=@($wire -split '\r?\n'|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json}|Where-Object message_type -CEQ 'summary')[0].snapshot_id
$association=New-NetCrateAssociation $mediaRequest $settings $first.SnapshotId $resultId $completeHash $manifestHash
Write-WorkflowRecord $root $settings association $requestId $association
$protected=& (Get-Module NetCrate.Maintenance) {param($r,$i) Get-MaintenanceInventory (Get-NetCrateMaintenanceContext $r $i) 1} $root $id
if(@($protected.Candidates).Count -ne 1 -or $protected.Candidates[0] -cne $second.SnapshotId){throw 'A worker-signed association did not protect the older generation original.'}
$progress=[ordered]@{Version=2;Kind='progress';RequestId=$requestId;SnapshotId=$third.SnapshotId;Recipe=$recipe;FootageFingerprint=('a'*64);State='Processing';UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
Write-WorkflowRecord $root $settings progress $requestId $progress
$withProgress=& (Get-Module NetCrate.Maintenance) {param($r,$i) Get-MaintenanceInventory (Get-NetCrateMaintenanceContext $r $i) 1} $root $id
if(@($withProgress.Candidates).Count -ne 1 -or $withProgress.Candidates[0] -cne $second.SnapshotId){throw 'Worker progress did not preserve request and generation dependencies.'}
$reuseRequest=($mediaRequest|ConvertTo-Json|ConvertFrom-Json);$reuseRequest.SnapshotId=$second.SnapshotId
$reuseId=Get-NetCrateRequestId $second.SnapshotId $project $recipe
Write-WorkflowRecord $source $sourceSettings request $reuseId $reuseRequest
$reuse=New-NetCrateAssociation $reuseRequest $settings $first.SnapshotId $resultId $completeHash $manifestHash
Write-WorkflowRecord $root $settings association $reuseId $reuse
$afterReuse=& (Get-Module NetCrate.Maintenance) {param($r,$i) Get-MaintenanceInventory (Get-NetCrateMaintenanceContext $r $i) 1} $root $id
if(@($afterReuse.Candidates).Count -ne 0){throw 'Generation reuse did not protect both referenced originals.'}
$delivery=[ordered]@{Version=2;Kind='delivery-ack';RequestId=$requestId;RequestedSnapshotId=$third.SnapshotId;GenerationSnapshotId=$first.SnapshotId;ResultSnapshotId=$resultId;JobId=('auto-'+('a'*64));Recipe=$recipe;FootageFingerprint=('a'*64);MediaFiles=0}
Write-WorkflowRecord $source $sourceSettings delivery-ack $requestId $delivery
Write-NetCrateJson "$root/Published/$requestId.json" $association
Write-NetCrateJson "$root/Generations/$(('a'*64)).json" @{Output=$output;Association=$association}
Write-NetCrateJson "$root/WorkerJobs/$requestId.json" @{State='Published';RequestId=$requestId;ProjectPath=$project;SnapshotId=$third.SnapshotId;UpdatedUtc=[DateTime]::UtcNow.ToString('o');RetryAfterUtc=[DateTime]::UtcNow.ToString('o');Output=$output}
$withLocal=& (Get-Module NetCrate.Maintenance) {param($r,$i) Get-MaintenanceInventory (Get-NetCrateMaintenanceContext $r $i) 1} $root $id
if(@($withLocal.Candidates).Count -ne 0 -or @($withLocal.LocalEvidence).Count -ne 3){throw 'Verified local and delivery dependencies were not preserved.'}
$localPreview=& (Get-Module NetCrate.Maintenance) {param($r,$i) New-MaintenancePreview (Get-NetCrateMaintenanceContext $r $i) 'KeepLatestPerFolder' 1} $root $id
$localJob=Read-NetCrateJson "$root/WorkerJobs/$requestId.json";$localJob.UpdatedUtc=[DateTime]::UtcNow.AddSeconds(1).ToString('o');Write-NetCrateJson "$root/WorkerJobs/$requestId.json" $localJob
$rejected=$false;try{& (Get-Module NetCrate.Maintenance) {param($r,$i,$p) Test-MaintenancePreview (Get-NetCrateMaintenanceContext $r $i) $p ([DateTimeOffset]::UtcNow)} $root $id $localPreview.PreviewId|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'A changed worker dependency did not invalidate the preview.'}
$wrongAck=[ordered]@{Version=1;Kind='pairing-ack';RequestId=('3'*32);SourceId=('9'*32);ServerId=$id}
Write-WorkflowRecord $source $sourceSettings pairing-ack (Get-NetCrateHash ('3'*32)) $wrongAck
$rejected=$false;try{& (Get-Module NetCrate.Maintenance) {param($r,$i) Get-MaintenanceInventory (Get-NetCrateMaintenanceContext $r $i) 1} $root $id|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Conflicting signed pairing evidence was ignored.'}
$context=Get-NetCrateMaintenanceContext $root $id
if($context.Binding.PrimaryId -cne $binding.PrimaryId){throw 'Verified context has wrong repository.'}
$keepAll=& (Get-Module NetCrate.Maintenance) {param($c)
 $saved=(Get-Command Invoke-NetCrateProcess).ScriptBlock
 try {
  function script:Invoke-NetCrateProcess {throw 'Keep all invoked a native command.'}
  $p=New-MaintenancePreview $c 'KeepAll' 0
  $operation=[pscustomobject]@{Version=1;InstallationId=$c.Owner.InstallationId;OperationId=[guid]::NewGuid().ToString('N');Action='ApplyRetention';State='Running';PreviewId=$p.PreviewId;Confirm=$true}
  $file=[IO.Path]::Combine($c.Owner.Root,'Maintenance','Requests',$operation.OperationId+'.json');Write-NetCrateJson $file $operation
  Invoke-MaintenanceApply $c $operation $file
  [pscustomobject]@{Preview=$p;Operation=$operation;File=$file}
 } finally {Set-Item Function:script:Invoke-NetCrateProcess $saved}
} $context
if(@($keepAll.Preview.Candidates).Count -ne 0 -or $keepAll.Operation.Step -cne 'Completed'){throw 'Keep all did not remain non-destructive.'}
[IO.File]::Delete($keepAll.File)
$health=& (Get-Module NetCrate.Maintenance) {param($r,$i) Invoke-MaintenanceCheck (Get-NetCrateMaintenanceContext $r $i)} $root $id
if($health.Primary.State -cne 'Succeeded' -or $health.Results.State -cne 'Succeeded' -or -not $health.Primary.LastSuccessUtc -or -not $health.Results.LastSuccessUtc){throw 'Both repositories did not record a successful native check.'}
$failed=& (Get-Module NetCrate.Maintenance) {param($r,$i)
 $context=Get-NetCrateMaintenanceContext $r $i
 function Invoke-NetCrateProcess { [pscustomobject]@{ExitCode=1;Output='';Diagnostic='SECRET-DO-NOT-STORE'} }
 Invoke-MaintenanceCheck $context
} $root $id
if($failed.Primary.State -cne 'Failed' -or $failed.Primary.LastSuccessUtc -cne $health.Primary.LastSuccessUtc){throw 'A failed check erased the prior success.'}
if([IO.File]::ReadAllText("$root/Maintenance/health.json").Contains('SECRET-DO-NOT-STORE')){throw 'Health state leaked native diagnostics.'}
$request=Invoke-NetCrateMaintenanceRequest $root $id PreviewRetention @{Policy='KeepAll'}
if($request.State -cne 'Queued' -or $request.OperationId -cnotmatch '^[a-f0-9]{32}$'){throw 'Preview request was not durably queued.'}
$stored=Read-NetCrateJson "$root/Maintenance/Requests/$($request.OperationId).json"
if($stored.Policy -cne 'KeepAll'){throw 'Preview policy was not persisted.'}
$rejected=$false;try{Invoke-NetCrateMaintenanceRequest $root $id ApplyRetention @{PreviewId=('a'*32);Confirm=$true;Repository='forged'}|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Maintenance accepted an arbitrary repository.'}
$rejected=$false;try{Invoke-NetCrateMaintenanceRequest $root $id ApplyRetention @{PreviewId=('a'*32);Confirm=$false}|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Maintenance accepted an unconfirmed apply.'}
$checkRequest=Invoke-NetCrateMaintenanceRequest $root $id CheckStorage @{}
for($i=0;$i -lt 2;$i++){
 & (Get-Module NetCrate.Maintenance) {param($r,$i) Invoke-NetCrateMaintenancePass $r $i $null $null} $root $id
 $checked=Read-NetCrateJson "$root/Maintenance/Requests/$($checkRequest.OperationId).json"
 if($checked.State -ceq 'Succeeded'){break}
}
if($checked.State -cne 'Succeeded'){throw 'Worker pass did not complete the durable health request.'}
$status=Get-NetCrateMaintenanceStatus $root $id
if($status.FreeBytes -lt 0 -or $status.LowSpace -isnot [bool] -or $status.Health.Primary.State -cne 'Succeeded'){throw 'Storage status is missing volume space or the latest health state.'}
if($status.Operations.Count -ne 2 -or @($status.Operations | Where-Object {$_.Action -ceq 'CheckStorage' -and $_.State -ceq 'Succeeded'}).Count -ne 1){throw 'Storage status lost the queued request.'}
$settings.Repositories.Primary.Uri='rest:https://backup.example/editing/originals/'
Write-NetCrateJson "$root/settings.json" $settings
$rejected=$false;try{Get-NetCrateMaintenanceContext $root $id|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Worker HTTPS repository forgery was accepted.'}
Write-Output 'PASS: worker repository identity and forged endpoint rejection.'

$settings.Repositories.Primary.Uri=$binding.PrimaryPath;Write-NetCrateJson "$root/settings.json" $settings
$marker="$($binding.RepositoryRoot)/netcrate-owner.json"
[IO.File]::Move($marker,"$marker.saved")
try {$rejected=$false;try{Get-NetCrateMaintenanceContext $root $id|Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Missing storage marker was accepted.'}} finally {[IO.File]::Move("$marker.saved",$marker)}
$wrong='3'*32
$rejected=$false;try{Get-NetCrateMaintenanceContext $root $wrong|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Another installation was accepted.'}
$settings.Repositories.Results.Id='a'*64;Write-NetCrateJson "$root/settings.json" $settings
$rejected=$false;try{Get-NetCrateMaintenanceContext $root $id|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Forged results identity was accepted.'}
Write-Output 'PASS: missing marker, owner mismatch and forged ID rejected.'
$settings.Repositories.Results.Id=$binding.ResultsId;Write-NetCrateJson "$root/settings.json" $settings
$changed=Read-NetCrateJson "$root/repositories.json";$changed.PrimaryId='b'*64;Write-NetCrateJson "$root/repositories.json" $changed
$settings.Repositories.Primary.Id='b'*64;Write-NetCrateJson "$root/settings.json" $settings
$rejected=$false;try{Get-NetCrateMaintenanceContext $root $id|Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'An actual config identity mismatch was accepted.'}
Write-Output 'PASS: actual repository config ID overrides forged matching metadata.'
Write-Output 'PASS: signed and local dependency evidence, stale previews, status and worker check.'
# A separate, newly-created disposable repository pair is used for native
# destructive checks. No user-supplied repo path or existing root is accepted.
$native=[IO.Path]::Combine($full,'NativeApply');$nativeWorker="$native/Engine";$nativeSource="$native/SourceEngine";$nativeStorage="$native/Storage";$nativeData="$native/Files"
$null=New-Item -ItemType Directory -Path $nativeStorage,$nativeData
$nativeId='4'*32;$null=New-NetCrateIdentity $nativeWorker $nativeId Worker;$nativeSourceIdentity=New-NetCrateIdentity $nativeSource ('5'*32) Source
$nativeBinding=Initialize-NetCrateRepositories $nativeWorker $nativeStorage $ResticExe
Write-NetCrateJson "$native/fixture.json" @{Version=1;Root=$native;InstallationId=$nativeId;PrimaryId=$nativeBinding.PrimaryId;ResultsId=$nativeBinding.ResultsId}
Protect-NetCrateRecord $nativeSource paired-secrets (Get-NetCrateRepositorySecrets $nativeWorker)
$nativeWorkerSettings=[pscustomobject]@{Version=1;Role='Worker';InstallationId=$nativeId;BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='SERVER';ActiveRoot=$nativeData;StateRoot=$nativeWorker;Recipe='half-prores-v2';PollSeconds=2;Tools=@{Restic=$ResticExe;PowerShell=(Get-Process -Id $PID).Path;RestServer=$RestServerExe;Python=$PythonExe};Repositories=@{Primary=@{Uri=$nativeBinding.PrimaryPath;Id=$nativeBinding.PrimaryId};Results=@{Uri=$nativeBinding.ResultsPath;Id=$nativeBinding.ResultsId}}}
Write-NetCrateJson "$nativeWorker/settings.json" $nativeWorkerSettings
$nativeSourceSettings=[pscustomobject]@{Role='Source';InstallationId=('5'*32);BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='SERVER';ActiveRoot=$nativeData;StateRoot=$nativeSource;SnapshotRoot=(Get-NetCrateSnapshotRoot $nativeData);Recipe='half-prores-v2';PollSeconds=2;Tools=@{Restic=$ResticExe};Repositories=@{Primary=@{Uri=$nativeBinding.PrimaryPath;Id=$nativeBinding.PrimaryId};Results=@{Uri=$nativeBinding.ResultsPath;Id=$nativeBinding.ResultsId}}}
Protect-NetCrateRecord $nativeWorker runtime-peer @{PublicKey=$nativeSourceIdentity.PublicKey}
Protect-NetCrateRecord $nativeWorker inbound-request @{Request=@{RequestId=('6'*32);RecipientId=('5'*32)}}
$nativeAck=[ordered]@{Version=1;Kind='pairing-ack';RequestId=('6'*32);SourceId=('5'*32);ServerId=$nativeId}
Write-WorkflowRecord $nativeSource $nativeSourceSettings pairing-ack (Get-NetCrateHash ('6'*32)) $nativeAck
$versions=@();$versionHashes=@();foreach($value in @('fixture-first','fixture-second','fixture-third')){[IO.File]::WriteAllText("$nativeData/version.txt",$value);$versionHashes+=(Get-FileHash "$nativeData/version.txt" -Algorithm SHA256).Hash;$versions+=Invoke-NetCrateOriginals $nativeSource $nativeSourceSettings $nativeData '' Folder}
function Assert-NativeFixture {
 $marker=Read-NetCrateJson "$native/fixture.json"
 if($marker.Version -ne 1 -or $marker.Root -cne $native -or $marker.InstallationId -cne $nativeId -or $marker.PrimaryId -cne $nativeBinding.PrimaryId -or $marker.ResultsId -cne $nativeBinding.ResultsId -or -not $native.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Destructive fixture ownership guard failed.'}
 $verified=Get-NetCrateMaintenanceContext $nativeWorker $nativeId
 if($verified.Binding.PrimaryId -cne $marker.PrimaryId -or $verified.Binding.ResultsId -cne $marker.ResultsId -or -not $verified.Binding.RepositoryRoot.StartsWith($native+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Destructive fixture repository guard failed.'}
 return $verified
}
# Simulate interruptions with an argv-guarded runner. It delegates only bounded
# reads to the pinned binary and never executes either destructive command.
$guardContext=Assert-NativeFixture
foreach($failure in @('Forget','Prune')){
 $fakePreview=& (Get-Module NetCrate.Maintenance) {param($c) New-MaintenancePreview $c 'KeepLatestPerFolder' 1} $guardContext
 $fakeOp=[pscustomobject]@{Version=1;InstallationId=$nativeId;OperationId=[guid]::NewGuid().ToString('N');Action='ApplyRetention';State='Running';CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');PreviewId=$fakePreview.PreviewId;Confirm=$true}
 $fakeFile="$nativeWorker/Maintenance/Requests/$($fakeOp.OperationId).json";Write-NetCrateJson $fakeFile $fakeOp
 $outcome=& (Get-Module NetCrate.Maintenance) {
  param($c,$o,$f,$mode,$candidateIds)
  $saved=(Get-Command Invoke-NetCrateProcess).ScriptBlock
  $script:FixtureRunnerSaved=$saved;$script:FixtureMode=$mode;$script:FixtureIds=@($candidateIds);$script:FixtureForgetSeen=$false;$script:FixtureArgv=[Collections.Generic.List[string]]::new();$script:FixturePrimary=$c.Binding.PrimaryPath;$script:FixtureResults=$c.Binding.ResultsPath;$script:FixtureExe=$c.Settings.Tools.Restic
  function script:Invoke-NetCrateProcess {
   param([string]$FilePath,[string[]]$Arguments,[hashtable]$Environment,[int]$TimeoutSeconds,[string]$OutputFile,[string]$InputText)
   if($FilePath -cne $script:FixtureExe -or $Arguments.Count -lt 4 -or $Arguments[0] -cne '--repo' -or $Arguments[1] -cnotin @($script:FixturePrimary,$script:FixtureResults) -or $Arguments -ccontains '--no-lock'){throw 'Fixture runner rejected an unexpected target.'}
   $verb=$Arguments[3];if($verb -cnotin @('cat','snapshots','dump','ls','forget','prune')){throw 'Fixture runner rejected an unexpected command.'}
   $script:FixtureArgv.Add(($Arguments -join ' '))
   if($verb -ceq 'forget'){
    if($Arguments[1] -cne $script:FixturePrimary -or ((@($Arguments|Select-Object -Skip 4)|Sort-Object) -join ',') -cne (($script:FixtureIds|Sort-Object) -join ',')){throw 'Fixture runner rejected unexpected forget IDs.'}
    $script:FixtureForgetSeen=$true;return [pscustomobject]@{ExitCode=if($script:FixtureMode -ceq 'Forget'){1}else{0};Output='';Diagnostic='sensitive fixture text'}
   }
   if($verb -ceq 'prune'){if($Arguments[1] -cne $script:FixturePrimary -or -not $script:FixtureForgetSeen){throw 'Fixture runner rejected unexpected prune.'};return [pscustomobject]@{ExitCode=1;Output='';Diagnostic='sensitive fixture text'}}
   $result=& $script:FixtureRunnerSaved @PSBoundParameters
   if($verb -ceq 'snapshots' -and $Arguments[1] -ceq $script:FixturePrimary -and $script:FixtureForgetSeen -and $script:FixtureMode -ceq 'Prune'){
    $remaining=@($result.Output|ConvertFrom-Json|Where-Object {$_.id -cnotin $script:FixtureIds})
    return [pscustomobject]@{ExitCode=0;Output=($remaining|ConvertTo-Json -Depth 32 -Compress);Diagnostic=''}
   }
   return $result
  }
  try {try{Invoke-MaintenanceApply $c $o $f}catch{};[pscustomobject]@{Operation=(Read-NetCrateJson $f);Argv=@($script:FixtureArgv)}}
  finally {Set-Item Function:script:Invoke-NetCrateProcess $script:FixtureRunnerSaved}
 } $guardContext $fakeOp $fakeFile $failure $fakePreview.Candidates
 if($outcome.Operation.State -cne 'NeedsAttention' -or ($failure -ceq 'Forget' -and ($outcome.Operation.Step -cne 'ForgetStarted' -or @($outcome.Argv|Where-Object {$_ -match ' prune$'}).Count)) -or ($failure -ceq 'Prune' -and $outcome.Operation.Step -cne 'PruneStarted')){throw 'Interrupted maintenance did not preserve its partial step.'}
 if([IO.File]::ReadAllText($fakeFile).Contains('sensitive fixture text')){throw 'Native diagnostic text leaked into operation state.'}
}
Write-Output 'PASS: guarded simulated forget and prune interruption states.'
Import-Module "$repo/install/NetCrate.Engine.psm1" -DisableNameChecking
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$endpoint=Initialize-NetCrateEndpoint $nativeWorker '127.0.0.1' '127.0.0.1' @{Restic=$ResticExe;RestServer=$RestServerExe;Python=$PythonExe} -Fixture -Port $port
[IO.File]::WriteAllText("$nativeSource/server.pem",$endpoint.Certificate)
Write-NetCrateJson "$nativeWorker/prepared.json" @{Version=1;Role='Worker';InstallationId=$nativeId;Folder=$nativeStorage;BackupMode='Folder'}
$nativeContext=Assert-NativeFixture
$beforeResults=@(Invoke-WorkflowRestic $nativeWorker $nativeWorkerSettings Results @('snapshots','--json')|ConvertFrom-Json)
$inputFile="$native/Setup/action.json"
function Invoke-FixtureBridge([string]$action,$data){
 Write-NetCrateJson $inputFile $data
 $wire=& (Get-Process -Id $PID).Path -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action $action -InputFile $inputFile
 if($LASTEXITCODE -ne 0){throw "Fixture bridge failed: $action"}
 return $wire|ConvertFrom-Json
}
Write-NetCrateJson $inputFile @{Version=1;Role='EditingComputer';InstallationId=$nativeId;Policy='KeepAll'}
$bad=& (Get-Process -Id $PID).Path -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action PreviewRetention -InputFile $inputFile|ConvertFrom-Json
if($bad.Succeeded){throw 'A source-role storage action was accepted.'}
Write-NetCrateJson $inputFile @{Version=1;Role='BackupServer';InstallationId=$nativeId;Policy='KeepAll';Repository=$nativeBinding.PrimaryPath}
$bad=& (Get-Process -Id $PID).Path -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action PreviewRetention -InputFile $inputFile|ConvertFrom-Json
if($bad.Succeeded){throw 'The bridge accepted an arbitrary repository.'}
$state=@{Version=1;Role='BackupServer';InstallationId=$nativeId;Policy='KeepLatestPerFolder';Count=2}
$queued=Invoke-FixtureBridge 'PreviewRetention' $state
if(-not $queued.Succeeded){throw 'The fixture preview was not queued through the bridge.'}
$start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
foreach($argument in @('-NoProfile','-File',"$repo/src/shared/Invoke-NetCrateRuntime.ps1",'-Root',$nativeWorker)){$start.ArgumentList.Add($argument)}
Write-Output 'Starting loopback runtime preview/apply/restart fixture.'
$runtime=[Diagnostics.Process]::Start($start)
try {
 $previewFile="$nativeWorker/Maintenance/Requests/$($queued.OperationId).json"
 $watch=[Diagnostics.Stopwatch]::StartNew();$previewStatus=$null
 while($watch.Elapsed.TotalSeconds -lt 180){
  if($runtime.HasExited){throw 'The fixture worker runtime exited unexpectedly.'}
  $previewOperation=Read-NetCrateJson $previewFile
  if($previewOperation.State -cin @('Succeeded','Failed','NeedsAttention')){break};Start-Sleep -Milliseconds 300
 }
 $previewStatus=Invoke-FixtureBridge 'StorageStatus' @{Version=1;Role='BackupServer';InstallationId=$nativeId}
 if(-not $previewStatus.Maintenance.Preview -or $previewStatus.Maintenance.Preview.CandidateCount -ne 1){throw 'The runtime did not produce the expected preview.'}
 $nativePreview=$previewStatus.Maintenance.Preview
 $nativeContext=Assert-NativeFixture
 $queued=Invoke-FixtureBridge 'ApplyRetention' @{Version=1;Role='BackupServer';InstallationId=$nativeId;PreviewId=$nativePreview.PreviewId;Confirm=$true}
 if($queued.OperationId -cnotmatch '^[a-f0-9]{32}$'){throw 'The fixture apply was not queued.'}
 $opFile="$nativeWorker/Maintenance/Requests/$($queued.OperationId).json"
 $watch.Restart();$op=$null
 while($watch.Elapsed.TotalSeconds -lt 300){
  if($runtime.HasExited){throw 'The fixture worker runtime exited during retention.'}
  $op=Read-NetCrateJson $opFile
  if($op.State -cin @('Succeeded','Failed','NeedsAttention')){break};Start-Sleep -Milliseconds 300
 }
 if(-not $op -or $op.State -cne 'Succeeded'){throw 'The fixture worker did not complete retention.'}
 $remote=[pscustomobject]@{Role='Source';Tools=@{Restic=$ResticExe};Repositories=@{Primary=@{Uri="rest:https://127.0.0.1:$port/editing/originals/";Id=$nativeBinding.PrimaryId};Results=@{Uri="rest:https://127.0.0.1:$port/editing/results/";Id=$nativeBinding.ResultsId}}}
 $reconnected=$false;for($i=0;$i -lt 20;$i++){try{$cfg=Invoke-WorkflowRestic $nativeSource $remote Primary @('cat','config')|ConvertFrom-Json;if($cfg.id -ceq $nativeBinding.PrimaryId){$reconnected=$true;break}}catch{Start-Sleep -Milliseconds 200}}
 if(-not $reconnected){throw 'The append-only endpoint did not restart after retention.'}
 $denied=$false;try{Invoke-WorkflowRestic $nativeSource $remote Primary @('forget',$versions[2].SnapshotId)|Out-Null}catch{$denied=$true}
 if(-not $denied){throw 'The remote append-only endpoint accepted deletion.'}
 $nativeContext=Assert-NativeFixture
 $replay=Invoke-FixtureBridge 'ApplyRetention' @{Version=1;Role='BackupServer';InstallationId=$nativeId;PreviewId=$nativePreview.PreviewId;Confirm=$true}
 $replayFile="$nativeWorker/Maintenance/Requests/$($replay.OperationId).json";$watch.Restart()
 do {Start-Sleep -Milliseconds 300;$replayState=Read-NetCrateJson $replayFile;if($replayState.State -cin @('Succeeded','Failed','NeedsAttention')){break}}while($watch.Elapsed.TotalSeconds -lt 120)
 if($replayState.State -cne 'Failed'){throw 'A used preview was replayed.'}
} finally {
 if(-not $runtime.HasExited){$runtime.Kill();$runtime.WaitForExit()};$runtime.Dispose()
 $watch=[Diagnostics.Stopwatch]::StartNew();do{$remaining=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object Port -EQ $port);if(-not $remaining.Count){break};Start-Sleep -Milliseconds 200}while($watch.Elapsed.TotalSeconds -lt 10)
 if($remaining.Count){throw 'The worker-owned endpoint survived runtime termination.'}
}
# A new runtime must restore its own endpoint after the prior process was killed.
$runtime2=[Diagnostics.Process]::Start($start)
try {
 $restarted=$false;for($i=0;$i -lt 30;$i++){
  if($runtime2.HasExited){throw 'The restarted fixture worker exited.'}
  try{$cfg=Invoke-WorkflowRestic $nativeSource $remote Primary @('cat','config')|ConvertFrom-Json;if($cfg.id -ceq $nativeBinding.PrimaryId){$restarted=$true;break}}catch{Start-Sleep -Milliseconds 200}
 }
 if(-not $restarted){throw 'The append-only endpoint did not recover on worker restart.'}
} finally {if(-not $runtime2.HasExited){$runtime2.Kill();$runtime2.WaitForExit()};$runtime2.Dispose()}
$op=Read-NetCrateJson $opFile
if($op.State -cne 'Succeeded' -or $op.Step -cne 'Completed'){throw 'Native forget/prune did not finish.'}
$after=@(Invoke-WorkflowRestic $nativeWorker $nativeWorkerSettings Primary @('snapshots','--json')|ConvertFrom-Json)
if(@($after|Where-Object id -CEQ $versions[0].SnapshotId).Count -or @($after|Where-Object id -CEQ $versions[1].SnapshotId).Count -ne 1 -or @($after|Where-Object id -CEQ $versions[2].SnapshotId).Count -ne 1){throw 'Native inventory did not match the reviewed candidates.'}
$afterResults=@(Invoke-WorkflowRestic $nativeWorker $nativeWorkerSettings Results @('snapshots','--json')|ConvertFrom-Json)
if(($beforeResults|ConvertTo-Json -Depth 20 -Compress) -cne ($afterResults|ConvertTo-Json -Depth 20 -Compress)){throw 'Results snapshots changed during retention.'}
foreach($index in @(1,2)){
 $restore="$native/Restored-$index";$null=Invoke-WorkflowRestic $nativeWorker $nativeWorkerSettings Primary @('restore',($versions[$index].SnapshotId+':'+(Get-NetCrateSnapshotRoot $nativeData)),'--target',$restore,'--verify')
 if((Get-FileHash "$restore/version.txt" -Algorithm SHA256).Hash -cne $versionHashes[$index]){throw 'A retained fixture version did not restore exact bytes.'}
}
Write-Output 'PASS: native exact-ID forget, prune, retained restore hash and unchanged Results.'
