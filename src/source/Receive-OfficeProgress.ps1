#requires -Version 5.1
[CmdletBinding()]
param([string]$ServiceRoot='C:\ProgramData\OfficeMediaProgress',[switch]$Once)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
. (Join-Path $PSScriptRoot 'Protocol.ps1')
$config=Get-Content -LiteralPath (Join-Path $ServiceRoot 'settings.json') -Raw|ConvertFrom-Json
$credential=$null;$plain=$null
function Invoke-ProgressRead([string[]]$Arguments){
    if($Arguments[0] -notin @('snapshots','dump')){throw 'Only progress metadata reads are permitted.'}
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$config.ResticExe;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($key in @($psi.EnvironmentVariables.Keys)){if($key -like 'RESTIC_*'){$psi.EnvironmentVariables.Remove($key)}}
    $all=@('--repo',$config.Repository,'--no-lock','--cache-dir',(Join-Path $ServiceRoot 'Cache'))+$Arguments
    $quoted=foreach($arg in $all){if($arg -match '["\r\n]' -or $arg.EndsWith('\')){throw 'Unsupported progress command argument.'};'"'+$arg+'"'}
    $psi.Arguments=$quoted -join ' '
    $psi.EnvironmentVariables['RESTIC_PASSWORD']=$credential.ResultsPassword;$psi.EnvironmentVariables['RESTIC_REST_USERNAME']=$credential.RestUsername;$psi.EnvironmentVariables['RESTIC_REST_PASSWORD']=$credential.RestPassword
    $child=New-Object Diagnostics.Process;$child.StartInfo=$psi
    try{
        $null=$child.Start();$psi.EnvironmentVariables.Clear();$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(30000)){$child.Kill();$child.WaitForExit();throw 'Progress metadata read timed out; it will retry.'}
        $text=$stdout.GetAwaiter().GetResult();$diagnostic=$stderr.GetAwaiter().GetResult()
        if($child.ExitCode -ne 0){throw 'Progress metadata connection failed; it will retry.'}
        if($text.Length -gt 8MB){throw 'Excessive progress metadata response.'}
        return $text
    }finally{$psi.EnvironmentVariables.Clear();$child.Dispose();$diagnostic=$null}
}
function Read-ProgressIteration {
    $groups=ConvertFrom-Json -InputObject (Invoke-ProgressRead @('snapshots','--json','--tag','office-media-progress','--group-by','paths','--latest','1'))
    $snapshots=@(foreach($entry in $groups){if($entry.PSObject.Properties['snapshots']){foreach($item in $entry.snapshots){$item}}else{$entry}})
    $errorsCount=0;$received=0
    foreach($snapshot in ($snapshots|Sort-Object time)){
      try{
        $phase='Envelope'
        if($snapshot.id -cnotmatch '^[a-f0-9]{64}$' -or $snapshot.hostname -cne 'WORKER-PC' -or @($snapshot.paths).Count -ne 1 -or [long]$snapshot.summary.total_files_processed -ne 1 -or [long]$snapshot.summary.total_bytes_processed -gt 32768){throw 'Invalid progress snapshot envelope.'}
        $root=$snapshot.paths[0].Replace('\','/')
        if($root -cnotmatch ('^'+[regex]::Escape($config.PublisherRoot.TrimEnd('/'))+'/([a-f0-9]{64})$')){throw 'Progress snapshot is outside the allowed metadata root.'}
        $id=$Matches[1]
        $tags=@($snapshot.tags|Where-Object{$_ -like 'request:*'});if($tags.Count -ne 1 -or $tags[0] -cne ('request:'+$id)){throw 'Progress snapshot request tag mismatch.'}
        $requestPath=Join-Path $config.Outbox ($id+'\request.json');$sentPath=Join-Path $config.SentRoot ($id+'.json')
        if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf) -or -not(Test-Path -LiteralPath $sentPath -PathType Leaf)){continue}
        $cachePath=Join-Path $ServiceRoot ('State\Jobs\'+$id+'.json')
        $previous=$null;if(Test-Path -LiteralPath $cachePath){$previous=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json;if($previous.TransportSnapshotId -ceq $snapshot.id){continue}}
        $phase='ReadPayload'
        $body=Invoke-ProgressRead @('dump',$snapshot.id,('/C/'+$root.Substring(3)+'/progress.json'))
        if([Text.Encoding]::UTF8.GetByteCount($body) -gt 32768){throw 'Progress payload is too large.'}
        $payload=$body|ConvertFrom-Json;$request=Get-Content -LiteralPath $requestPath -Raw|ConvertFrom-Json
        $phase='ValidatePayload'
        $null=Assert-OfficeProgressPayload -Payload $payload -Request $request -RequestId $id
        if($previous){
            $newTime=Get-OfficeProgressUtc $payload.UpdatedUtc;$oldTime=Get-OfficeProgressUtc $previous.UpdatedUtc
            if($newTime -lt $oldTime -or ($payload.AttemptId -ceq $previous.AttemptId -and [long]$payload.Sequence -lt [long]$previous.Sequence)){continue}
        }
        $payload|Add-Member -NotePropertyName TransportSnapshotId -NotePropertyValue $snapshot.id -Force
        $payload.UpdatedUtc=(Get-OfficeProgressUtc $payload.UpdatedUtc).ToString('o')
        $payload|Add-Member -NotePropertyName SourceReceivedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $phase='CachePayload'
        Write-OfficeProgressJson $cachePath $payload;$received++
      }catch{
        $errorsCount++
        if($snapshot.id -cmatch '^[a-f0-9]{64}$'){Write-OfficeProgressJson (Join-Path $ServiceRoot ('State\retry-'+$snapshot.id+'.json')) @{State='RetryPending';Stage=$phase;ErrorType=$_.Exception.GetType().Name;UpdatedUtc=[DateTime]::UtcNow.ToString('o')}}
      }
    }
    Write-OfficeProgressJson (Join-Path $ServiceRoot 'State\status.json') @{State=$(if($errorsCount){'RetryPending'}else{'Ready'});ReceivedThisPoll=$received;InvalidSnapshots=$errorsCount;CheckedUtc=[DateTime]::UtcNow.ToString('o');PollSeconds=15;Message=$(if($errorsCount){'Some office progress metadata was invalid or unreadable; existing valid status is preserved.'}else{'Waiting for or receiving WORKER-PC progress metadata.'})}
}
try{
    if($env:COMPUTERNAME -ine 'SOURCE-PC' -or $config.Repository -cne 'rest:http://backup.example:8000/sample-user/office-media-results/' -or $config.PublisherRoot -cne 'C:/ProgramData/OfficeMedia/ProgressPublish'){throw 'Progress reader identity, repository or publisher root mismatch.'}
    $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($config.CredentialPath),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    $credential=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json
    if($credential.ResultsRepository -cne $config.Repository -or $credential.RestUsername -ne 'sample-user'){throw 'Existing results credential identity mismatch.'}
    do{
        try{Read-ProgressIteration}catch{Write-OfficeProgressJson (Join-Path $ServiceRoot 'State\status.json') @{State='RetryPending';CheckedUtc=[DateTime]::UtcNow.ToString('o');Message='Live office progress is temporarily unavailable. Existing media processing continues; this reader retries automatically.'}}
        if(-not $Once){Start-Sleep -Seconds 15}
    }while(-not $Once)
}catch{Write-OfficeProgressJson (Join-Path $ServiceRoot 'State\status.json') @{State='RetryPending';CheckedUtc=[DateTime]::UtcNow.ToString('o');Message='Progress reader setup or protected credential access needs review. No credentials were logged.'};exit 1}
finally{if($plain){[Array]::Clear($plain,0,$plain.Length)};$credential=$null}
