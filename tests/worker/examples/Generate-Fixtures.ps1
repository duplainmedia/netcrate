#requires -Version 7.0
# Pure synthetic metadata generation. No repository, media, or credential operations.
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\..\office\OfficeMediaAuto.psm1" -Force
Import-Module "$PSScriptRoot\..\office\OfficeMediaProgressTransport.psm1" -Force
function Save([string]$Name,$Value){$Value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $PSScriptRoot $Name) -Encoding utf8NoBOM}
$snapshot=Get-AutoHash 'netcrate-public-fixture-v1:source-snapshot'
$result=Get-AutoHash 'netcrate-public-fixture-v1:result-snapshot'
$project='/D/Projects/sample-project'
$nodes=@([pscustomobject]@{type='file';path="$project/Camera/clip.mov";size=41;content=@((Get-AutoHash 'netcrate-public-fixture-v1:restic-content'))})
$identity=Get-AutoVideoIdentity $project $nodes
$job='auto-'+$identity.Fingerprint
$requestId=Get-AutoHash ($snapshot+'|'+$project)
$attempt=(Get-AutoHash 'netcrate-public-fixture-v1:attempt').Substring(0,32)
$request=[ordered]@{Version=1;Kind='request';SourceComputer='SOURCE-PC';Repository='rest:https://backup.example:8000/sample-user/source-pc/';BackupExitCode=0;SnapshotId=$snapshot;ProjectPath=$project;CompletedUtc='2025-01-15T12:00:00Z'}
$null=Assert-AutoRequest ([pscustomobject]$request)
Save 'request.json' $request
Save 'footage-identity.json' $identity
Save 'snapshot-nodes.json' $nodes
$payloads=[ordered]@{'Camera/clip_Proxy.mov'='Synthetic proxy stand-in; not playable media.';'Camera/clip_ContactSheet.jpg'='Synthetic sheet stand-in; not an image.'}
$rows=@(foreach($entry in $payloads.GetEnumerator()){$bytes=[Text.Encoding]::UTF8.GetBytes($entry.Value);[pscustomobject]@{RelativePath=$entry.Key;Bytes=$bytes.Length;SHA256=(Get-AutoHash $entry.Value).ToUpperInvariant()}})
$rows|Export-Csv -LiteralPath "$PSScriptRoot\Files-SHA256.csv" -NoTypeInformation -Encoding utf8NoBOM
Save 'synthetic-payload-spec.json' $payloads
Save 'COMPLETE.json' ([ordered]@{project='sample-project';snapshot_id=$snapshot;proxy_recipe='half-prores-v2';proxy_scale_divisor=2;proxy_bit_depth=10;proxy_pixel_format='yuv422p10le';clips=1;proxy_files=1;contact_sheets=1;verified=$true;elapsed_seconds=90})
Save 'delivery.json' ([ordered]@{Version=1;Kind='delivery';SourceComputer='SOURCE-PC';JobId=$job;ResultSnapshot=$result;MediaFiles=2;VerifiedUtc='2025-01-15T12:02:00Z'})
$progress=[ordered]@{Version=1;Kind='office-media-progress';SourceComputer='SOURCE-PC';WorkerComputer='WORKER-PC';RequestId=$requestId;SourceSnapshotId=$snapshot;ProjectPath=$project;JobId=$job;AttemptId=$attempt;Sequence=0;UpdatedUtc='2025-01-15T12:01:00Z';Stage='GeneratingProxies';TotalClips=1;CompletedClips=0;ProxyFilesCompleted=0;ContactSheetsCompleted=0;StageCompletedUnits=10;StageTotalUnits=20;StageUnit='source-seconds';CurrentClip='Camera/clip.mov';EtaSeconds=40;EtaScope='phase';EtaBasis='observed';EtaSampleSeconds=40;Message='Encoding.'}
Assert-ProgressRecord $progress $requestId
Save 'progress.json' $progress
Save 'identities.json' ([ordered]@{RequestId=$requestId;JobId=$job;SourceSnapshotId=$snapshot;ResultSnapshotId=$result;AttemptId=$attempt;RequestTransportSnapshotId=(Get-AutoHash 'netcrate-public-fixture-v1:request-transport')})
'Synthetic fixtures generated; no media files written.'
