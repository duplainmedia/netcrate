#requires -Version 5.1
function Get-PrimaryBackupSnapshot {
    param([int]$BackupExitCode,[string]$BackupJsonLogPath)
    if($BackupExitCode -ne 0){return $null}
    $summaries=@(foreach($line in [IO.File]::ReadLines($BackupJsonLogPath)){
        if($line -match '"message_type"\s*:\s*"summary"'){$line|ConvertFrom-Json}
    })
    if($summaries.Count -ne 1 -or $summaries[0].snapshot_id -cnotmatch '^[a-f0-9]{64}$'){throw 'Successful backup must contain exactly one full snapshot ID from its own log.'}
    return $summaries[0].snapshot_id
}
function Get-PrimarySnapshotProjects {
    param([string]$MetadataPath,[string[]]$ExcludedProjects=@())
    $projects=New-Object 'Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    foreach($line in [IO.File]::ReadLines($MetadataPath)){
        if(-not $line.Trim()){continue}
        $node=$line|ConvertFrom-Json
        if(-not $node.PSObject.Properties['type'] -or $node.type -ne 'file'){continue}
        if([IO.Path]::GetExtension($node.path).ToLowerInvariant() -notin @('.mp4','.mov','.mxf','.mts','.m2ts','.avi','.mkv','.mpg','.mpeg','.webm')){continue}
        if($node.path -cmatch '^(/D/Video Projects/([^/]+))/'){
            $project=$Matches[1];$name=$Matches[2]
            if($name -in $ExcludedProjects){continue}
            if($project -match '[\\:*?\[\]"<>|\r\n]|(^|/)\.\.?(/|$)|[. ]$'){throw 'Snapshot contains an unsupported active-project path.'}
            [void]$projects.Add($project)
        }
    }
    return @($projects)
}
function Save-PrimaryMediaEvent {
    param($Event,[string]$Path)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.writing'
    $Event|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Complete-PrimaryMediaEvent {
    param([string]$EventPath,[string]$ResticExe,[string[]]$ExcludedProjects=@())
    $event=Get-Content -LiteralPath $EventPath -Raw|ConvertFrom-Json
    try {
        $snapshot=Get-PrimaryBackupSnapshot -BackupExitCode $event.BackupExitCode -BackupJsonLogPath $event.BackupLog
        if($snapshot -ne $event.SnapshotId){throw 'Pending event does not match its exact successful backup log.'}
        $metadata=Join-Path ([IO.Path]::GetDirectoryName($EventPath)) ($snapshot+'.snapshot-files.jsonl')
        if(-not(Test-Path -LiteralPath $metadata)){
            $temporary=$metadata+'.writing'
            & $ResticExe ls --json --recursive $snapshot | Set-Content -LiteralPath $temporary -Encoding UTF8
            $metadataExit=$LASTEXITCODE
            if($metadataExit -ne 0){throw 'Snapshot metadata lookup failed; successful backup event retained for retry.'}
            Move-Item -LiteralPath $temporary -Destination $metadata -Force
        }
        $paths=@(Get-PrimarySnapshotProjects -MetadataPath $metadata -ExcludedProjects $ExcludedProjects)
        $event.ProjectPaths=$paths
        if($paths.Count){
            $summaryLog=$EventPath+'.summary.jsonl'
            @{message_type='summary';snapshot_id=$snapshot}|ConvertTo-Json -Compress|Set-Content -LiteralPath $summaryLog -Encoding UTF8
            & 'C:\Program Files\OfficeMediaSource\Queue-OfficeMediaAfterBackup.ps1' -BackupExitCode 0 -BackupJsonLogPath $summaryLog -ProjectPaths $paths | Out-Null
            $event.State='Queued'
        }else{$event.State='Skipped; no eligible active footage projects'}
        $event.Error=$null
    } catch {
        $event.State='RetryPending'
        $event.Error=$_.Exception.Message
        Write-Warning 'Backup succeeded; automatic media enqueue is pending. Its success event is retained and will retry on the next primary-backup command.'
    }
    $event.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
    Save-PrimaryMediaEvent -Event $event -Path $EventPath
}
function Invoke-PrimaryMediaPending {
    param([string]$RunRoot,[string]$ResticExe,[string[]]$ExcludedProjects=@())
    foreach($file in Get-ChildItem -LiteralPath $RunRoot -Filter '*.media-success.json' -File){
        $event=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
        if($event.State -in @('Pending','RetryPending')){
            Complete-PrimaryMediaEvent -EventPath $file.FullName -ResticExe $ResticExe -ExcludedProjects $ExcludedProjects
        }
    }
}
