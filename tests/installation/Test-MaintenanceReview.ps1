#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference='Stop'
if([IO.Directory]::Exists($TestRoot) -or [IO.File]::Exists($TestRoot)){throw 'TestRoot must not exist.'}
$full=[IO.Path]::GetFullPath($TestRoot)
if($full -notmatch '(?i)[\\/]NC5-[a-f0-9]{8}$'){throw 'Use a unique NC5 fixture root.'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach($name in @('Configuration','Credentials','Maintenance')){Import-Module "$repo/src/shared/NetCrate.$name.psm1"}
Import-Module "$repo/install/NetCrate.Repositories.psm1"
$null=Assert-NetCrateLocalPath $full
$storage=[IO.Path]::Combine($full,'Storage');$source=[IO.Path]::Combine($full,'Files');$root=[IO.Path]::Combine($full,'Engine');$null=New-Item -ItemType Directory -Path $storage,$source
$id='7'*32;$null=New-NetCrateIdentity $root $id Worker;$binding=Initialize-NetCrateRepositories $root $storage $ResticExe
Write-NetCrateJson "$full/fixture.json" @{Version=1;Root=$full;InstallationId=$id;PrimaryId=$binding.PrimaryId;ResultsId=$binding.ResultsId}
$settings=[pscustomobject]@{Version=1;Role='Worker';InstallationId=$id;BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='SERVER';ActiveRoot=$source;StateRoot=$root;Recipe='half-prores-v2';PollSeconds=2;Tools=@{Restic=$ResticExe;PowerShell=(Get-Process -Id $PID).Path;RestServer=$ResticExe;Python=$ResticExe};Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri=$binding.ResultsPath;Id=$binding.ResultsId}}}
Write-NetCrateJson "$root/settings.json" $settings
Write-NetCrateJson "$root/prepared.json" @{Version=1;Role='Worker';InstallationId=$id;Folder=$storage;BackupMode='Folder'}
$prior='2026-01-02T03:04:05Z';Write-NetCrateJson "$root/Maintenance/health.json" @{Version=1;InstallationId=$id;Primary=@{State='Succeeded';Code='ok';LastAttemptUtc=$prior;LastSuccessUtc=$prior};Results=@{State='Succeeded';Code='ok';LastAttemptUtc=$prior;LastSuccessUtc=$prior}}
$inputFile="$full/Setup/action.json";$pwsh=(Get-Process -Id $PID).Path
function Bridge([string]$action,$state){Write-NetCrateJson $inputFile $state;$wire=& $pwsh -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action $action -InputFile $inputFile;return $wire|ConvertFrom-Json}
$base=@{Version=1;Role='BackupServer';InstallationId=$id}
$offline=[IO.Path]::Combine($full,'Storage.offline')
if(-not $storage.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $offline.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture move escaped its root.'}
[IO.Directory]::Move($storage,$offline)
try {
 $status=Bridge StorageStatus $base
 if(-not $status.Succeeded -or -not $status.Maintenance.Health.Primary.LastSuccessUtc -or $status.Maintenance.StorageCode -cne 'unavailable'){throw 'Offline storage hid cached status or its safe reason.'}
 $queued=Bridge CheckStorage $base
 if(-not $queued.Succeeded -or $queued.OperationId -cnotmatch '^[a-f0-9]{32}$'){throw 'Offline check could not be durably requested.'}
 & $pwsh -NoProfile -File "$repo/src/shared/Invoke-NetCrateRuntime.ps1" -Root $root -Once
 $record=Read-NetCrateJson "$root/Maintenance/Requests/$($queued.OperationId).json"
 $status=Bridge StorageStatus $base
 if($record.State -cne 'Failed' -or $status.Maintenance.Health.Primary.State -cne 'Failed' -or ([DateTimeOffset]$status.Maintenance.Health.Primary.LastSuccessUtc).UtcDateTime -ne ([DateTimeOffset]$prior).UtcDateTime){throw 'Offline check did not preserve last success and record failure.'}
 $forged=Bridge PreviewRetention @{Version=1;Role='BackupServer';InstallationId=$id;Policy='KeepLatestPerFolder';Count=1}
 if($forged.Succeeded){throw 'Preview admitted while the repository was unverified.'}
} finally {[IO.Directory]::Move($offline,$storage)}
Write-Output 'PASS: offline status, queued failed check and unverified preview refusal.'

# Inject volume failures in process scope; never alter the host drive or ACL.
foreach($case in @('Permission','Full')){
 $result=& (Get-Module NetCrate.Maintenance) {param($r,$i,$kind)
  $saved=(Get-Command Get-MaintenanceFreeSpace).ScriptBlock
  try {
   if($kind -ceq 'Permission'){function script:Get-MaintenanceFreeSpace {throw [UnauthorizedAccessException]::new('fixture diagnostic')}}
   else {function script:Get-MaintenanceFreeSpace {return 0L}}
   Get-NetCrateMaintenanceStatus $r $i
  } finally {Set-Item Function:script:Get-MaintenanceFreeSpace $saved}
 } $root $id $case
 if($case -ceq 'Permission' -and $result.StorageCode -cne 'permission'){throw 'Permission failure was not shown safely.'}
 if($case -ceq 'Full' -and (-not $result.LowSpace -or $result.FreeBytes -ne 0)){throw 'A full drive did not produce a warning.'}
 if(-not $result.Health.Primary.LastSuccessUtc){throw 'Volume failure erased cached check history.'}
}
Write-Output 'PASS: injected permission and full-volume status without changing the host drive.'
# Inject a failed check at the native boundary; verified config reads still use
# the actual fixture repositories. No raw diagnostic is persisted.
foreach($case in @('Permission','Full','Corrupt')){
 $request=Invoke-NetCrateMaintenanceRequest $root $id CheckStorage @{}
 & (Get-Module NetCrate.Maintenance) {param($r,$i,$kind)
  $savedNative=(Get-Command Invoke-NetCrateProcess).ScriptBlock;$savedFree=(Get-Command Get-MaintenanceFreeSpace).ScriptBlock
  $script:ReviewSavedNative=$savedNative;$script:ReviewCase=$kind
  try {
   function script:Invoke-NetCrateProcess {
    param([string]$FilePath,[string[]]$Arguments,[hashtable]$Environment,[int]$TimeoutSeconds,[string]$OutputFile,[string]$InputText)
    if($Arguments -ccontains 'check'){
     if($script:ReviewCase -ceq 'Permission'){throw [UnauthorizedAccessException]::new('sensitive fixture diagnostic')}
     return [pscustomobject]@{ExitCode=1;Output='';Diagnostic='sensitive fixture diagnostic'}
    }
    & $script:ReviewSavedNative @PSBoundParameters
   }
   if($kind -ceq 'Full'){function script:Get-MaintenanceFreeSpace {return 0L}}
   Invoke-NetCrateMaintenancePass $r $i $null $null
  } finally {Set-Item Function:script:Invoke-NetCrateProcess $savedNative;Set-Item Function:script:Get-MaintenanceFreeSpace $savedFree}
 } $root $id $case
 $failed=Get-NetCrateMaintenanceStatus $root $id
 $expected=if($case -ceq 'Permission'){'permission'}elseif($case -ceq 'Full'){'full'}else{'check-failed'}
 if($failed.Health.Primary.State -cne 'Failed' -or $failed.Health.Primary.Code -cne $expected -or ([DateTimeOffset]$failed.Health.Primary.LastSuccessUtc).UtcDateTime -ne ([DateTimeOffset]$prior).UtcDateTime){throw "Injected $case check did not record a safe failure and preserve success."}
 if([IO.File]::ReadAllText("$root/Maintenance/health.json").Contains('sensitive fixture diagnostic')){throw 'A raw check diagnostic was persisted.'}
}
Write-Output 'PASS: permission, full-volume and corrupt-check failures retain last success without diagnostics.'

# Remove only a fixture config temporarily, then restore it even on failure.
$config=[IO.Path]::Combine($binding.PrimaryPath,'config');$savedConfig=$config+'.fixture-held'
if(-not $config.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture config escaped its root.'}
[IO.File]::Move($config,$savedConfig)
try {
 $status=Bridge StorageStatus $base
 if(-not $status.Succeeded -or -not $status.Maintenance.Health.Primary.LastSuccessUtc){throw 'Unverified repository hid cached history.'}
 $preview=Bridge PreviewRetention @{Version=1;Role='BackupServer';InstallationId=$id;Policy='KeepLatestPerFolder';Count=1}
 if($preview.Succeeded){throw 'A missing repository config was accepted for preview.'}
 [IO.File]::WriteAllText($config,'synthetic corruption')
 $corruptStatus=Bridge StorageStatus $base
 if(-not $corruptStatus.Succeeded -or $corruptStatus.Maintenance.StorageCode -cne 'unverified' -or -not $corruptStatus.Maintenance.Health.Primary.LastSuccessUtc){throw 'A corrupt config did not retain cached history as unverified.'}
 $preview=Bridge PreviewRetention @{Version=1;Role='BackupServer';InstallationId=$id;Policy='KeepLatestPerFolder';Count=1}
 if($preview.Succeeded){throw 'A corrupt repository config was accepted for preview.'}
 [IO.File]::Delete($config)
} finally {if([IO.File]::Exists($config)){[IO.File]::Delete($config)};[IO.File]::Move($savedConfig,$config)}
Write-Output 'PASS: missing fixture config preserved history and blocked preview.'

# Exercise the real worker/status boundary with a simulated oversized inventory.
$queued=Bridge PreviewRetention @{Version=1;Role='BackupServer';InstallationId=$id;Policy='KeepLatestPerFolder';Count=1}
if(-not $queued.Succeeded){throw 'Limit fixture preview did not queue.'}
& (Get-Module NetCrate.Maintenance) {param($r,$i)
 $saved=(Get-Command Get-MaintenanceInventory).ScriptBlock
 try {function script:Get-MaintenanceInventory {Assert-MaintenancePreviewLimit 257 0};Invoke-NetCrateMaintenancePass $r $i $null $null}
 finally {Set-Item Function:script:Get-MaintenanceInventory $saved}
} $root $id
$status=Bridge StorageStatus $base
$limit=@($status.Maintenance.Operations|Where-Object OperationId -CEQ $queued.OperationId)
if($limit.Count -ne 1 -or $limit[0].State -cne 'Failed' -or $limit[0].Code -cne 'preview-limit'){throw 'The 256 limit was lost across runtime and status.'}
Write-Output 'PASS: preview-limit code survives worker and status boundaries.'

# The production selector must choose the same ID when completion timestamps tie.
$tie=& (Get-Module NetCrate.Maintenance) {
 $t=[DateTimeOffset]::Parse('2026-01-01T00:00:00Z');$records=@([pscustomobject]@{Id=('a'*64);Host='SOURCE';Path='/C/Files';Time=$t},[pscustomobject]@{Id=('b'*64);Host='SOURCE';Path='/C/Files';Time=$t})
 $protected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 Select-MaintenanceCandidates $records $protected 1
}
if(@($tie).Count -ne 1 -or @($tie)[0] -cne ('a'*64)){throw 'Equal timestamps were not ordered by full ID deterministically.'}
Write-Output 'PASS: equal completion dates use deterministic ID order.'

# The action process has already exited before a separate worker process drains it.
$queued=Bridge CheckStorage $base
$helper="$full/drain.ps1"
@"
param(`$Root,`$Id,`$Module)
Import-Module `$Module
Invoke-NetCrateMaintenancePass `$Root `$Id `$null `$null
"@|Set-Content -Encoding utf8 $helper
& $pwsh -NoProfile -File $helper -Root $root -Id $id -Module "$repo/src/shared/NetCrate.Maintenance.psm1"
if($LASTEXITCODE -ne 0){throw 'Separate worker fixture failed.'}
$done=Read-NetCrateJson "$root/Maintenance/Requests/$($queued.OperationId).json"
if($done.State -cne 'Succeeded'){throw 'The durable request was lost after the foreground action exited.'}
Write-Output 'PASS: durable check completed after foreground action exited.'
