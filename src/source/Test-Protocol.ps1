$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Protocol.ps1')){. (Join-Path $PSScriptRoot 'Protocol.ps1')}
$snapshot='a'*64;$project='/D/Video Projects/Example';$sha=[Security.Cryptography.SHA256]::Create()
try{$id=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($snapshot+'|'+$project))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
$request=[pscustomobject]@{SnapshotId=$snapshot;ProjectPath=$project;Kind='request';BackupExitCode=0;SourceComputer='SOURCE-PC';Version=1}
$p=[pscustomobject]@{Version=1;Kind='office-media-progress';SourceComputer='SOURCE-PC';WorkerComputer='WORKER-PC';RequestId=$id;SourceSnapshotId=$snapshot;ProjectPath=$project;JobId='example-job';AttemptId=('b'*32);Sequence=1;UpdatedUtc=[DateTime]::UtcNow.ToString('o');Stage='GeneratingProxies';TotalClips=4;CompletedClips=1;ProxyFilesCompleted=1;ContactSheetsCompleted=1;StageCompletedUnits=40;StageTotalUnits=100;StageUnit='source-seconds';CurrentClip='Camera\two.mp4';EtaSeconds=120;EtaScope='phase';EtaBasis='Observed FFmpeg speed';EtaSampleSeconds=40;Message='Encoding clip'}
$null=Assert-OfficeProgressPayload -Payload $p -Request $request -RequestId $id
$parsed=$p|ConvertTo-Json|ConvertFrom-Json;$null=Assert-OfficeProgressPayload -Payload $parsed -Request $request -RequestId $id
foreach($change in @(@{Key='SourceSnapshotId';Value=('c'*64)},@{Key='ProjectPath';Value='/D/Video Projects/../escape'},@{Key='CompletedClips';Value=5},@{Key='StageCompletedUnits';Value=101},@{Key='CurrentClip';Value='..\secret'},@{Key='EtaSampleSeconds';Value=2},@{Key='Stage';Value='Unknown'},@{Key='UpdatedUtc';Value=[DateTime]::UtcNow.AddHours(1).ToString('o')})){
    $copy=$p|ConvertTo-Json|ConvertFrom-Json;$copy.($change.Key)=$change.Value;$blocked=$false
    try{$null=Assert-OfficeProgressPayload -Payload $copy -Request $request -RequestId $id}catch{$blocked=$true}
    if(-not $blocked){throw ('Invalid progress accepted: '+$change.Key)}
}
$p.EtaSeconds=$null;$p.EtaScope='';$p.EtaBasis='';$p.EtaSampleSeconds=0;$p.StageCompletedUnits=$null;$p.StageTotalUnits=$null;$p.StageUnit='unknown';$null=Assert-OfficeProgressPayload -Payload $p -Request $request -RequestId $id
'PASS: exact request binding, source/project identity, clip/unit bounds, path safety, ETA warmup, stages and timestamp validation.'
