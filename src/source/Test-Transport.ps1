$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Protocol.ps1')
$fixture=Join-Path $env:TEMP ('OfficeProgressTest-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $fixture|Out-Null
$prior=$env:RESTIC_PASSWORD
try{
    $ServiceRoot=Join-Path $fixture 'service';$outbox=Join-Path $fixture 'outbox';$sent=Join-Path $fixture 'sent';$publish=Join-Path $fixture 'publish';$repo=Join-Path $fixture 'repository'
    New-Item -ItemType Directory -Path (Join-Path $ServiceRoot 'State\Jobs'),(Join-Path $ServiceRoot 'Cache'),$outbox,$sent,$publish -Force|Out-Null
    $config=[pscustomobject]@{Repository=$repo;ResticExe='C:\Users\sample-user\AppData\Local\Microsoft\WinGet\Packages\restic.restic_Microsoft.Winget.Source_8wekyb3d8bbwe\restic_0.19.1_windows_amd64.exe';Outbox=$outbox;SentRoot=$sent;PublisherRoot=$publish.Replace('\','/')}
    $env:RESTIC_PASSWORD=[guid]::NewGuid().ToString('N');$credential=[pscustomobject]@{ResultsPassword=$env:RESTIC_PASSWORD;RestUsername='synthetic';RestPassword='synthetic'}
    & $config.ResticExe --repo $repo init|Out-Null;if($LASTEXITCODE -ne 0){throw 'Disposable test repository init failed.'}
    $snapshot='a'*64;$project='/D/Video Projects/Example';$id=Get-OfficeProgressRequestId $snapshot $project
    $folder=Join-Path $publish $id;New-Item -ItemType Directory -Path $folder,(Join-Path $outbox $id) -Force|Out-Null
    @{SnapshotId=$snapshot;ProjectPath=$project;Kind='request';Version=1;SourceComputer='SOURCE-PC';BackupExitCode=0}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $outbox ($id+'\request.json'))
    @{Kind='request'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $sent ($id+'.json'))
    $payload=[pscustomobject]@{Version=1;Kind='office-media-progress';SourceComputer='SOURCE-PC';WorkerComputer='WORKER-PC';RequestId=$id;SourceSnapshotId=$snapshot;ProjectPath=$project;JobId='example-job';AttemptId=('b'*32);Sequence=2;UpdatedUtc=[DateTime]::UtcNow.ToString('o');Stage='GeneratingProxies';TotalClips=4;CompletedClips=1;ProxyFilesCompleted=1;ContactSheetsCompleted=1;StageCompletedUnits=40;StageTotalUnits=100;StageUnit='source-seconds';CurrentClip='Camera\two.mp4';EtaSeconds=120;EtaScope='phase';EtaBasis='Observed FFmpeg speed';EtaSampleSeconds=40;Message='Encoding clip'}
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Receive-OfficeProgress.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('Invoke-ProgressRead','Read-ProgressIteration')){$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);if(-not $definition){throw 'Production progress function missing.'};Invoke-Expression $definition.Extent.Text}
    function Publish-TestProgress{
        $payload|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder 'progress.json') -Encoding UTF8
        & $config.ResticExe --repo $repo backup --json --host WORKER-PC --tag office-media-progress --tag ('request:'+$id) -- $folder|Out-Null
        if($LASTEXITCODE -ne 0){throw 'Disposable metadata publication failed.'}
    }
    Publish-TestProgress;Read-ProgressIteration
    $cache=Join-Path $ServiceRoot ('State\Jobs\'+$id+'.json')
    if(-not(Test-Path -LiteralPath $cache)){Get-Content -LiteralPath (Join-Path $ServiceRoot 'State\status.json') -Raw;Get-ChildItem -LiteralPath (Join-Path $ServiceRoot 'State') -Filter 'retry-*.json'|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw};Invoke-ProgressRead @('snapshots','--json','--tag','office-media-progress','--group-by','paths','--latest','1');throw 'Disposable progress cache was not created.'}
    $value=Get-Content -LiteralPath $cache -Raw|ConvertFrom-Json
    if($value.Sequence -ne 2 -or $value.StageCompletedUnits -ne 40 -or $value.TransportSnapshotId -notmatch '^[a-f0-9]{64}$'){throw 'Real metadata snapshot did not reach the validated cache.'}
    $payload.Sequence=1;$payload.StageCompletedUnits=10;Publish-TestProgress;Read-ProgressIteration
    if((Get-Content -LiteralPath $cache -Raw|ConvertFrom-Json).Sequence -ne 2){throw 'A backwards worker sequence replaced newer progress.'}
    $payload.Sequence=3;$payload.SourceSnapshotId='c'*64;Publish-TestProgress;Read-ProgressIteration
    if((Get-Content -LiteralPath $cache -Raw|ConvertFrom-Json).SourceSnapshotId -ne $snapshot){throw 'Invalid metadata replaced valid cached progress.'}
    'PASS: actual disposable Restic status publication, latest-by-path snapshot read/dump, exact validated cache, sequence rollback rejection and invalid-source preservation.'
}finally{
    $env:RESTIC_PASSWORD=$prior;$credential=$null
    $resolved=(Resolve-Path -LiteralPath $fixture).ProviderPath
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^OfficeProgressTest-[a-f0-9]{32}$'){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
