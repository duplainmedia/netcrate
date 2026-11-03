#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath("$PSScriptRoot/../..")
Import-Module "$repo/src/shared/NetCrate.Configuration.psm1"
Import-Module "$repo/src/shared/NetCrate.Credentials.psm1"
$root=Join-Path $TestRoot 'Engine';$active=Join-Path $TestRoot 'Files';$null=[IO.Directory]::CreateDirectory($active)
$null=New-NetCrateIdentity $root ('a'*32) Source
$ps=(Get-Process -Id $PID).Path
Write-NetCrateJson (Join-Path $root 'settings.json') @{Version=1;Role='Source';InstallationId=('a'*32);BackupMode='Folder';ActiveRoot=$active;StateRoot=$root;SourceComputer='SOURCE';WorkerComputer='SERVER';PollSeconds=2;Recipe='half-prores-v2';Tools=@{PowerShell=$ps;Restic=$ps};Repositories=@{Primary=@{Uri='rest:https://backup.example:8200/editing/originals/';Id=('a'*64)};Results=@{Uri='rest:https://backup.example:8200/editing/results/';Id=('b'*64)}}}
$statusFile=Join-Path $root 'runtime-status.json'
Write-NetCrateJson $statusFile @{State='NeedsAttention';Code='schedule-admission';Message='Prior scheduling attention.';ProcessId=$PID;ProcessStartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
$harness=Join-Path $TestRoot 'hold-runtime.ps1'
[IO.File]::WriteAllText($harness,@'
param($Root,$Repo)
$ErrorActionPreference='Stop'
Import-Module "$Repo/src/shared/NetCrate.Workflow.psm1"
& (Get-Module NetCrate.Workflow) {
 function script:Invoke-NetCrateSchedules {
  param($Root,$Settings)
  [IO.File]::WriteAllText((Join-Path $Root 'evaluation-entered'),'entered')
  $deadline=[DateTime]::UtcNow.AddSeconds(20)
  while(-not [IO.File]::Exists((Join-Path $Root 'evaluation-release'))){if([DateTime]::UtcNow -gt $deadline){throw 'Fixture evaluation timeout.'};Start-Sleep -Milliseconds 20}
  if(-not [IO.File]::Exists((Join-Path $Root 'healthy'))){return [pscustomobject]@{NeedsAttention=$true;Code='schedule-admission';Message='Automatic backups need attention. Check state-folder access and queue records.'}}
 }
 function script:Invoke-NetCrateQueue {
  param($Root,$Settings)
  [IO.File]::WriteAllText((Join-Path $Root 'backup-entered'),'entered')
  $deadline=[DateTime]::UtcNow.AddSeconds(20)
  while(-not [IO.File]::Exists((Join-Path $Root 'backup-release'))){if([DateTime]::UtcNow -gt $deadline){throw 'Fixture backup timeout.'};Start-Sleep -Milliseconds 20}
 }
 function script:Update-NetCrateQueue {param($Root,$Settings)}
 Export-ModuleMember -Function Invoke-NetCrateSchedules,Invoke-NetCrateQueue,Update-NetCrateQueue
}
& "$Repo/src/shared/Invoke-NetCrateRuntime.ps1" -Root $Root -Once
'@)
$failures=[Collections.Generic.List[string]]::new();$script:checks=0
function Check($value,$message){$script:checks++;if(-not $value){$failures.Add($message)}}
function WaitMarker($name,$process){$deadline=[DateTime]::UtcNow.AddSeconds(15);while(-not [IO.File]::Exists((Join-Path $root $name))){if($process.HasExited){throw ('Runtime fixture exited before '+$name+': '+$process.StandardError.ReadToEnd())};if([DateTime]::UtcNow -gt $deadline){throw ('Runtime fixture did not reach '+$name)};Start-Sleep -Milliseconds 20}}
function StartHeld {
 $start=[Diagnostics.ProcessStartInfo]::new($ps);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in @('-NoProfile','-File',$harness,$root,$repo)){$start.ArgumentList.Add($arg)}
 return [Diagnostics.Process]::Start($start)
}
$child=StartHeld
try {
 WaitMarker 'evaluation-entered' $child
 $status=Read-NetCrateJson $statusFile
 Check ($status.State -eq 'NeedsAttention' -and $status.Code -eq 'schedule-admission') 'Pass start erased prior scheduling attention before reevaluation.'
 $contenderStart=[Diagnostics.ProcessStartInfo]::new($ps);$contenderStart.UseShellExecute=$false;$contenderStart.CreateNoWindow=$true
 foreach($arg in @('-NoProfile','-File',"$repo/src/shared/Invoke-NetCrateRuntime.ps1",'-Root',$root,'-Once')){$contenderStart.ArgumentList.Add($arg)}
 $contender=[Diagnostics.Process]::Start($contenderStart)
 try {Check ($contender.WaitForExit(10000) -and $contender.ExitCode -eq 0 -and (Read-NetCrateJson $statusFile).ProcessId -eq $child.Id) 'A second source runtime acquired ownership while the first was held.'} finally {if(-not $contender.HasExited){$contender.Kill();$contender.WaitForExit()};$contender.Dispose()}
 [IO.File]::WriteAllText((Join-Path $root 'evaluation-release'),'continue')
 WaitMarker 'backup-entered' $child
 $status=Read-NetCrateJson $statusFile
 Check ($status.State -eq 'NeedsAttention' -and $status.Code -eq 'schedule-admission' -and $status.Message -like '*queue records*') 'Scheduling attention was not durable before held backup work.'
 $child.Kill();$null=$child.WaitForExit(10000)
 $status=Read-NetCrateJson $statusFile
 Check ($status.State -eq 'NeedsAttention' -and $status.Code -eq 'schedule-admission') 'Interrupted backup left scheduling attention hidden.'
} finally {if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(10000)};$child.Dispose()}
foreach($name in @('evaluation-entered','evaluation-release','backup-entered')){[IO.File]::Delete((Join-Path $root $name))}
[IO.File]::WriteAllText((Join-Path $root 'healthy'),'healthy')
$child=StartHeld
try {
 WaitMarker 'evaluation-entered' $child
 $status=Read-NetCrateJson $statusFile
 Check ($status.State -eq 'NeedsAttention' -and $status.Code -eq 'schedule-admission') 'Runtime restart erased scheduling attention before reevaluation.'
 [IO.File]::WriteAllText((Join-Path $root 'evaluation-release'),'continue')
 WaitMarker 'backup-entered' $child
 $status=Read-NetCrateJson $statusFile
 Check ($status.State -eq 'Running' -and -not $status.Code) 'Healthy reevaluation did not clear attention before independent backup work.'
 [IO.File]::WriteAllText((Join-Path $root 'backup-release'),'continue')
 Check ($child.WaitForExit(10000) -and $child.ExitCode -eq 0) 'Healthy held runtime did not finish.'
} finally {if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(10000)};$child.Dispose()}
if($failures.Count){throw ($failures -join ' | ')}
Write-Output "PASS: $script:checks runtime attention assertions observed during evaluation, held backup, interruption and restart."
