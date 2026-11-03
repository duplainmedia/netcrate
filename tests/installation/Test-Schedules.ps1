#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/../../src/shared/NetCrate.Workflow.psm1" -Force
Import-Module "$PSScriptRoot/../../src/shared/NetCrate.Configuration.psm1"
$null=[IO.Directory]::CreateDirectory($TestRoot)
$active=Join-Path $TestRoot 'Files';$null=[IO.Directory]::CreateDirectory($active)
$settings=[pscustomobject]@{BackupMode='Folder';ActiveRoot=$active;StateRoot=(Join-Path $TestRoot 'Engine');InstallationId=('a'*32)}
Import-Module "$PSScriptRoot/../../src/shared/NetCrate.Credentials.psm1"
$null=New-NetCrateIdentity $settings.StateRoot $settings.InstallationId Source
$zone=[TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$script:checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function Save($Name,$Time,$Now){$p=Join-Path $active $Name;$null=[IO.Directory]::CreateDirectory($p);Save-NetCrateSchedule $settings.StateRoot $settings $p $Time $true ([DateTimeOffset]$Now) $zone}
function Tick($Now){Invoke-NetCrateSchedules $settings.StateRoot $settings ([DateTimeOffset]$Now) $zone}
function Jobs{ @(Get-ChildItem -LiteralPath (Join-Path $settings.StateRoot 'Queue') -Filter '*.json' -ErrorAction SilentlyContinue|ForEach-Object {Read-NetCrateJson $_.FullName}) }
Check ([bool](Get-Command Save-NetCrateSchedule -ErrorAction SilentlyContinue)) 'Missing daily schedule persistence and admission behavior.'
$s=Save 'Before' '10:00' '2026-02-01T14:00:00Z'
Check ($s.NextDueUtc -eq '2026-02-01T15:00:00.0000000+00:00') 'Before-time creation skipped today.'
Tick '2026-02-01T14:59:00Z';Check ((Jobs).Count -eq 0) 'Ran before first due time.'
Tick '2026-02-05T16:00:00Z';Check ((Jobs).Count -eq 1) 'Missed days did not catch up once.'
$record=Get-NetCrateSchedules $settings.StateRoot ([DateTimeOffset]'2026-02-05T16:00:00Z') $zone|Select-Object -First 1
Check ($record.LastOccurrence -eq '2026-02-05') 'Did not consume latest local date.'
Tick '2026-02-05T17:00:00Z';Tick '2026-02-03T16:00:00Z';Check ((Jobs).Count -eq 1) 'Replayed consumed occurrence on tick/rollback.'
$file=Join-Path $settings.StateRoot ('Queue/'+(Jobs)[0].Id+'.json');$job=Read-NetCrateJson $file;$job.SnapshotId='b'*64;$job.BackupCompletedUtc='2026-02-05T16:01:00Z';$job.ReceiptConfirmed=$true;$job.State='WaitingForProxies';Write-NetCrateJson $file $job
$manual=Add-NetCrateBackupQueue $settings.StateRoot $settings $s.Project
Check ((Jobs).Count -eq 2) 'Media pending prevented a new original.'
$again=Add-NetCrateBackupQueue $settings.StateRoot $settings $s.Project
Check ($again -eq $manual) 'Concurrent manual admission duplicated active originals.'
Tick '2026-02-06T16:00:00Z';Check ((Jobs).Count -eq 2) 'Scheduled admission duplicated active manual originals.'
$occ=Get-ChildItem (Join-Path $settings.StateRoot 'ScheduleOccurrences') -Filter '*.json'|ForEach-Object {Read-NetCrateJson $_.FullName}|Where-Object {$_.LocalDate -eq '2026-02-06'}
Check ($occ.JobId -eq [IO.Path]::GetFileNameWithoutExtension($manual)) 'Occurrence did not durably bind to the existing job.'
# Simulate crash after association, before cursor write; completed job must not be re-enqueued.
$job=Read-NetCrateJson $manual;$job.State='Ready';$job.ReceiptConfirmed=$true;$job.SnapshotId='c'*64;$job.BackupCompletedUtc='2026-02-06T16:01:00Z';Write-NetCrateJson $manual $job
$sp=Join-Path $settings.StateRoot ('Schedules/'+$s.Id+'.json');$r=Read-NetCrateJson $sp;$r.LastOccurrence='2026-02-05';Write-NetCrateJson $sp $r
Tick '2026-02-06T17:00:00Z';Check ((Jobs).Count -eq 2) 'Replayed admission after cursor crash.'
$edit=Save 'Before' '11:30' '2026-02-06T17:00:00Z';Check ($edit.Id -eq $s.Id -and $edit.Revision -eq 2) 'Edit changed identity or lost revision.'
$case=Save-NetCrateSchedule $settings.StateRoot $settings $s.Project.ToUpperInvariant() '11:45' $true ([DateTimeOffset]'2026-02-06T17:00:00Z') $zone
Check ($case.Id -eq $s.Id -and $case.Revision -eq 3) 'Case-insensitive canonical folder created a duplicate schedule.'
Disable-NetCrateSchedule $settings.StateRoot $settings $s.Project|Out-Null
Import-Module "$PSScriptRoot/../../src/shared/NetCrate.Workflow.psm1" -Force
Tick '2026-02-20T17:00:00Z';Check ((Jobs).Count -eq 2) 'Disabled schedule ran after restart.'
$after=Save 'After' '10:00' '2026-02-01T16:00:00Z';Check ($after.NextDueUtc.StartsWith('2026-02-02T15:00')) 'After-time creation replayed today.'
$gap=Save 'Gap' '02:30' '2026-03-07T18:00:00Z';$gapNext=Get-NetCrateScheduleOccurrence ([DateTime]'2026-03-08') '02:30' $zone
Check ($gapNext -eq [DateTimeOffset]'2026-03-08T07:00:00Z') 'Skipped spring minute did not run at next valid minute.'
$fold=Get-NetCrateScheduleOccurrence ([DateTime]'2026-11-01') '01:30' $zone
Check ($fold -eq [DateTimeOffset]'2026-11-01T05:30:00Z') 'Repeated hour did not choose first occurrence.'
$fall=Save 'Fall' '01:30' '2026-10-31T18:00:00Z';Tick '2026-11-01T05:30:00Z';$count=(Jobs).Count;Tick '2026-11-01T06:30:00Z';Check ((Jobs).Count -eq $count) 'Repeated hour enqueued twice.'
$utc=[TimeZoneInfo]::Utc;Invoke-NetCrateSchedules $settings.StateRoot $settings ([DateTimeOffset]'2026-11-01T08:00:00Z') $utc;Check ((Jobs).Count -eq $count) 'Timezone change replayed consumed local date.'
$lost=Save 'Lost' '10:00' '2026-12-01T12:00:00Z';[IO.Directory]::Delete($lost.Project);Tick '2026-12-02T16:00:00Z'
$lost=Get-NetCrateSchedules $settings.StateRoot ([DateTimeOffset]'2026-12-02T16:00:00Z') $zone|Where-Object Id -eq $lost.Id
Check ($lost.Status -eq 'Folder unavailable' -and -not $lost.LastOccurrence) 'Unavailable folder was consumed or hid attention.'
$other=Get-NetCrateSchedules $settings.StateRoot ([DateTimeOffset]'2026-12-02T16:00:00Z') $zone|Where-Object Id -eq $after.Id
Check ($other.LastOccurrence -eq '2026-12-02') 'Unavailable folder blocked other schedules.'
# Real action bridge validates source identity and returns schedules separately from Restore Items.
$ps=(Get-Process -Id $PID).Path
$bridge=[pscustomobject]@{Version=1;Role='Source';InstallationId=$settings.InstallationId;BackupMode='Folder';ActiveRoot=$active;StateRoot=$settings.StateRoot;SourceComputer='SOURCE';WorkerComputer='SERVER';PollSeconds=2;Recipe='half-prores-v2';Tools=@{PowerShell=$ps;Restic=$ps};Repositories=@{Primary=@{Uri='rest:https://backup.example:8200/editing/originals/';Id=('a'*64)};Results=@{Uri='rest:https://backup.example:8200/editing/results/';Id=('b'*64)}}}
Write-NetCrateJson (Join-Path $settings.StateRoot 'settings.json') $bridge
Write-NetCrateJson (Join-Path $settings.StateRoot 'prepared.json') @{Version=1;Role='Source';InstallationId=$settings.InstallationId;Folder=$active;BackupMode='Folder'}
$inputFile=Join-Path $TestRoot 'Setup/action.json'
$inputState=@{Version=1;Role='EditingComputer';InstallationId=$settings.InstallationId;Folder=$active;BackupMode='Folder';Path=$after.Project;TimeOfDay='11:42';Enabled=$true}
function Action($Name){Write-NetCrateJson $inputFile $inputState; (& $ps -NoProfile -File "$PSScriptRoot/../../install/Invoke-SetupAction.ps1" -Action $Name -InputFile $inputFile)|ConvertFrom-Json}
$result=Action SaveSchedule;Check ($result.Succeeded -and @($result.Schedules).Count -gt 0) 'SaveSchedule bridge action missing.'
$result=Action ListSchedules;Check ($result.Succeeded -and $result.Schedules[0].TimeZone -and $result.PSObject.Properties.Name -notcontains 'Items') 'Schedule bridge broke typed Restore items.'
$inputState.InstallationId='f'*32;$result=Action SaveSchedule;Check (-not $result.Succeeded) 'Schedule bridge accepted another installation.'
$inputState.InstallationId=$settings.InstallationId;$inputState.TimeOfDay='25:00';$result=Action SaveSchedule;Check (-not $result.Succeeded) 'Schedule bridge accepted invalid daily time.'
$inputState.TimeOfDay='11:42';$inputState.Role='BackupServer';$result=Action SaveSchedule;Check (-not $result.Succeeded) 'Worker created a source schedule.'
$inputState.Role='EditingComputer';$result=Action DisableSchedule;Check $result.Succeeded 'DisableSchedule bridge action missing.'
# Crash after durable assignment but before job creation: a manual start must use the reservation.
$reserved=Join-Path $active 'Reserved';$null=[IO.Directory]::CreateDirectory($reserved)
$reservedId='d'*64
Write-NetCrateJson (Join-Path $settings.StateRoot 'ScheduleOccurrences/reserved.json') @{Version=1;OccurrenceId='reserved';LocalDate='2026-12-02';JobId=$reservedId;Project=$reserved}
$reservedFile=Add-NetCrateBackupQueue $settings.StateRoot $settings $reserved
Check ([IO.Path]::GetFileNameWithoutExtension($reservedFile) -eq $reservedId) 'Manual admission ignored an interrupted durable scheduled assignment.'
# A completed originals read awaiting its receipt cannot satisfy a later request.
$pendingPath=Join-Path $active 'PendingReceipt';$null=[IO.Directory]::CreateDirectory($pendingPath)
$monday=Add-NetCrateBackupQueue $settings.StateRoot $settings $pendingPath
$mondayRecord=Read-NetCrateJson $monday;$mondayRecord.SnapshotId='7'*64;$mondayRecord.ReceiptConfirmed=$false;$mondayRecord.State='NeedsAttention';Write-NetCrateJson $monday $mondayRecord
$tuesday=Add-NetCrateBackupQueue $settings.StateRoot $settings $pendingPath -OccurrenceId 'tuesday-fixture' -LocalDate '2026-11-03'
Check ($tuesday -cne $monday) 'Later scheduled occurrence reused a prior immutable originals read.'
Check ((Add-NetCrateBackupQueue $settings.StateRoot $settings $pendingPath -OccurrenceId 'tuesday-fixture' -LocalDate '2026-11-03') -ceq $tuesday) 'Occurrence replay did not retain its assigned job.'
$manualPath=Join-Path $active 'ManualPendingReceipt';$null=[IO.Directory]::CreateDirectory($manualPath)
$olderManual=Add-NetCrateBackupQueue $settings.StateRoot $settings $manualPath
$oldManual=Read-NetCrateJson $olderManual;$oldManual.SnapshotId='8'*64;$oldManual.ReceiptConfirmed=$false;$oldManual.State='NeedsAttention';Write-NetCrateJson $olderManual $oldManual
$newManual=Add-NetCrateBackupQueue $settings.StateRoot $settings $manualPath
Check ($newManual -cne $olderManual) 'Later manual request reused a prior immutable originals read.'
# Four processes contend on one installation: manual/manual/schedule/schedule.
$concurrent=Join-Path $TestRoot 'Concurrent';$p=Join-Path $active 'Concurrent';$null=[IO.Directory]::CreateDirectory($p)
$cs=$settings.PSObject.Copy();$cs.StateRoot=$concurrent
$null=New-NetCrateIdentity $concurrent $cs.InstallationId Source
$null=Save-NetCrateSchedule $concurrent $cs $p '10:00' $true ([DateTimeOffset]'2026-01-01T12:00:00Z') $zone
Write-NetCrateJson (Join-Path $concurrent 'settings-fixture.json') $cs
$scriptFile=Join-Path $concurrent 'tick.ps1'
[IO.File]::WriteAllText($scriptFile,@'
param($Module,$Root,$Mode,$Project)
$ErrorActionPreference='Stop'
Import-Module $Module
Import-Module ([IO.Path]::Combine([IO.Path]::GetDirectoryName($Module),'NetCrate.Configuration.psm1'))
$s=Read-NetCrateJson ([IO.Path]::Combine($Root,'settings-fixture.json'))
if($Mode -eq 'drain') {
 & (Get-Module NetCrate.Workflow) {
  param($Root,$s)
  function script:Invoke-NetCrateOriginals {
   param($Root,$Settings,$Project,$Checkpoint,$BackupMode)
   [IO.File]::WriteAllText([IO.Path]::Combine($Root,'backup-entered'),'running')
   $deadline=[DateTime]::UtcNow.AddSeconds(20)
   while(-not [IO.File]::Exists([IO.Path]::Combine($Root,'backup-release'))){if([DateTime]::UtcNow -gt $deadline){throw 'Fixture release timeout.'};Start-Sleep -Milliseconds 20}
   $j=Read-NetCrateJson $Checkpoint;$j.SnapshotId='e'*64;$j.BackupCompletedUtc='2026-01-02T16:01:00Z';Write-NetCrateJson $Checkpoint $j;return $j
  }
  Invoke-NetCrateQueue $Root $s
 } $Root $s
}
elseif($Mode -eq 'manual') { Add-NetCrateBackupQueue $Root $s $Project|Out-Null }
else { Invoke-NetCrateSchedules $Root $s ([DateTimeOffset]'2026-01-02T16:00:00Z') ([TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')) }
'@)
$processes=@();foreach($kind in @('manual','schedule','manual','schedule')){
 $start=[Diagnostics.ProcessStartInfo]::new($ps);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 foreach($arg in @('-NoProfile','-File',$scriptFile,([IO.Path]::GetFullPath("$PSScriptRoot/../../src/shared/NetCrate.Workflow.psm1")),$concurrent,$kind,$p)){$start.ArgumentList.Add($arg)}
 $processes+= [Diagnostics.Process]::Start($start)
}
foreach($process in $processes){Check ($process.WaitForExit(30000) -and $process.ExitCode -eq 0) 'Concurrent admission process failed.';$process.Dispose()}
$cj=@(Get-ChildItem (Join-Path $concurrent 'Queue') -Filter '*.json');Check ($cj.Count -eq 1) 'Concurrent manual/scheduled admissions duplicated originals.'
$co=@(Get-ChildItem (Join-Path $concurrent 'ScheduleOccurrences') -Filter '*.json'|ForEach-Object {Read-NetCrateJson $_.FullName});Check ($co.Count -eq 1 -and $co[0].JobId -eq $cj[0].BaseName) 'Concurrent scheduled occurrence lost its stable job binding.'
# Hold a fake backup in the native drain process; admission must remain available.
$start=[Diagnostics.ProcessStartInfo]::new($ps);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
foreach($arg in @('-NoProfile','-File',$scriptFile,([IO.Path]::GetFullPath("$PSScriptRoot/../../src/shared/NetCrate.Workflow.psm1")),$concurrent,'drain',$p)){$start.ArgumentList.Add($arg)}
$drain=[Diagnostics.Process]::Start($start)
$deadline=[DateTime]::UtcNow.AddSeconds(15);while(-not [IO.File]::Exists((Join-Path $concurrent 'backup-entered'))){if([DateTime]::UtcNow -gt $deadline){throw 'Backup fixture did not enter processing.'};Start-Sleep -Milliseconds 20}
try {
 $timer=[Diagnostics.Stopwatch]::StartNew();$same=Add-NetCrateBackupQueue $concurrent $cs $p
 $child=Join-Path $p 'Child';$null=[IO.Directory]::CreateDirectory($child);$null=Add-NetCrateBackupQueue $concurrent $cs $child
 Check ($timer.Elapsed.TotalSeconds -lt 5 -and [IO.Path]::GetFileNameWithoutExtension($same) -eq $cj[0].BaseName) 'Admission lock was held across backup work or duplicated the running original.'
} finally {[IO.File]::WriteAllText((Join-Path $concurrent 'backup-release'),'continue')}
Check ($drain.WaitForExit(30000) -and $drain.ExitCode -eq 0) 'Queue drain fixture failed.';$drain.Dispose()
& "$PSScriptRoot/Test-ScheduleReview.ps1" -TestRoot (Join-Path $TestRoot 'Review')
& "$PSScriptRoot/Test-ScheduleRuntimeAttention.ps1" -TestRoot (Join-Path $TestRoot 'RuntimeAttention')
Write-Output "PASS: $script:checks schedule assertions."
