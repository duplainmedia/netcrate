#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe,[string]$PythonExe,[string]$RestServerExe)
$ErrorActionPreference='Stop'
if([IO.Directory]::Exists($TestRoot) -or [IO.File]::Exists($TestRoot)){throw 'TestRoot must not exist.'}
$full=[IO.Path]::GetFullPath($TestRoot)
if($full -notmatch '(?i)[\\/](temp|_temp)[\\/]' -or $full -match '(?i)OneDrive' -or $full -notmatch '(?i)[\\/]NC5-[a-f0-9]{8}$'){throw 'Use a unique NC5 fixture root.'}
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


function Guard {
 $marker=Read-NetCrateJson "$full/fixture.json"
 if($marker.Root -cne $full -or $marker.InstallationId -cne $id -or $marker.PrimaryId -cne $binding.PrimaryId -or $marker.ResultsId -cne $binding.ResultsId){throw 'Fixture marker mismatch.'}
 $c=Get-NetCrateMaintenanceContext $root $id
 if($c.Binding.PrimaryPath -cne $binding.PrimaryPath -or $c.Binding.PrimaryId -cne $marker.PrimaryId -or $c.Binding.ResultsId -cne $marker.ResultsId){throw 'Fixture repository identity mismatch.'}
 return $c
}
$context=Guard
$preview=& (Get-Module NetCrate.Maintenance) {param($c) New-MaintenancePreview $c 'KeepLatestPerFolder' 1} $context
$op=[pscustomobject]@{Version=1;InstallationId=$id;OperationId=[guid]::NewGuid().ToString('N');Action='ApplyRetention';State='Running';CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');PreviewId=$preview.PreviewId;Confirm=$true}
$null=[IO.Directory]::CreateDirectory("$root/Maintenance/Requests");$opFile="$root/Maintenance/Requests/$($op.OperationId).json";Write-NetCrateJson $opFile $op
& (Get-Module NetCrate.Maintenance) {
 param($c,$o,$f,$ids)
 $saved=(Get-Command Invoke-NetCrateProcess).ScriptBlock
 $script:SavedRunner=$saved
 try {
  $script:ExpectedRepo=$c.Binding.PrimaryPath;$script:ExpectedIds=@($ids);$script:PruneBlocked=$false
  function script:Invoke-NetCrateProcess {
   param([string]$FilePath,[string[]]$Arguments,[hashtable]$Environment,[int]$TimeoutSeconds,[string]$OutputFile,[string]$InputText)
   if($Arguments -ccontains 'forget' -or $Arguments -ccontains 'prune') {if($Arguments[0] -cne '--repo' -or $Arguments[1] -cne $script:ExpectedRepo -or $Arguments[2] -cne '--no-cache'){throw 'Unexpected fixture target.'}}
   if($Arguments.Count -gt 3 -and $Arguments[3] -ceq 'forget') {if(((@($Arguments|Select-Object -Skip 4)|Sort-Object) -join ',') -cne (($script:ExpectedIds|Sort-Object) -join ',')){throw 'Unexpected fixture forget IDs.'}}
   elseif($Arguments.Count -gt 3 -and $Arguments[3] -ceq 'prune') {if($Arguments.Count -ne 4){throw 'Unexpected prune arguments.'};$script:PruneBlocked=$true;return [pscustomobject]@{ExitCode=1;Output='';Diagnostic='private'}}
   return & $script:SavedRunner @PSBoundParameters
  }
  try {Invoke-MaintenanceApply $c $o $f;throw 'Fault did not fire.'}catch {if(-not $script:PruneBlocked){throw}}
 } finally {Set-Item Function:script:Invoke-NetCrateProcess $saved}
} $context $op $opFile $preview.Candidates
$prior=Read-NetCrateJson $opFile
if($prior.State -cne 'NeedsAttention' -or $prior.Code -cne 'prune-interrupted'){throw 'Verified forget did not journal interrupted prune.'}
$context=Guard
$remaining=& (Get-Module NetCrate.Maintenance) {param($c) Get-MaintenanceInventory $c 1} $context
if(@($remaining.Candidates).Count -ne 0){throw 'Fixture still has a new removal candidate.'}
$expectedHash=(Get-FileHash -LiteralPath "$full/Source/Child/version.txt" -Algorithm SHA256).Hash
$cleanup=& (Get-Module NetCrate.Maintenance) {param($c) New-MaintenancePreview $c 'CompleteCleanup' 0} $context
if(@($cleanup.Candidates).Count -ne 0 -or $cleanup.PriorOperationId -cne $prior.OperationId){throw 'Cleanup preview did not bind the previous forget.'}
$prior.Code='forget-uncertain';Write-NetCrateJson $opFile $prior
$ambiguous=$false;try{& (Get-Module NetCrate.Maintenance) {param($c) New-MaintenancePreview $c 'CompleteCleanup' 0} $context}catch{$ambiguous=$true};if(-not $ambiguous){throw 'An ambiguous forget was accepted for cleanup.'}
$prior.Code='prune-interrupted';Write-NetCrateJson $opFile $prior
$previewFile="$root/Maintenance/Previews/$($cleanup.PreviewId).json";$tampered=Read-NetCrateJson $previewFile;$tampered.Fingerprint='0'*64;Write-NetCrateJson $previewFile $tampered
$stale=$false;try{& (Get-Module NetCrate.Maintenance) {param($c,$p) Test-MaintenancePreview $c $p ([DateTimeOffset]::UtcNow)} $context $cleanup.PreviewId}catch{$stale=$true};if(-not $stale){throw 'A stale cleanup preview was accepted.'};Write-NetCrateJson $previewFile $cleanup
$retry=[pscustomobject]@{Version=1;InstallationId=$id;OperationId=[guid]::NewGuid().ToString('N');Action='ApplyRetention';State='Queued';CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');PreviewId=$cleanup.PreviewId;Confirm=$true}
$retryFile="$root/Maintenance/Requests/$($retry.OperationId).json";Write-NetCrateJson $retryFile $retry
$context=Guard
& (Get-Module NetCrate.Maintenance) {
 param($c,$o,$f)
 $script:SavedRetry=(Get-Command Invoke-NetCrateProcess).ScriptBlock;$script:RetryRepo=$c.Binding.PrimaryPath;$script:RetryPruned=$false
 try {
  function script:Invoke-NetCrateProcess {
   param([string]$FilePath,[string[]]$Arguments,[hashtable]$Environment,[int]$TimeoutSeconds,[string]$OutputFile,[string]$InputText)
   if($Arguments -ccontains 'forget'){throw 'Cleanup repeated forget.'}
   if($Arguments -ccontains 'prune') {if($Arguments.Count -ne 4 -or $Arguments[0] -cne '--repo' -or $Arguments[1] -cne $script:RetryRepo -or $Arguments[2] -cne '--no-cache' -or $Arguments[3] -cne 'prune'){throw 'Unexpected cleanup target or arguments.'};$script:RetryPruned=$true}
   return & $script:SavedRetry @PSBoundParameters
  }
  $script:Quiesced=$false;$script:Resumed=$false
  Invoke-NetCrateMaintenancePass $c.Owner.Root $c.Owner.InstallationId { $script:Quiesced=$true } { $script:Resumed=$true }
  if(-not $script:Quiesced -or -not $script:Resumed){throw 'Cleanup did not quiesce and resume the endpoint.'}
  if(-not $script:RetryPruned){throw 'Cleanup did not invoke native prune.'}
 } finally {Set-Item Function:script:Invoke-NetCrateProcess $script:SavedRetry}
} $context $retry $retryFile
if((Read-NetCrateJson $retryFile).Step -cne 'Completed' -or (Read-NetCrateJson $retryFile).State -cne 'Succeeded'){throw 'Cleanup did not finish.'}
$context=Guard
$replayed=$false;try{& (Get-Module NetCrate.Maintenance) {param($c,$o,$f) Invoke-MaintenanceApply $c $o $f} $context $retry $retryFile}catch{$replayed=$true};if(-not $replayed){throw 'Cleanup replay accepted.'}
$restore="$full/Retained";$null=Invoke-WorkflowRestic $root $settings Primary @('restore',($third.SnapshotId+':'+(Get-NetCrateSnapshotRoot "$full/Source/Child")),'--target',$restore,'--verify')
if((Get-FileHash -LiteralPath "$restore/version.txt" -Algorithm SHA256).Hash -cne $expectedHash){throw 'Retained byte hash changed.'}
Write-Output 'PASS: guarded native forget, interrupted prune, fresh zero-candidate cleanup and retained bytes.'
