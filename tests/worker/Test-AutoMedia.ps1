# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\..\..\src\worker\OfficeMediaAuto.psm1" -Force
function Assert-Throws([scriptblock]$Block){try{& $Block;throw 'Expected rejection was missing.'}catch{if($_.Exception.Message -eq 'Expected rejection was missing.'){throw}}}
$project='/D/Projects/Example'
$request=[pscustomobject]@{Version=1;Kind='request';SourceComputer='SOURCE-PC';Repository='rest:https://backup.example:8000/sample-user/source-pc/';BackupExitCode=0;SnapshotId=('a'*64);ProjectPath=$project;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
$null=Assert-AutoRequest $request
foreach($field in @('BackupExitCode','SnapshotId','ProjectPath','SourceComputer')){
    $bad=$request|ConvertTo-Json|ConvertFrom-Json
    switch($field){'BackupExitCode'{$bad.$field=3};'SnapshotId'{$bad.$field='latest'};'ProjectPath'{$bad.$field='/D/Projects/../escape'};'SourceComputer'{$bad.$field='WORKER-PC'}}
    Assert-Throws {Assert-AutoRequest $bad}
}
$a=[pscustomobject]@{path="$project/Camera/a.MP4";type='file';size=8;content=@('1'*64);mtime='one'}
$b=[pscustomobject]@{path="$project/Camera/b.MOV";type='file';size=9;content=@('2'*64)}
$text=[pscustomobject]@{path="$project/edit.prproj";type='file';size=5;content=@('3'*64)}
$first=Get-AutoVideoIdentity -ProjectPath $project -Nodes @($a,$b,$text)
$second=Get-AutoVideoIdentity -ProjectPath $project -Nodes @($b,$a)
if($first.Fingerprint -ne $second.Fingerprint -or $first.Clips -ne 2){throw 'Order/nonvideo changes affected identity.'}
$a.mtime='different'
if((Get-AutoVideoIdentity $project @($a,$b)).Fingerprint -ne $first.Fingerprint){throw 'Metadata-only change affected identity.'}
$a.content=@('4'*64)
if((Get-AutoVideoIdentity $project @($a,$b)).Fingerprint -eq $first.Fingerprint){throw 'Changed footage was ignored.'}
Assert-Throws {Get-AutoVideoIdentity $project @($a,$a)}
$summary='{"message_type":"summary","snapshot_id":"'+('a'*64)+'"}'
$queued=New-AutoBackupRequest -BackupExitCode 0 -BackupJsonLines $summary -ProjectPath $project
if($queued.SnapshotId -ne $request.SnapshotId){throw 'Wrong backup invocation snapshot captured.'}
Assert-Throws {New-AutoBackupRequest -BackupExitCode 3 -BackupJsonLines $summary -ProjectPath $project}
Assert-Throws {New-AutoBackupRequest -BackupExitCode 0 -BackupJsonLines '{"message_type":"status"}' -ProjectPath $project}
'PASS: successful backup binding, rejected failures/invalid requests, stable footage fingerprint, changed-content and collision detection.'
