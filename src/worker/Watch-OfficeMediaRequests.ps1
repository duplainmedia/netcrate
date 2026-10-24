#requires -Version 7.0
# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
$root='C:\ProgramData\NetCrate\Office'
if(-not(Test-Path -LiteralPath "$root\auto-config.json")){return}
$config=Get-Content -LiteralPath "$root\auto-config.json" -Raw|ConvertFrom-Json
if(-not $config.Enabled){return}
Import-Module "$root\Tools\OfficeMediaAuto.psm1" -Force
Import-Module "$root\Tools\OfficeMediaPrimary.psm1" -Force
Import-Module "$root\Tools\OfficeMediaResults.psm1" -Force
$failures=0;$accepted=0
foreach($kind in @('request','delivery')){
    $tag='office-media-'+$kind
    $snapshots=@((Invoke-OfficeMediaResult -Command snapshots -Arguments @('--tag',$tag))|ConvertFrom-Json)
    foreach($snapshot in ($snapshots|Sort-Object time)){
        $permanent=$false;$statePath=$null
        try{
            if($snapshot.id -cnotmatch '^[a-f0-9]{64}$'){throw 'Malformed request snapshot identifier.'}
            $statePath="$root\AutoState\Requests\$($snapshot.id).json"
            if(Test-Path -LiteralPath $statePath){$old=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json;if($old.State -in @('Accepted','Deduplicated','Delivered','Rejected','IgnoredHistorical','NoVideo')){continue}}
            $permanent=$true
            if($snapshot.hostname -ine 'SOURCE-PC' -or @($snapshot.paths).Count -ne 1 -or $snapshot.summary.total_files_processed -ne 1 -or [long]$snapshot.summary.total_bytes_processed -gt 32768){throw 'Request snapshot origin, size or file count is invalid.'}
            $sourcePath=$snapshot.paths[0].Replace('\','/')
            if($sourcePath -cnotmatch '^C:/ProgramData/NetCrate/Source/Outbox/[a-f0-9]{64}$'){throw 'Request snapshot directory is outside the source outbox.'}
            $subtree='/C/'+$sourcePath.Substring(3)
            $incoming="$root\AutoState\Incoming\$($snapshot.id)"
            New-Item -ItemType Directory -Path $incoming -Force|Out-Null
            $permanent=$false
            $null=Invoke-OfficeMediaResult -Command restore -Arguments @(($snapshot.id+':'+$subtree),'--target',$incoming,'--verify','--overwrite','if-changed')
            $permanent=$true
            $payloadFile="$incoming\$kind.json"
            $actual=@(Get-ChildItem -LiteralPath $incoming -Force -Recurse -File)
            if($actual.Count -ne 1 -or -not(Test-Path -LiteralPath $payloadFile -PathType Leaf) -or (Get-Item -LiteralPath $payloadFile).Length -gt 32768 -or (Get-Item -LiteralPath $payloadFile).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Request payload files are invalid.'}
            $payload=Get-Content -LiteralPath $payloadFile -Raw|ConvertFrom-Json
            if($kind -eq 'delivery'){
                if($payload.Version -ne 1 -or $payload.Kind -ne 'delivery' -or $payload.SourceComputer -ine 'SOURCE-PC' -or $payload.JobId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,100}$' -or $payload.ResultSnapshot -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid delivery acknowledgement.'}
                $jobPath="$root\Queue\$($payload.JobId).json"
                if(-not(Test-Path -LiteralPath $jobPath)){throw 'Acknowledgement has no known job.'}
                $job=Get-Content -LiteralPath $jobPath -Raw|ConvertFrom-Json
                if($job.State -ne 'Published' -or $job.ResultSnapshot -cne $payload.ResultSnapshot){throw 'Acknowledgement does not match published results.'}
                $complete=Get-Content -LiteralPath ($job.OutputPath+'\COMPLETE.json') -Raw|ConvertFrom-Json
                if([int]$payload.MediaFiles -ne ([int]$complete.proxy_files+[int]$complete.contact_sheets)){throw 'Acknowledged media count differs from generated results.'}
                $job|Add-Member -NotePropertyName DeliveryConfirmed -NotePropertyValue $true -Force
                $job|Add-Member -NotePropertyName DeliveredUtc -NotePropertyValue (Get-AutoUtc $payload.VerifiedUtc).ToString('o') -Force
                Write-AutoJson $jobPath $job
                Write-AutoJson $statePath @{State='Delivered';JobId=$job.JobId;ResultSnapshot=$payload.ResultSnapshot;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
                continue
            }
            $null=Assert-AutoRequest $payload
            if((Get-AutoUtc $payload.CompletedUtc) -lt (Get-AutoUtc $config.AcceptAfterUtc)){
                Write-AutoJson $statePath @{State='IgnoredHistorical';CheckedUtc=[DateTime]::UtcNow.ToString('o')};continue
            }
            $permanent=$false
            $identity=Get-PrimaryFootage -SnapshotId $payload.SnapshotId -ProjectPath $payload.ProjectPath
            if($identity.Clips -eq 0){Write-AutoJson $statePath @{State='NoVideo';CheckedUtc=[DateTime]::UtcNow.ToString('o')};continue}
            $generationPath="$root\AutoState\Generations\$($identity.Fingerprint).json"
            if(Test-Path -LiteralPath $generationPath){
                $generation=Get-Content -LiteralPath $generationPath -Raw|ConvertFrom-Json
                if($generation.State -eq 'Published'){
                    Write-AutoJson $statePath @{State='Deduplicated';JobId=$generation.JobId;SourceSnapshot=$payload.SnapshotId;Fingerprint=$identity.Fingerprint;CheckedUtc=[DateTime]::UtcNow.ToString('o')};continue
                }
            }
            $jobId='auto-'+$identity.Fingerprint
            $jobRoot="$root\Jobs\$jobId";$jobPath="$root\Queue\$jobId.json"
            if(-not(Test-Path -LiteralPath $jobPath)){
                New-Item -ItemType Directory -Path $jobRoot -Force|Out-Null
                Write-AutoJson "$jobRoot\footage.json" $identity
                $proxySettings=Get-AutoProxySettings
                $job=[ordered]@{JobId=$jobId;ProjectName=($payload.ProjectPath -split '/')[-1];SnapshotId=$payload.SnapshotId;SnapshotPath=$payload.ProjectPath;FootageFingerprint=$identity.Fingerprint;ProxyRecipe=$proxySettings.RecipeId;ProxyScaleDivisor=$proxySettings.ScaleDivisor;ProxyBitDepth=$proxySettings.BitDepth;InventoryPath="$jobRoot\media-inventory.json";RestoreReport="$jobRoot\restore-verification.json";OutputPath="$jobRoot\Output";State='Queued';RequestedUtc=[DateTime]::UtcNow.ToString('o')}
                Write-AutoJson $jobPath $job
            }else{
                $job=Get-Content -LiteralPath $jobPath -Raw|ConvertFrom-Json
                if($job.FootageFingerprint -cne $identity.Fingerprint -or $job.SnapshotPath -cne $payload.ProjectPath){throw 'Existing automatic job identity mismatch.'}
            }
            Write-AutoJson $generationPath @{State=$job.State;JobId=$jobId;Fingerprint=$identity.Fingerprint;ProjectPath=$payload.ProjectPath}
            Write-AutoJson $statePath @{State='Accepted';JobId=$jobId;Fingerprint=$identity.Fingerprint;SourceSnapshot=$payload.SnapshotId;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
            $accepted++
        }catch{
            $failures++
            if($statePath){Write-AutoJson $statePath @{State=$(if($permanent){'Rejected'}else{'RetryPending'});Message=$_.Exception.Message;CheckedUtc=[DateTime]::UtcNow.ToString('o')}}
        }
    }
}
Write-AutoJson "$root\Logs\auto-status.json" @{Enabled=$true;AcceptedThisRun=$accepted;ErrorsThisRun=$failures;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
