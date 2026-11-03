# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\..\..\src\worker\OfficeMediaProgressTransport.psm1" -Force
$snapshot='a'*64;$project='/D/Projects/Example'
$id=Get-ProgressRequestId $snapshot $project
$status=@{Version=1;Kind='office-media-progress';SourceComputer='SOURCE-PC';WorkerComputer='WORKER-PC';RequestId=$id;SourceSnapshotId=$snapshot;ProjectPath=$project;JobId='job';AttemptId=('b'*32);Sequence=0;UpdatedUtc=[DateTime]::UtcNow.ToString('o');Stage='GeneratingProxies';TotalClips=2;CompletedClips=0;ProxyFilesCompleted=0;ContactSheetsCompleted=0;StageCompletedUnits=10;StageTotalUnits=1000;StageUnit='source-seconds';CurrentClip='Camera/clip.mov';EtaSeconds=$null;EtaScope='';EtaBasis='';EtaSampleSeconds=0;Message='Encoding.'}
Assert-ProgressRecord $status $id
if(-not(Test-ProgressDue $status $null 1000)){throw 'Initial status not due.'}
$sent=@{Stage=$status.Stage;AttemptId=$status.AttemptId;Sequence=0;PublishedEpoch=1000}
$status.Sequence=1
if(Test-ProgressDue $status $sent 1029){throw 'Active publish exceeded 30-second throttle.'}
if(-not(Test-ProgressDue $status $sent 1030)){throw 'Latest active status did not become due.'}
$status.Stage='GeneratingContactSheets'
if(-not(Test-ProgressDue $status $sent 1001)){throw 'Stage transition not immediate.'}
$status.Stage='Complete';$sent.Stage='Complete';$sent.Sequence=1
if(Test-ProgressDue $status $sent 5000){throw 'Unchanged final status republished.'}
$status.AttemptId='c'*32
if(-not(Test-ProgressDue $status $sent 1001)){throw 'Restart attempt not immediate.'}
$status.CurrentClip='../credentials'
try{Assert-ProgressRecord $status $id;throw 'Unsafe clip accepted.'}catch{if($_.Exception.Message -eq 'Unsafe clip accepted.'){throw}}
$oldEvent=@{Stage='Probing';AttemptId=('b'*32);Sequence=1;UpdatedUtc='2025-01-15T12:00:00Z'}
$latest=@{Stage='GeneratingProxies';AttemptId=('b'*32);Sequence=100;UpdatedUtc='2025-01-15T12:01:00Z'}
$now=([DateTimeOffset]::Parse('2025-01-15T12:01:00Z')).ToUnixTimeSeconds()
if((Select-ProgressRecord $latest @($oldEvent) $null $now).Sequence -ne 100){throw 'Slow successful transport replayed stale transition backlog.'}
$oldEvent.UpdatedUtc='2025-01-15T12:00:59Z'
if((Select-ProgressRecord $latest @($oldEvent) $null $now).Sequence -ne 1){throw 'Fresh transition was not preserved.'}
foreach($terminal in @('Complete','Failed')){$latest.Stage=$terminal;if((Select-ProgressRecord $latest @($oldEvent) $null $now).Sequence -ne 100){throw 'Terminal status waited behind healthy slow transport.'}}
'PASS: exact association, 30-second throttle, immediate phase/retry/final transitions and unsafe-path rejection.'
