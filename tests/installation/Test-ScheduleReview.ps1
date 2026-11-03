#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot,[ValidateSet('All','Zone','Pending','Errors')][string]$Case='All')
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/../../src/shared/NetCrate.Workflow.psm1" -Force
Import-Module "$PSScriptRoot/../../src/shared/NetCrate.Configuration.psm1"
$null=[IO.Directory]::CreateDirectory($TestRoot)
$script:n=0
function Check($value,$message){if(-not $value){throw $message};$script:n++}
$active=Join-Path $TestRoot 'Files';$null=[IO.Directory]::CreateDirectory($active)
$settings=[pscustomobject]@{BackupMode='Folder';ActiveRoot=$active;StateRoot=(Join-Path $TestRoot 'Engine');InstallationId=('a'*32)}
Import-Module "$PSScriptRoot/../../src/shared/NetCrate.Credentials.psm1"
$null=New-NetCrateIdentity $settings.StateRoot $settings.InstallationId Source
$east=[TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
function Save($name){$p=Join-Path $active $name;$null=[IO.Directory]::CreateDirectory($p);Save-NetCrateSchedule $settings.StateRoot $settings $p '10:00' $true ([DateTimeOffset]'2026-01-01T12:00:00Z') $east}
function Find($id){Get-NetCrateSchedules $settings.StateRoot ([DateTimeOffset]'2026-01-02T16:00:00Z') $east|Where-Object Id -eq $id}
if($Case -in @('All','Zone')){
 $old=[TimeZoneInfo]::Local
 $null=Invoke-NetCrateSchedules (Join-Path $TestRoot 'Empty') $settings ([DateTimeOffset]'2026-01-02T14:00:00Z')
 Check (-not [object]::ReferenceEquals($old,[TimeZoneInfo]::Local)) 'Default runtime pass retained the cached local time-zone instance.'
 $s=Save 'Zone'
 & (Get-Module NetCrate.Workflow) {
  param($root,$settings,$east,$id)
  $saved=(Get-Command Get-NetCrateScheduleLocalZone).ScriptBlock
  try {
   $script:fixtureZone=$east
   function script:Get-NetCrateScheduleLocalZone { return $script:fixtureZone }
   $null=Invoke-NetCrateSchedules $root $settings ([DateTimeOffset]'2026-01-02T14:00:00Z')
   $first=Read-NetCrateJson ([IO.Path]::Combine($root,'Schedules',$id+'.json'))
   if($first.LastOccurrence -ne '2026-01-01'){throw 'Default runtime path ignored first zone provider.'}
   $script:fixtureZone=[TimeZoneInfo]::Utc
   $null=Invoke-NetCrateSchedules $root $settings ([DateTimeOffset]'2026-01-02T14:00:00Z')
   $second=Read-NetCrateJson ([IO.Path]::Combine($root,'Schedules',$id+'.json'))
   if($second.LastOccurrence -ne '2026-01-02'){throw 'Default runtime path failed to refresh the changed zone provider.'}
   $view=Get-NetCrateSchedules $root ([DateTimeOffset]'2026-01-02T14:00:00Z')|Where-Object Id -eq $id
   if($view.TimeZone -ne 'UTC'){throw 'Schedule bridge display retained the old default zone.'}
  } finally {Set-Item Function:script:Get-NetCrateScheduleLocalZone $saved;Remove-Variable fixtureZone -Scope Script}
 } $settings.StateRoot $settings $east $s.Id
 $script:n+=3
}
if($Case -in @('All','Pending')){
 $s=Save 'Pending';$view=Find $s.Id
 Check ($view.NextDueUtc.StartsWith('2026-01-02T15:00') -and $view.CatchUpPending) 'Overdue unconsumed occurrence was displayed as a future run.'
 $null=Invoke-NetCrateSchedules $settings.StateRoot $settings ([DateTimeOffset]'2026-01-02T16:00:00Z') $east
 $view=Find $s.Id;Check ($view.NextDueUtc.StartsWith('2026-01-03T15:00') -and -not $view.CatchUpPending) 'Consumed occurrence still displayed as pending.'
 $lost=Save 'Disconnected';[IO.Directory]::Delete($lost.Project)
 $null=Invoke-NetCrateSchedules $settings.StateRoot $settings ([DateTimeOffset]'2026-01-02T16:00:00Z') $east
 $view=Find $lost.Id;Check ($view.CatchUpPending -and $view.NextDueUtc.StartsWith('2026-01-02T15:00') -and $view.Status -eq 'Folder unavailable') 'Disconnected folder hid its pending catch-up.'
 $null=[IO.Directory]::CreateDirectory($lost.Project)
 $null=Invoke-NetCrateSchedules $settings.StateRoot $settings ([DateTimeOffset]'2026-01-02T16:00:00Z') $east
 $view=Find $lost.Id;Check (-not $view.CatchUpPending -and $view.NextDueUtc.StartsWith('2026-01-03T15:00')) 'Reconnected folder did not advance after durable admission.'
}
if($Case -in @('All','Errors')){
 $bad=Save 'Fault';$good=Save 'Independent'
 & (Get-Module NetCrate.Workflow) {
  param($root,$settings,$east,$badProject)
  $saved=(Get-Command Add-NetCrateBackupQueue).ScriptBlock
  try {
   $script:badProject=$badProject;$script:realAdmission=$saved;$script:storageFault=$false
   function script:Add-NetCrateBackupQueue {
    param($Root,$Settings,$Project,$OccurrenceId,$LocalDate,$Now)
    if($Project -eq $script:badProject){if($script:storageFault){throw [IO.IOException]::new('Generated storage-write failure.')};throw [UnauthorizedAccessException]::new('Generated admission denial.')}
    & $script:realAdmission $Root $Settings $Project -OccurrenceId $OccurrenceId -LocalDate $LocalDate -Now $Now
   }
   $result=Invoke-NetCrateSchedules $root $settings ([DateTimeOffset]'2026-01-02T16:00:00Z') $east
   if(-not $result -or -not $result.NeedsAttention -or $result.Message -notlike '*access*'){throw 'Admission access failure was swallowed instead of surfacing scheduler attention.'}
   $script:storageFault=$true
   $result=Invoke-NetCrateSchedules $root $settings ([DateTimeOffset]'2026-01-02T16:00:00Z') $east
   if(-not $result.NeedsAttention -or $result.Message -notlike '*free space*' -or $result.Message -like '*Generated*'){throw 'Storage failure was swallowed or exposed raw diagnostics.'}
  } finally {Set-Item Function:script:Add-NetCrateBackupQueue $saved;Remove-Variable badProject,realAdmission,storageFault -Scope Script}
 } $settings.StateRoot $settings $east $bad.Project
 $script:n+=2
 $view=Find $bad.Id;Check ($view.Status -like 'Scheduling needs attention*' -and -not $view.LastOccurrence) 'Access failure was mislabeled as a missing folder or consumed.'
 $view=Find $good.Id;Check ($view.LastOccurrence -eq '2026-01-02') 'Admission error blocked an independent schedule.'
 $corrupt=Save 'CorruptQueue';[IO.File]::WriteAllText((Join-Path $settings.StateRoot 'Queue/broken.json'),'{ broken')
 $result=Invoke-NetCrateSchedules $settings.StateRoot $settings ([DateTimeOffset]'2026-01-02T16:00:00Z') $east
 Check ($result.NeedsAttention -and (Find $corrupt.Id).Status -like 'Scheduling needs attention*') 'Corrupt queue was disguised as folder unavailability.'
 # Exercise the real existing owner runtime, with no paired credentials or real
 # repository. Queue corruption must preserve the scheduler code in its status.
 $ps=(Get-Process -Id $PID).Path
 Write-NetCrateJson (Join-Path $settings.StateRoot 'settings.json') @{Version=1;Role='Source';InstallationId=$settings.InstallationId;BackupMode='Folder';ActiveRoot=$active;StateRoot=$settings.StateRoot;SourceComputer='SOURCE';WorkerComputer='SERVER';PollSeconds=2;Recipe='half-prores-v2';Tools=@{PowerShell=$ps;Restic=$ps};Repositories=@{Primary=@{Uri='rest:https://backup.example:8200/editing/originals/';Id=('a'*64)};Results=@{Uri='rest:https://backup.example:8200/editing/results/';Id=('b'*64)}}}
 & $ps -NoProfile -File "$PSScriptRoot/../../src/shared/Invoke-NetCrateRuntime.ps1" -Root $settings.StateRoot -Once
 Check ($LASTEXITCODE -eq 0) 'Disposable owner runtime did not finish its single pass.'
 $runtime=Read-NetCrateJson (Join-Path $settings.StateRoot 'runtime-status.json')
 Check ($runtime.State -eq 'NeedsAttention' -and $runtime.Code -eq 'schedule-admission' -and $runtime.Message -like '*queue records*') 'Existing owner runtime lost actionable scheduling attention.'
}
Write-Output "PASS: $script:n schedule review regression assertions ($Case)."
