param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$repo/src/shared/NetCrate.Configuration.psm1"
Import-Module "$repo/src/shared/NetCrate.Process.psm1"
$null=[IO.Directory]::CreateDirectory($TestRoot)
$project=[IO.Path]::GetFullPath([IO.Path]::Combine($TestRoot,'Old profile','日本語 [set]'))
$store=[IO.Path]::Combine($TestRoot,'Moved drive','originals')
$dest=[IO.Path]::Combine($TestRoot,'Recovered')
$null=[IO.Directory]::CreateDirectory("$project/nested [a]/empty")
$null=[IO.Directory]::CreateDirectory($dest)
$password='NC3-canary-'+[guid]::NewGuid().ToString('N')
function Native([string[]]$Arguments) {
 $r=Invoke-NetCrateProcess $ResticExe (@('--repo',$store,'--no-cache')+$Arguments) @{RESTIC_PASSWORD=$password}
 if($r.ExitCode){throw 'Native fixture failed.'}; $r.Output
}
$null=Native @('init')
$id=(Native @('cat','config')|ConvertFrom-Json).id
[IO.File]::WriteAllBytes("$project/nested [a]/café [1].txt",[byte[]](1,2,3,4))
[IO.File]::WriteAllText("$project/nested [a]/café 1.txt",'sibling')
[IO.File]::WriteAllText("$project/zero.txt",'')
[IO.File]::WriteAllBytes("$project/binary.bin",[byte[]](0..255))
$binaryHash=(Get-FileHash -LiteralPath "$project/binary.bin" -Algorithm SHA256).Hash
function Backup([string]$Date) {
 $o=Native @('backup','--json','--host','OLD-SOURCE','--time',$Date,'--tag','netcrate-v2-originals','--tag','netcrate-folder-originals','--',$project)
 $s=@($o -split '\r?\n'|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json}|Where-Object message_type -EQ summary)[0].snapshot_id
 $receipt="$TestRoot/BackupReceipts/$s.json"
 Write-NetCrateJson $receipt @{Version=1;Kind='backup-receipt';RepositoryId=$id;SourceComputer='OLD-SOURCE';Project=$project;SnapshotId=$s;BackupMode='Folder';JobId=[guid]::NewGuid().ToString('N');BackupCompletedUtc=([DateTimeOffset]::Parse($Date)).ToUniversalTime().ToString('o')}
 $null=Native @('backup','--host','OLD-SOURCE','--tag','netcrate-backup-receipt','--tag',"netcrate-receipt-$s",'--',$receipt)
 $s
}
# A historical source ACL may name unrelated accounts; restored output must be private to this account.
$file=[IO.FileInfo]::new("$project/nested [a]/café [1].txt")
$sourceAcl=[IO.FileSystemAclExtensions]::GetAccessControl($file)
$sourceAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Read','Allow'))
[IO.FileSystemAclExtensions]::SetAccessControl($file,$sourceAcl)
$first=Backup '2024-01-02 03:04:05'
[IO.File]::WriteAllBytes("$project/nested [a]/café [1].txt",[byte[]](4,3,2,1))
$second=Backup '2024-02-03 04:05:06'
# A marked image without a completion receipt is never a restore point.
$null=Native @('backup','--host','OLD-SOURCE','--tag','netcrate-v2-originals','--tag','netcrate-folder-originals','--',$project)
$recovery="$TestRoot/recovery.json"
Write-NetCrateJson $recovery @{Version=1;Kind='netcrate-recovery';InstallationId=('a'*32);CreatedUtc=[DateTime]::UtcNow.ToString('o');Primary=@{Id=$id;Path='Z:\missing-profile\originals';Password=$password};Results=@{Id=('b'*64);Path='Z:\absent';Password='unused'};Instructions='fixture'}
# Remove the entire source: metadata must not depend on its drive, profile or settings.
[IO.Directory]::Move("$TestRoot/Old profile","$TestRoot/Absent source")
if(-not (Test-Path "$repo/src/shared/NetCrate.Restore.psm1")){throw 'Restore actions and independent recovery are not implemented.'}
Import-Module "$repo/src/shared/NetCrate.Restore.psm1"
# Observe each native materialization boundary before product cleanup/permission changes.
$observe=Get-Module NetCrate.Restore
& $observe {
 $script:ObservedNative=(Get-Command Invoke-RestoreNative).ScriptBlock
 function script:Invoke-RestoreNative($Context,[string[]]$Arguments) {
  $r=& $script:ObservedNative $Context $Arguments
  $i=[Array]::IndexOf($Arguments,'--target')
  if($i -ge 0) {
   $path=[IO.Path]::GetFullPath($Arguments[$i+1]);$stage=$path
   while($stage -and [IO.Path]::GetFileName($stage) -cnotmatch '^\.netcrate-restore-[a-f0-9]{32}$'){$stage=[IO.Path]::GetDirectoryName($stage)}
   if($stage) {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach($entry in @([IO.DirectoryInfo]::new($stage))+@([IO.DirectoryInfo]::new($stage).EnumerateFileSystemInfos('*',[IO.SearchOption]::AllDirectories))) {
     $acl=if($entry -is [IO.DirectoryInfo]){[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]$entry)}else{[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]$entry)}
     $broad=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -cnotin @($sid,'S-1-5-18')})
     if($broad.Count){throw 'Historical source ACL exposed bytes during materialization.'}
    }
   }
  }
  return $r
 }
}
$request=@{RecoveryFile=$recovery;RepositoryPath=$store}
function Action($Name,$Extra=@{}) { $q=@{};foreach($k in $request.Keys){$q[$k]=$request[$k]};foreach($k in $Extra.Keys){$q[$k]=$Extra[$k]};Invoke-NetCrateRestoreAction $Name ([pscustomobject]$q) "$TestRoot/Fresh" $ResticExe }
$n=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:n++}
function Reject($Work,$Message){$bad=$false;try{&$Work|Out-Null}catch{$bad=$true};Check $bad $Message}
$list=Action ListBackups
Check (@($list.Items).Count -eq 2) 'Receipt snapshots or incomplete originals were visible.'
Check ($list.Items[0].SnapshotId -ceq $second -and $list.Items[1].SnapshotId -ceq $first) 'Dated versions are not selectable in order.'
Check ($list.Items[0].Project -ceq $project -and $list.Items[0].SourceComputer -ceq 'OLD-SOURCE') 'Recovery borrowed the current profile or host.'
$children=Action ListBackupChildren @{SnapshotId=$first;RelativePath='nested [a]'}
Check (@($children.Items).Count -eq 3 -and @($children.Items|Where-Object Name -CEQ 'café [1].txt').Count -eq 1) 'Immediate literal Unicode children missing.'
$old=Action RestoreSelection @{SnapshotId=$first;RelativePath='nested [a]/café [1].txt';DestinationParent=$dest}
Check (([IO.File]::ReadAllBytes("$($old.RestoredPath)/café [1].txt") -join ',') -ceq '1,2,3,4') 'Old file bytes differ.'
Check (@([IO.Directory]::EnumerateFileSystemEntries($old.RestoredPath)).Count -eq 1) 'Single file included a similarly named sibling.'
$currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new("$($old.RestoredPath)/café [1].txt"))
$unexpected=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -cnotin @($currentSid,'S-1-5-18')})
Check ($unexpected.Count -eq 0) 'Recovered file retained source-account permissions instead of private recovery permissions.'
$new=Action RestoreSelection @{SnapshotId=$second;RelativePath='nested [a]';DestinationParent=$dest}
Check (([IO.File]::ReadAllBytes("$($new.RestoredPath)/café [1].txt") -join ',') -ceq '4,3,2,1') 'Same-size changed bytes were not verified.'
Check ([IO.Directory]::Exists("$($new.RestoredPath)/empty")) 'Empty directory lost.'
[IO.File]::WriteAllText("$($new.RestoredPath)/sentinel",'keep')
$root=Action RestoreSelection @{SnapshotId=$second;RelativePath='';DestinationParent=$dest}
Check ([IO.File]::Exists("$($root.RestoredPath)/zero.txt") -and [IO.Directory]::Exists("$($root.RestoredPath)/nested [a]/empty")) 'Whole root membership differs.'
Check ((Get-FileHash -LiteralPath "$($root.RestoredPath)/binary.bin" -Algorithm SHA256).Hash -ceq $binaryHash) 'Root restore corrupted NUL or bytes 0..255.'
$binary=Action RestoreSelection @{SnapshotId=$first;RelativePath='binary.bin';DestinationParent=$dest}
Check ((Get-FileHash -LiteralPath "$($binary.RestoredPath)/binary.bin" -Algorithm SHA256).Hash -ceq $binaryHash) 'Single-file dump corrupted NUL or bytes 0..255.'
Check ([IO.File]::ReadAllText("$($new.RestoredPath)/sentinel") -ceq 'keep') 'Existing target overwritten.'
Reject {Action RestoreSelection @{SnapshotId='latest';DestinationParent=$dest}} 'Snapshot aliases accepted.'
Reject {Action RestoreSelection @{SnapshotId=$first;RelativePath='../escape';DestinationParent=$dest}} 'Traversal accepted.'
Reject {Action RestoreSelection @{SnapshotId=$first;DestinationParent=$store}} 'Repository destination accepted.'
$wrong=Read-NetCrateJson $recovery;$wrong.Primary.Id='f'*64;Write-NetCrateJson "$TestRoot/wrong.json" $wrong
Reject {Invoke-NetCrateRestoreAction ListBackups ([pscustomobject]@{RecoveryFile="$TestRoot/wrong.json";RepositoryPath=$store}) "$TestRoot/Fresh" $ResticExe} 'Wrong ID accepted.'
$wrong.Primary.Id=$id;$wrong.Primary.Password='bad';Write-NetCrateJson "$TestRoot/wrong.json" $wrong
Reject {Invoke-NetCrateRestoreAction ListBackups ([pscustomobject]@{RecoveryFile="$TestRoot/wrong.json";RepositoryPath=$store}) "$TestRoot/Fresh" $ResticExe} 'Wrong password accepted.'
# Node validation is exercised before any native restoration or materialization.
foreach($name in @('../escape','con.txt','a:b','a/b','trailing.')) {Reject {Assert-NetCrateRestoreNodes @([pscustomobject]@{name=$name;type='file';size=0})} "Unsafe name accepted: $name"}
Reject {Assert-NetCrateRestoreNodes @([pscustomobject]@{name='A';type='dir'},[pscustomobject]@{name='a';type='dir'})} 'Case collision accepted.'
Reject {Assert-NetCrateRestoreNodes @([pscustomobject]@{name='link';type='symlink'})} 'Link node accepted.'
$link="$TestRoot/link";$null=New-Item -ItemType Junction -Path $link -Target $dest
Reject {Action RestoreSelection @{SnapshotId=$first;DestinationParent=$link}} 'Linked destination accepted.'
Check (@([IO.Directory]::EnumerateDirectories($dest,'.netcrate-restore-*')).Count -eq 0) 'Owned staging leaked after success.'
Check (-not [IO.Directory]::Exists("$TestRoot/Fresh/Secrets")) 'Independent recovery created DPAPI identity.'
# Fault the native restore at the publication boundary: partial private bytes must never become output.
$before=@([IO.Directory]::EnumerateDirectories($dest)).Count
$module=Get-Module NetCrate.Restore
& $module {
 $script:OriginalRestoreNative=(Get-Command Invoke-RestoreNative).ScriptBlock
 function script:Invoke-RestoreNative($Context,[string[]]$Arguments) {
  if($Arguments[0] -ceq 'restore' -or ($Arguments[0] -ceq 'dump' -and [Array]::IndexOf($Arguments,'--target') -ge 0)) {
   $target=$Arguments[[Array]::IndexOf($Arguments,'--target')+1]
   $null=[IO.Directory]::CreateDirectory($target);[IO.File]::WriteAllText([IO.Path]::Combine($target,'partial'),'not published')
   throw 'Simulated interrupted restore before publication.'
  }
  & $script:OriginalRestoreNative $Context $Arguments
 }
}
try { Reject {Action RestoreSelection @{SnapshotId=$first;DestinationParent=$dest}} 'Interrupted restore reported success.' }
finally { & $module {Set-Item Function:script:Invoke-RestoreNative $script:OriginalRestoreNative;Remove-Variable OriginalRestoreNative -Scope Script} }
Check (@([IO.Directory]::EnumerateDirectories($dest)).Count -eq $before) 'Interrupted restore published or leaked partial staging.'
Check ([IO.File]::ReadAllText("$($new.RestoredPath)/sentinel") -ceq 'keep') 'Interrupted restore altered existing output.'
Check (-not [IO.Directory]::Exists("$TestRoot/Fresh/Logs")) 'Recovery unnecessarily saved tool diagnostics.'
Write-Output "PASS: $n originals recovery assertions (native Restic, absent source profile, no media tools)."
