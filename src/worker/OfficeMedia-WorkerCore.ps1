#requires -Version 7.0
# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
$root='C:\ProgramData\NetCrate\Office'
if([Security.Principal.WindowsIdentity]::GetCurrent().Name -ine 'WORKER-PC\worker-user'){throw 'Worker identity mismatch.'}
try{$workerLock=[IO.File]::Open("$root\worker.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{exit 0}
try{
$tools=Get-Content -LiteralPath "$root\tools.json" -Raw|ConvertFrom-Json
Import-Module "$($tools.Scripts)\OfficeMediaResults.psm1" -Force
try{
    $null=Invoke-OfficeMediaResult -Command snapshots -Arguments @('--tag','office-media-result')
    $primaryPassed=$false
    if((Test-Path -LiteralPath "$root\auto-config.json") -and (Get-Content -LiteralPath "$root\auto-config.json" -Raw|ConvertFrom-Json).Enabled){
        Import-Module "$($tools.Scripts)\OfficeMediaPrimary.psm1" -Force
        $null=Invoke-PrimaryRead @('snapshots');$primaryPassed=$true
    }
    @{State='Ready';ResultsAuthenticationPassed=$true;PrimaryRestoreReadPassed=$primaryPassed;User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;CheckedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content "$root\Logs\worker-health.json"
}catch{
    @{State='Error';Message=$_.Exception.Message;CheckedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content "$root\Logs\worker-health.json"
    exit 1
}
function Write-Job([string]$Path,$Job){$temp=$Path+'.writing';$Job|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $temp;Move-Item -LiteralPath $temp -Destination $Path -Force}
function Assert-JobPath([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    $allowed=@('C:\ProgramData\NetCrate\Office\Jobs\','C:\NetCrate\Workspace\work\sample-project\','C:\NetCrate\Workspace\outputs\Sample-Project-Full')
    if(-not @($allowed|Where-Object{$base=$_.TrimEnd('\');$full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Job path is outside media working storage.'}
    $cursor=$full
    while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse job path rejected.'};$cursor=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))}
    return $full
}
function Get-JobProxySettings($Job){
    $divisor=if($Job.PSObject.Properties.Name -contains 'ProxyScaleDivisor'){[int]$Job.ProxyScaleDivisor}else{4}
    if($divisor -notin @(2,4)){throw 'Unsupported queued proxy scale.'}
    $recipe=if($divisor -eq 2){'half-prores-v2'}else{'quarter-prores-v1'}
    if(($Job.PSObject.Properties.Name -contains 'ProxyRecipe') -and $Job.ProxyRecipe -cne $recipe){throw 'Queued recipe differs from its pinned scale.'}
    return @{Divisor=$divisor;Recipe=$recipe}
}
if(Test-Path -LiteralPath "$root\auto-config.json"){
    try{& "$($tools.Scripts)\Watch-OfficeMediaRequests.ps1"}catch{
        @{Enabled=$true;State='RetryPending';Message=$_.Exception.Message;CheckedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content "$root\Logs\auto-status.json"
    }
}
try{
    Import-Module "$($tools.Scripts)\OfficeMediaAuto.psm1" -Force
    Import-Module "$($tools.Scripts)\OfficeMediaProgress.psm1" -Force
    Start-OfficeProgressProcesses $tools
}catch{
    function Start-OfficeProgress {}
    function Set-OfficeProgress {}
}
foreach($waiting in (Get-ChildItem -LiteralPath "$root\Queue" -Filter '*.json' -File)){
    try{$pending=Get-Content $waiting.FullName -Raw|ConvertFrom-Json;if($pending.State -ne 'Published'){Start-OfficeProgress $pending -OnlyIfMissing}}catch{}
}
foreach($file in (Get-ChildItem -LiteralPath "$root\Queue" -Filter '*.json' -File|Sort-Object Name)){
    $job=$null
    try{
        $job=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
        if($job.State -eq 'Published'){
            try{
                $published=Get-Content -LiteralPath ($job.OutputPath+'\COMPLETE.json') -Raw|ConvertFrom-Json
                if($published.verified -and $published.snapshot_id -eq $job.SnapshotId -and $published.clips -eq $published.proxy_files -and $published.clips -eq $published.contact_sheets -and $job.ResultSnapshot -cmatch '^[a-f0-9]{64}$'){
                    Start-OfficeProgress $job -OnlyIfMissing
                    Set-OfficeProgress $job.JobId 'Complete' $published
                }
            }catch{}
            continue
        }
        if($job.JobId -notmatch '^[a-z0-9][a-z0-9._-]{0,100}$'){throw 'Unsafe job ID.'}
        $inventory=Assert-JobPath $job.InventoryPath;$receipt=Assert-JobPath $job.RestoreReport;$output=Assert-JobPath $job.OutputPath
        $proxySettings=Get-JobProxySettings $job
        Start-OfficeProgress $job
        $job.State='Processing';Write-Job $file.FullName $job
        $null=New-Item -ItemType Directory -Path "$root\Logs" -Force
        if($job.PSObject.Properties.Name -contains 'FootageFingerprint' -and -not(Test-Path -LiteralPath "$output\COMPLETE.json")){
            & "$($tools.Scripts)\Restore-AutoMediaProject.ps1" -JobPath $file.FullName *> "$root\Logs\$($job.JobId)-restore.log"
        }
        if(-not(Test-Path -LiteralPath "$output\COMPLETE.json")){
            Set-OfficeProgress $job.JobId 'Verifying'
            $oldProgressContext=$env:OFFICE_MEDIA_PROGRESS_CONTEXT
            try{
                $env:OFFICE_MEDIA_PROGRESS_CONTEXT="$root\ProgressState\Jobs\$($job.JobId).json"
                & $tools.Python "$($tools.Scripts)\run_media_batch.py" --inventory $inventory --restore-report $receipt --out $output --label $job.ProjectName --proxy-divisor $proxySettings.Divisor --proxy-recipe $proxySettings.Recipe *> "$root\Logs\$($job.JobId).log"
                if($LASTEXITCODE -ne 0){throw 'Media processing failed; inspect the job log. Verified clip states are preserved for retry.'}
            }finally{$env:OFFICE_MEDIA_PROGRESS_CONTEXT=$oldProgressContext}
        }
        Set-OfficeProgress $job.JobId 'Verifying'
        $complete=Get-Content -LiteralPath "$output\COMPLETE.json" -Raw|ConvertFrom-Json
        if(-not $complete.verified -or $complete.snapshot_id -ne $job.SnapshotId){throw 'Media completion marker does not match the requested snapshot.'}
        $completedDivisor=if($complete.PSObject.Properties.Name -contains 'proxy_scale_divisor'){[int]$complete.proxy_scale_divisor}else{4}
        $completedRecipe=if($complete.PSObject.Properties.Name -contains 'proxy_recipe'){$complete.proxy_recipe}else{'quarter-prores-v1'}
        if($completedDivisor -ne $proxySettings.Divisor -or $completedRecipe -cne $proxySettings.Recipe){throw 'Completed output uses another proxy recipe; existing versions preserved.'}
        $manifest=@(Import-Csv -LiteralPath "$output\Files-SHA256.csv")
        $clipCount=@(Get-Content -LiteralPath $inventory -Raw|ConvertFrom-Json).Count
        if($complete.clips -ne $clipCount -or $complete.proxy_files -ne $clipCount -or $complete.contact_sheets -ne $clipCount -or $manifest.Count -ne 2*$clipCount){throw 'Generated result count mismatch.'}
        foreach($row in $manifest){
            if($row.RelativePath -match '^[/\\]|(^|[/\\])\.\.?($|[/\\])|:'){throw 'Unsafe generated-file manifest path.'}
            $media=Assert-JobPath (Join-Path $output $row.RelativePath)
            if((Get-Item -LiteralPath $media).Length -ne [long]$row.Bytes -or (Get-FileHash -LiteralPath $media -Algorithm SHA256).Hash -ne $row.SHA256){throw 'Generated result checksum validation failed.'}
        }
        $job.State='Publishing';Write-Job $file.FullName $job
        Set-OfficeProgress $job.JobId 'Publishing' $complete
        # A failed backup can leave a partial snapshot. Only a successful backup's
        # own summary is accepted; retries may add a deduplicated snapshot.
        $backup=Invoke-OfficeMediaResult -Command backup -Arguments @('--host','WORKER-PC-MEDIA','--tag','office-media-result','--tag',('job:'+$job.JobId),$output)
        $summary=@($backup -split "`n"|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{$_.message_type -eq 'summary'})
        if($summary.Count -ne 1 -or $summary[0].snapshot_id -notmatch '^[0-9a-f]{64}$'){throw 'Successful result snapshot ID missing.'}
        $job|Add-Member -NotePropertyName ResultSnapshot -NotePropertyValue $summary[0].snapshot_id -Force
        $job.State='Published';Write-Job $file.FullName $job
        if($job.PSObject.Properties.Name -contains 'FootageFingerprint'){
            Import-Module "$($tools.Scripts)\OfficeMediaAuto.psm1" -Force
            Write-AutoJson "$root\AutoState\Generations\$($job.FootageFingerprint).json" @{State='Published';JobId=$job.JobId;Fingerprint=$job.FootageFingerprint;ProjectPath=$job.SnapshotPath;ResultSnapshot=$job.ResultSnapshot;PublishedUtc=[DateTime]::UtcNow.ToString('o')}
        }
        Set-OfficeProgress $job.JobId 'Complete' $complete
    }catch{
        if($job){Set-OfficeProgress $job.JobId 'Failed'}
        if($job){$job.State='RetryPending';$job|Add-Member -NotePropertyName LastError -NotePropertyValue $_.Exception.Message -Force;Write-Job $file.FullName $job}
    }
}
}finally{$workerLock.Dispose()}
