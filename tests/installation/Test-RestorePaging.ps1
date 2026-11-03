param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$module=Import-Module "$repo/src/shared/NetCrate.Restore.psm1" -PassThru
& $module {
 $script:RealNative=(Get-Command Invoke-RestoreNative).ScriptBlock
 $script:FixtureSnapshots=@();$script:FixtureReceipts=@{};$script:DumpCount=0;$script:SelectedQuery=$false
 for($i=1;$i -le 120;$i++) {
  $id=$i.ToString('x64');$rid=($i+1000).ToString('x64');$project='Z:\Missing\Project'+$i
  $date=([DateTimeOffset]'2024-01-01T00:00:00Z').AddMinutes($i).ToString('o')
  $script:FixtureSnapshots+=@{id=$id;hostname='OLD';paths=@($project);time=$date;tags=@('netcrate-v2-originals','netcrate-folder-originals')}
  $script:FixtureSnapshots+=@{id=$rid;hostname='OLD';paths=@("Z:\Missing\Engine\BackupReceipts\$id.json");time=$date;tags=@('netcrate-backup-receipt',"netcrate-receipt-$id")}
  $script:FixtureReceipts[$rid]=@{Version=1;Kind='backup-receipt';RepositoryId=('f'*64);SourceComputer='OLD';Project=$project;SnapshotId=$id;BackupMode='Folder';JobId=('job'+$i);BackupCompletedUtc=$date}
 }
 function script:New-RestoreContext {return [pscustomobject]@{Id=('f'*64);HostName='';ActiveRoot='';Environment=@{}}}
 function script:Invoke-RestoreNative($Context,[string[]]$Arguments) {
  switch($Arguments[0]) {
   snapshots {
    $items=$script:FixtureSnapshots
    $tag=[Array]::IndexOf($Arguments,'--tag')
    if($tag -ge 0){$items=@($items|Where-Object {$_.tags -ccontains $Arguments[$tag+1]})}
    elseif($Arguments[-1] -cmatch '^[a-f0-9]{64}$'){$script:SelectedQuery=$true;$items=@($items|Where-Object id -CEQ $Arguments[-1])}
    return ConvertTo-Json -InputObject @($items) -Depth 8 -Compress
   }
   dump {$script:DumpCount++;return $script:FixtureReceipts[$Arguments[1]]|ConvertTo-Json -Compress}
   cat {return '{"nodes":[]}'}
  }
 }
}
$first=Invoke-NetCrateRestoreAction ListBackups ([pscustomobject]@{Version=1}) 'C:\fixture' 'C:\restic.exe'
$count=& $module {$script:DumpCount}
if($count -gt 50 -or @($first.Items).Count -gt 50 -or -not $first.NextCursor){throw 'The first browse page scanned receipts outside its bounded candidate page.'}
$next=Invoke-NetCrateRestoreAction ListBackups ([pscustomobject]@{Cursor=$first.NextCursor}) 'C:\fixture' 'C:\restic.exe'
if(@($next.Items|Where-Object {$_.SnapshotId -cin $first.Items.SnapshotId}).Count){throw 'Candidate paging repeated a prior snapshot.'}
& $module {$script:DumpCount=0}
$children=Invoke-NetCrateRestoreAction ListBackupChildren ([pscustomobject]@{SnapshotId=(2).ToString('x64');RelativePath=''}) 'C:\fixture' 'C:\restic.exe'
if((& $module {$script:DumpCount}) -ne 1 -or -not (& $module {$script:SelectedQuery})){throw 'Selected-snapshot browsing rescanned unrelated originals or receipts.'}
& $module {
 $context=[pscustomobject]@{BrowseDeadlineUtc=[DateTimeOffset]::UtcNow.AddSeconds(7)}
 $seconds=Get-RestoreNativeTimeout $context @('cat','config')
 if($seconds -gt 7 -or $seconds -lt 1){throw 'Native metadata timeout exceeds the remaining whole-action budget.'}
 $context.BrowseDeadlineUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1);$rejected=$false
 try{Get-RestoreNativeTimeout $context @('cat','config')|Out-Null}catch{$rejected=$_.Exception.Message -match 'reading.*backup|backup.*took'}
 if(-not $rejected){throw 'An expired whole-action budget did not return a specific browse retry.'}
}
& $module {
 function script:Invoke-NetCrateProcess {param($FilePath,$Arguments,$Environment,[int]$TimeoutSeconds);$script:ForwardedTimeout=$TimeoutSeconds;throw 'The operation timed out. Its work was retained for retry.'}
 $context=[pscustomobject]@{BrowseDeadlineUtc=[DateTimeOffset]::UtcNow.AddSeconds(7);Restic='C:\fixture.exe';Repository='C:\fixture';Options=@();Environment=@{}}
 $specific=$false
 try{& $script:RealNative $context @('cat','config')|Out-Null}catch{$specific=$_.Exception.Message -match 'Reading the backup took too long.*Refresh'}
 if(-not $specific -or $script:ForwardedTimeout -gt 7){throw 'A native browse timeout did not preserve its remaining budget and specific retry guidance.'}
}
Write-Output 'PASS: bounded candidate receipts, stable paging, exact selected revalidation and remaining browse-budget assertions.'
