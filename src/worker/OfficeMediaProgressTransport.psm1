# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
function Get-ProgressRequestId([string]$Snapshot,[string]$Project){
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Snapshot+'|'+$Project))).ToLowerInvariant()
}
function Assert-ProgressRecord($Value,[string]$Id){
    $required=@('Version','Kind','SourceComputer','WorkerComputer','RequestId','SourceSnapshotId','ProjectPath','JobId','AttemptId','Sequence','UpdatedUtc','Stage','TotalClips','CompletedClips','ProxyFilesCompleted','ContactSheetsCompleted','StageCompletedUnits','StageTotalUnits','StageUnit','CurrentClip','EtaSeconds','EtaScope','EtaBasis','EtaSampleSeconds','Message')
    $names=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
    if(@($required|Where-Object{$_ -notin $names}).Count -or @($names|Where-Object{$_ -notin $required}).Count){throw 'Progress fields differ from Version 1 contract.'}
    if($Value.Version -ne 1 -or $Value.Kind -cne 'office-media-progress' -or $Value.SourceComputer -cne 'SOURCE-PC' -or $Value.WorkerComputer -cne 'WORKER-PC' -or $Id -cnotmatch '^[a-f0-9]{64}$' -or $Value.RequestId -cne $Id -or $Value.SourceSnapshotId -cnotmatch '^[a-f0-9]{64}$' -or $Value.AttemptId -cnotmatch '^[a-f0-9]{32}$' -or $Value.JobId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,100}$'){throw 'Invalid progress identity.'}
    if($Value.ProjectPath -cnotmatch '^/D/Projects/[^/\\:*?\[\]"<>|\x00-\x1f]+$' -or $Value.ProjectPath -match '(^|/)\.\.?(/|$)|[. ]$' -or (Get-ProgressRequestId $Value.SourceSnapshotId $Value.ProjectPath) -cne $Id){throw 'Progress request association differs.'}
    if($Value.Stage -cnotin @('Queued','RestoringOriginals','Probing','GeneratingProxies','GeneratingContactSheets','Verifying','Publishing','Complete','Failed')){throw 'Invalid progress stage.'}
    foreach($name in @('Sequence','TotalClips','CompletedClips','ProxyFilesCompleted','ContactSheetsCompleted')){
        $valueNumber=$Value.$name
        if($null -eq $valueNumber -or $valueNumber -is [string] -or $valueNumber -is [bool] -or -not [double]::IsFinite([double]$valueNumber) -or [double]$valueNumber -lt 0 -or [double]$valueNumber -ne [math]::Floor([double]$valueNumber)){throw 'Invalid progress integer.'}
    }
    foreach($name in @('CompletedClips','ProxyFilesCompleted','ContactSheetsCompleted')){if($Value.$name -gt $Value.TotalClips){throw 'Progress clip count exceeds total.'}}
    foreach($name in @('StageCompletedUnits','StageTotalUnits','EtaSeconds','EtaSampleSeconds')){
        if($null -ne $Value.$name -and ($Value.$name -is [string] -or $Value.$name -is [bool] -or -not [double]::IsFinite([double]$Value.$name) -or [double]$Value.$name -lt 0)){throw 'Invalid progress measurement.'}
    }
    if($null -ne $Value.StageTotalUnits -and ($Value.StageTotalUnits -le 0 -or $Value.StageCompletedUnits -gt $Value.StageTotalUnits)){throw 'Invalid progress phase total.'}
    if($Value.StageUnit -cnotin @('source-seconds','frames','clips','bytes','unknown') -or $Value.Message.Length -gt 500 -or $Value.EtaBasis.Length -gt 500){throw 'Invalid progress description.'}
    if($Value.CurrentClip -and ($Value.CurrentClip -match '^[/\\]|:|(^|[/\\])\.\.?($|[/\\])|\p{Cc}')){throw 'Unsafe progress relative clip.'}
    if($null -ne $Value.EtaSeconds -and ($Value.EtaSampleSeconds -lt 30 -or $Value.EtaScope -cnotin @('phase','generation') -or -not $Value.EtaBasis)){throw 'Unsupported ETA.'}
    if($null -eq $Value.EtaSeconds -and ($Value.EtaScope -or $Value.EtaBasis)){throw 'ETA fields must be empty without an estimate.'}
    if($Value.UpdatedUtc -is [DateTime]){if($Value.UpdatedUtc.Kind -ne 'Utc'){throw 'Progress timestamp must be UTC.'}}else{if($Value.UpdatedUtc -notmatch '(Z|\+00:00)$'){throw 'Progress timestamp must be UTC.'};$null=[DateTimeOffset]::Parse($Value.UpdatedUtc)}
}
function Test-ProgressDue($Value,$Previous,[double]$Now){
    if(-not $Previous){return $true}
    if($Previous.AttemptId -cne $Value.AttemptId -or $Previous.Stage -cne $Value.Stage){return $true}
    if($Value.Sequence -le $Previous.Sequence){return $false}
    return $Now-[double]$Previous.PublishedEpoch -ge 30 -or $Value.Stage -in @('Complete','Failed')
}
function Select-ProgressRecord($Latest,[object[]]$Pending,$Previous,[double]$Now){
    if($Latest.Stage -in @('Complete','Failed')){return $Latest}
    foreach($candidate in ($Pending|Sort-Object Sequence)){
        if($candidate.AttemptId -ne $Latest.AttemptId -or ($Previous -and $candidate.AttemptId -eq $Previous.AttemptId -and $candidate.Sequence -le $Previous.Sequence)){continue}
        $when=if($candidate.UpdatedUtc -is [DateTime]){[DateTimeOffset]$candidate.UpdatedUtc}else{[DateTimeOffset]::Parse($candidate.UpdatedUtc)}
        # A slow successful upload must not turn historical phase replay into
        # current progress. Retain its journal locally; send the latest instead.
        if($Now-$when.ToUnixTimeMilliseconds()/1000.0 -gt 10){return $Latest}
        return $candidate
    }
    return $Latest
}
Export-ModuleMember -Function Get-ProgressRequestId,Assert-ProgressRecord,Test-ProgressDue,Select-ProgressRecord
