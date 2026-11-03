param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$module=Import-Module "$repo/src/shared/NetCrate.Restore.psm1" -PassThru
& $module {
 $script:ReadMode='Valid';$script:ReadCalls=0
 $script:OriginalId='a'*64;$script:ReceiptId='b'*64
 $script:Original=[pscustomobject]@{id=$script:OriginalId;hostname='OLD';paths=@('Z:\Absent\Project');time='2024-01-01T00:00:00Z';tags=@('netcrate-v2-originals','netcrate-folder-originals')}
 $script:ReceiptSnapshot=[pscustomobject]@{id=$script:ReceiptId;hostname='OLD';paths=@("Z:\Absent\BackupReceipts\$script:OriginalId.json");time='2024-01-01T00:00:00Z';tags=@('netcrate-backup-receipt',('netcrate-receipt-'+$script:OriginalId))}
 $script:Receipt=[pscustomobject]@{Version=1;Kind='backup-receipt';RepositoryId=('f'*64);SourceComputer='OLD';Project='Z:\Absent\Project';SnapshotId=$script:OriginalId;BackupMode='Folder';JobId='fixture';BackupCompletedUtc='2024-01-01T00:00:00Z'}
 function script:New-RestoreContext($Request,$Root,$ResticExe,$Action) {
  return [pscustomobject]@{Id=('f'*64);HostName='';ActiveRoot='';Environment=@{};Restic='C:\fixture.exe';Repository='C:\fixture';Options=@();BrowseDeadlineUtc=if($Action -ceq 'RestoreSelection'){$null}else{[DateTimeOffset]::UtcNow.AddMinutes(30)}}
 }
 # Only the process boundary is faked: invoke the real action, receipt loop and native error translation.
 function script:Invoke-NetCrateProcess($FilePath,[string[]]$Arguments,$Environment,$TimeoutSeconds) {
  $command=@($Arguments|Where-Object {$_ -cin @('snapshots','dump','cat')})[0]
  $output=''
  switch($command) {
   snapshots {
    $items=@($script:Original)
    if($script:ReadMode -cne 'Missing'){$items+=@($script:ReceiptSnapshot)}
    if($Arguments -ccontains '--tag'){$items=@($items|Where-Object id -CEQ $script:ReceiptId)}
    elseif($Arguments[-1] -ceq $script:OriginalId){$items=@($script:Original)}
    $output=ConvertTo-Json -InputObject @($items) -Depth 8 -Compress
   }
   dump {
    $script:ReadCalls++
    switch($script:ReadMode) {
     Timeout {throw 'The operation timed out. Its work was retained for retry.'}
     Offline {return [pscustomobject]@{ExitCode=10;Output='';Diagnostic='fixture offline'}}
     Malformed {$output='{broken'}
     WrongIdentity {$bad=$script:Receipt|Select-Object *;$bad.RepositoryId='e'*64;$output=$bad|ConvertTo-Json -Compress}
     default {$output=$script:Receipt|ConvertTo-Json -Compress}
    }
   }
   cat {$output='{"nodes":[]}'}
  }
  return [pscustomobject]@{ExitCode=0;Output=$output;Diagnostic=''}
 }
}
$n=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:n++}
function Action($Name){Invoke-NetCrateRestoreAction $Name ([pscustomobject]@{Version=1;SnapshotId=('a'*64);RelativePath=''}) 'C:\fixture' 'C:\fixture.exe'}
foreach($mode in @('Timeout','Offline')) {
 & $module {param($Mode);$script:ReadMode=$Mode} $mode
 foreach($action in @('ListBackups','ListBackupChildren','RestoreSelection')) {
  $message='';try{Action $action|Out-Null}catch{$message=$_.Exception.Message}
  $expected=if($mode -ceq 'Timeout'){'Reading the backup took too long.*Refresh'}else{'repository could not be read or verified.*try again'}
  Check ($message -match $expected) "$action swallowed $mode receipt-read failure instead of a specific retry: $message"
 }
}
foreach($mode in @('Malformed','WrongIdentity','Missing')) {
 & $module {param($Mode);$script:ReadMode=$Mode} $mode
 $listed=Action ListBackups
 Check ($listed.Succeeded -and @($listed.Items).Count -eq 0) "$mode receipt made a new-schema original visible."
 foreach($action in @('ListBackupChildren','RestoreSelection')) {
  $message='';try{Action $action|Out-Null}catch{$message=$_.Exception.Message}
  Check ($message -match 'no valid completion evidence') "$mode receipt did not fail selected revalidation closed."
 }
}
& $module {$script:ReadMode='Valid'}
Check (@((Action ListBackups).Items).Count -eq 1) 'Valid receipt control was not listed.'
Check ((Action ListBackupChildren).Succeeded) 'Valid receipt selected control could not browse.'
Check ((& $module {$script:ReadCalls}) -gt 0) 'The actual native receipt-read loop was not exercised.'
Write-Output "PASS: $n full-action receipt timeout/offline retry, malformed/missing/identity rejection and valid-control assertions."
