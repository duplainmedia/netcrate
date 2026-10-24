#requires -Version 5.1
[CmdletBinding()]
param([string]$ServiceRoot='C:\ProgramData\OfficeMediaClient')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
. (Join-Path $PSScriptRoot 'OfficeMedia.Common.ps1')
$settings=Get-Content -LiteralPath "$ServiceRoot\settings.json" -Raw|ConvertFrom-Json
$projectDelivery=$settings.PSObject.Properties['ProjectDeliveryEnabled'] -and $settings.ProjectDeliveryEnabled
$stateRoot="$ServiceRoot\State"
$statusPath="$stateRoot\status.json"
$credential=$null;$plainBytes=$null;$process=$null
function Set-DeliveryStatus([string]$State,[string]$Message){
    @{State=$State;Message=$Message;UpdatedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $statusPath
}
function Invoke-ResultRead([string[]]$Arguments){
    if($Arguments[0] -notin @('snapshots','restore')){throw 'Only result reads are permitted.'}
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$settings.ResticExe;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($key in @($psi.EnvironmentVariables.Keys)){if($key -like 'RESTIC_*'){$psi.EnvironmentVariables.Remove($key)}}
    $allArguments=@('--repo',$settings.Repository,'--no-lock','--cache-dir',"$ServiceRoot\Cache",'--json')+$Arguments
    $quoted=foreach($argument in $allArguments){
        if($argument -match '["\r\n]' -or $argument.EndsWith('\')){throw 'Unsupported command argument.'}
        '"'+$argument+'"'
    }
    $psi.Arguments=$quoted -join ' '
    $psi.EnvironmentVariables['RESTIC_PASSWORD']=$credential.ResultsPassword
    $psi.EnvironmentVariables['RESTIC_REST_USERNAME']=$credential.RestUsername
    $psi.EnvironmentVariables['RESTIC_REST_PASSWORD']=$credential.RestPassword
    $child=New-Object Diagnostics.Process;$child.StartInfo=$psi
    try{
        $null=$child.Start();$psi.EnvironmentVariables.Clear()
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        $child.WaitForExit();$text=$stdout.GetAwaiter().GetResult();$diagnostic=$stderr.GetAwaiter().GetResult()
        if($child.ExitCode -ne 0){throw "Results read failed (exit $($child.ExitCode)); will retry."}
        return $text
    }finally{$psi.EnvironmentVariables.Clear();$child.Dispose();$diagnostic=$null}
}
try{
    $protected=[IO.File]::ReadAllBytes("$ServiceRoot\credential.dpapi")
    $plainBytes=[Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    $credential=[Text.Encoding]::UTF8.GetString($plainBytes)|ConvertFrom-Json
    if($credential.ResultsRepository -ne $settings.Repository){throw 'Results repository identity mismatch.'}
    $snapshots=@((Invoke-ResultRead @('snapshots','--tag','office-media-result'))|ConvertFrom-Json)
    $retryCount=0
    foreach($snapshot in ($snapshots|Sort-Object time)){
      try{
        $jobTags=@($snapshot.tags|Where-Object{$_ -like 'job:*'})
        if($jobTags.Count -ne 1 -or $snapshot.id -notmatch '^[0-9a-f]{64}$'){throw 'Invalid published result metadata.'}
        $jobId=$jobTags[0].Substring(4)
        if($jobId -notmatch '^[a-z0-9][a-z0-9._-]{0,100}$'){throw 'Invalid result job ID.'}
        $receiptPath=Assert-SafePath (Join-Path $stateRoot ($snapshot.id+'.json')) $stateRoot
        $priorReceipt=$null
        if(Test-Path -LiteralPath $receiptPath){
            if(-not $projectDelivery){continue}
            $priorReceipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
            if($priorReceipt.ResultSnapshot -ne $snapshot.id -or $priorReceipt.JobId -ne $jobId){throw 'Existing receiver receipt identity mismatch.'}
        }
        if(@($snapshot.paths).Count -ne 1){throw 'Published result must have exactly one root.'}
        $snapshotPath=$snapshot.paths[0].Replace('\','/')
        if($snapshotPath -notmatch '^([A-Za-z]):/(.+)$'){throw 'Invalid result snapshot root.'}
        $snapshotPath='/'+$Matches[1]+'/'+$Matches[2]
        $incoming=Assert-SafePath (Join-Path $settings.OutputRoot ('.incoming\'+$snapshot.id)) $settings.OutputRoot
        $final=Resolve-OfficeDeliveryDestination -OutputRoot $settings.OutputRoot -JobId $jobId -SnapshotId $snapshot.id
        $alreadyPromoted=Test-Path -LiteralPath $final
        $placementPath=Join-Path $stateRoot ('placement-'+$snapshot.id+'.json')
        if($projectDelivery -and (Test-Path -LiteralPath $placementPath)){
            $placement=Get-Content -LiteralPath $placementPath -Raw|ConvertFrom-Json
            if($placement.ResultSnapshot -ne $snapshot.id -or $placement.JobId -ne $jobId){throw 'Project placement checkpoint identity mismatch.'}
            $placed=Assert-SafePath ([string]$placement.Destination) $settings.ActiveRoot
            if(Test-Path -LiteralPath $placed -PathType Container){
                $complete=Get-Content -LiteralPath (Join-Path $placed 'COMPLETE.json') -Raw|ConvertFrom-Json
                $projectRoot=Resolve-OfficeProjectOutputRoot -Complete $complete -Settings $settings
                $expected=Resolve-OfficeDeliveryDestination -OutputRoot $projectRoot -JobId $jobId -SnapshotId $snapshot.id
                if($placed -ne $expected){throw 'Placement checkpoint points at an unexpected project folder.'}
                $final=$placed;$alreadyPromoted=$true
            }
        }
        # A prior receipt may point at the old central layout or a project delivery.
        # Only generated job directories are ever eligible for relocation.
        if($priorReceipt -and (Test-Path -LiteralPath $priorReceipt.Destination -PathType Container)){
            $previous=[IO.Path]::GetFullPath([string]$priorReceipt.Destination)
            $central=Assert-SafePath (Join-Path $settings.OutputRoot $jobId) $settings.OutputRoot
            $centralVersion=Assert-SafePath (Join-Path $settings.OutputRoot ($jobId+'--'+$snapshot.id)) $settings.OutputRoot
            if($previous -eq $central -or $previous -eq $centralVersion){$null=Assert-SafePath $previous $settings.OutputRoot}
            else{$null=Assert-SafePath $previous $settings.ActiveRoot}
            $complete=Get-Content -LiteralPath (Join-Path $previous 'COMPLETE.json') -Raw|ConvertFrom-Json
            $projectRoot=Resolve-OfficeProjectOutputRoot -Complete $complete -Settings $settings
            $projectFinal=Resolve-OfficeDeliveryDestination -OutputRoot $projectRoot -JobId $jobId -SnapshotId $snapshot.id
            if($previous -eq $projectFinal){continue}
            if($previous -ne $central -and $previous -ne $centralVersion){throw 'Receipt does not point at a known generated delivery; preserving it.'}
            $final=$previous;$alreadyPromoted=$true
        }
        if(-not $alreadyPromoted){
            if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($settings.OutputRoot))).AvailableFreeSpace -lt ([long]$snapshot.summary.total_bytes_processed+2GB)){throw 'Insufficient source disk free space.'}
            New-Item -ItemType Directory -Path $incoming -Force|Out-Null
            Set-DeliveryStatus 'Receiving' $jobId
            $null=Invoke-ResultRead @('restore',($snapshot.id+':'+$snapshotPath),'--target',$incoming,'--verify','--overwrite','if-changed')
            @{ResultSnapshot=$snapshot.id}|ConvertTo-Json|Set-Content -LiteralPath "$incoming\DELIVERY.json"
        }
        $verifyRoot=if($alreadyPromoted){$final}else{$incoming}
        $complete=Get-Content -LiteralPath "$verifyRoot\COMPLETE.json" -Raw|ConvertFrom-Json
        if($projectDelivery){
            $projectRoot=Resolve-OfficeProjectOutputRoot -Complete $complete -Settings $settings
            $final=Resolve-OfficeDeliveryDestination -OutputRoot $projectRoot -JobId $jobId -SnapshotId $snapshot.id
            # Recovery after promotion but before the receipt write: use, verify and
            # acknowledge the exact existing result, never overwrite or nest into it.
            if((Test-Path -LiteralPath $final) -and $verifyRoot -ne $final){$verifyRoot=$final}
        }
        $delivery=Get-Content -LiteralPath "$verifyRoot\DELIVERY.json" -Raw|ConvertFrom-Json
        if($delivery.ResultSnapshot -ne $snapshot.id){
            throw 'Existing delivery belongs to another result snapshot; preserving it.'
        }
        $complete=Get-Content -LiteralPath "$verifyRoot\COMPLETE.json" -Raw|ConvertFrom-Json
        if(-not $complete.verified){throw 'Result completion marker missing verification.'}
        $manifest=@(Import-Csv -LiteralPath "$verifyRoot\Files-SHA256.csv")
        if($manifest.Count -ne ([int]$complete.proxy_files+[int]$complete.contact_sheets)){throw 'Delivery manifest count mismatch.'}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($row in $manifest){
            if($row.RelativePath -match '^[/\\]|(^|[/\\])\.\.?($|[/\\])|:'){throw 'Unsafe result manifest path.'}
            $file=Assert-SafePath (Join-Path $verifyRoot $row.RelativePath) $verifyRoot
            if(-not $seen.Add($file)){throw 'Duplicate delivery manifest path.'}
            if((Get-Item -LiteralPath $file).Length -ne [long]$row.Bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $row.SHA256){throw 'Delivered media checksum mismatch.'}
        }
        if($projectDelivery){Write-OfficeDeliveryJson $placementPath @{JobId=$jobId;ResultSnapshot=$snapshot.id;Destination=$final}}
        if($verifyRoot -ne $final){[IO.Directory]::Move($verifyRoot,$final)}
        Write-OfficeDeliveryJson $receiptPath @{JobId=$jobId;ResultSnapshot=$snapshot.id;Destination=$final;MediaFiles=$manifest.Count;VerifiedUtc=[DateTime]::UtcNow.ToString('o')}
        Set-DeliveryStatus 'Delivered' $final
      }catch{
        $retryCount++
        $retryId=if($snapshot.id -match '^[0-9a-f]{64}$'){$snapshot.id}else{'invalid-metadata'}
        @{ResultSnapshot=$snapshot.id;Error=$_.Exception.Message;RetryUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath "$stateRoot\retry-$retryId.json"
        Set-DeliveryStatus 'RetryPending' $_.Exception.Message
      }
    }
    if($retryCount){Set-DeliveryStatus 'RetryPending' ("$retryCount result snapshot(s) need retry; other verified deliveries are preserved.")}
    if(-not(Test-Path -LiteralPath $statusPath)){Set-DeliveryStatus 'Waiting' 'No new completed results.'}
}catch{Set-DeliveryStatus 'RetryPending' $_.Exception.Message;exit 1}
finally{if($plainBytes){[Array]::Clear($plainBytes,0,$plainBytes.Length)};$credential=$null;$protected=$null}
