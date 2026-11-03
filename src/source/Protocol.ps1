#requires -Version 5.1
function Get-OfficeProgressUtc([object]$Value){
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    return [DateTimeOffset]::Parse([string]$Value).UtcDateTime
}
function Get-OfficeProgressRequestId([string]$Snapshot,[string]$Project){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Snapshot+'|'+$Project))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Assert-OfficeProgressPayload {
    param($Payload,$Request,[string]$RequestId)
    $p=$Payload
    $required=@('Version','Kind','SourceComputer','WorkerComputer','RequestId','SourceSnapshotId','ProjectPath','JobId','AttemptId','Sequence','UpdatedUtc','Stage','TotalClips','CompletedClips','ProxyFilesCompleted','ContactSheetsCompleted','StageCompletedUnits','StageTotalUnits','StageUnit','CurrentClip','EtaSeconds','EtaScope','EtaBasis','EtaSampleSeconds','Message')
    foreach($name in $required){if(-not $p.PSObject.Properties[$name]){throw 'Progress payload is missing a required field.'}}
    if($p.Version -ne 1 -or $p.Kind -cne 'office-media-progress' -or $p.SourceComputer -cne 'SOURCE-PC' -or $p.WorkerComputer -cne 'WORKER-PC' -or $p.RequestId -cnotmatch '^[a-f0-9]{64}$' -or $p.SourceSnapshotId -cnotmatch '^[a-f0-9]{64}$' -or $p.RequestId -cne $RequestId){throw 'Progress identity mismatch.'}
    if($p.ProjectPath -cnotmatch '^/D/Video Projects/[^/]+$' -or $p.ProjectPath -match '[\\:*?\[\]"<>|\r\n]|(^|/)\.\.?(/|$)|[. ]$'){throw 'Unsafe progress project path.'}
    if((Get-OfficeProgressRequestId $p.SourceSnapshotId $p.ProjectPath) -cne $RequestId -or $Request.SnapshotId -cne $p.SourceSnapshotId -or $Request.ProjectPath -cne $p.ProjectPath -or $Request.Kind -ne 'request' -or $Request.Version -ne 1 -or $Request.BackupExitCode -ne 0 -or $Request.SourceComputer -cne 'SOURCE-PC'){throw 'Progress does not match a successful local backup request.'}
    if($p.JobId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,100}$' -or $p.AttemptId -cnotmatch '^[a-f0-9]{32}$' -or [string]$p.Sequence -notmatch '^\d{1,18}$'){throw 'Invalid progress job/attempt sequence.'}
    $when=Get-OfficeProgressUtc $p.UpdatedUtc
    if($when -gt [DateTime]::UtcNow.AddMinutes(2)){throw 'Progress clock is too far in the future.'}
    if($p.Stage -cnotin @('Queued','RestoringOriginals','Probing','GeneratingProxies','GeneratingContactSheets','Verifying','Publishing','Complete','Failed') -or $p.StageUnit -cnotin @('source-seconds','frames','clips','bytes','unknown')){throw 'Unknown progress stage or work unit.'}
    foreach($name in @('TotalClips','CompletedClips','ProxyFilesCompleted','ContactSheetsCompleted')){if([string]$p.$name -notmatch '^\d{1,8}$' -or [long]$p.$name -gt 1000000){throw 'Invalid clip counter.'}}
    foreach($name in @('CompletedClips','ProxyFilesCompleted','ContactSheetsCompleted')){if([long]$p.$name -gt [long]$p.TotalClips){throw 'Progress exceeds the known clip count.'}}
    if($null -ne $p.StageCompletedUnits -or $null -ne $p.StageTotalUnits){
        if($null -eq $p.StageCompletedUnits -or $null -eq $p.StageTotalUnits){throw 'Both stage unit counts are required together.'}
        $done=[double]$p.StageCompletedUnits;$total=[double]$p.StageTotalUnits
        if([double]::IsNaN($done) -or [double]::IsInfinity($done) -or [double]::IsNaN($total) -or [double]::IsInfinity($total) -or $done -lt 0 -or $total -le 0 -or $done -gt $total){throw 'Invalid measured progress units.'}
    }
    if([string]$p.CurrentClip -match '^[/\\]|:|(^|[/\\])\.\.?($|[/\\])|[\x00-\x1f]' -or ([string]$p.CurrentClip).Length -gt 1024 -or ([string]$p.Message).Length -gt 500 -or ([string]$p.EtaBasis).Length -gt 200){throw 'Unsafe or excessive progress text.'}
    if($null -ne $p.EtaSeconds){$eta=[double]$p.EtaSeconds;$sample=[double]$p.EtaSampleSeconds;if([double]::IsNaN($eta) -or [double]::IsInfinity($eta) -or [double]::IsNaN($sample) -or [double]::IsInfinity($sample) -or $eta -lt 0 -or $eta -gt 2592000 -or $sample -lt 30 -or $p.EtaScope -cnotin @('phase','generation') -or [string]::IsNullOrWhiteSpace($p.EtaBasis) -or $p.Stage -in @('Queued','Complete','Failed')){throw 'ETA requires a useful observed rate and explicit scope.'}}
    return $p
}
function Write-OfficeProgressJson([string]$Path,$Value){
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.writing'
    $Value|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $temporary -Encoding UTF8
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
}
