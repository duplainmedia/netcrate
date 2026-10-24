#requires -Version 7.0
# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
param([string]$Root='C:\ProgramData\NetCrate\Office',[switch]$Once)
$ErrorActionPreference='Stop'
Import-Module "$Root\Tools\OfficeMediaAuto.psm1" -Force
Import-Module "$Root\Tools\OfficeMediaResults.psm1" -Force
Import-Module "$Root\Tools\OfficeMediaProgressTransport.psm1" -Force
$state="$Root\ProgressState\Publisher"
New-Item -ItemType Directory -Path $state,"$Root\ProgressState\PublicLocks","$Root\ProgressState\Staging" -Force|Out-Null
try{$lock=[IO.File]::Open("$state\publisher.lock",'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{return}
try{
    do{
        $errorsCount=0;$sent=0
        foreach($folder in (Get-ChildItem -LiteralPath "$Root\ProgressPublish" -Directory -ErrorAction SilentlyContinue)){
            $validRecord=$false
            try{
                if($folder.Name -cnotmatch '^[a-f0-9]{64}$' -or $folder.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Invalid metadata folder.'}
                $files=@(Get-ChildItem -LiteralPath $folder.FullName -Force)
                if($files.Count -ne 1 -or $files[0].Name -cne 'progress.json' -or $files[0].PSIsContainer -or $files[0].Length -gt 32768 -or $files[0].Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Invalid metadata payload.'}
                $value=Get-Content -LiteralPath $files[0].FullName -Raw|ConvertFrom-Json
                $checkpoint="$state\$($folder.Name).json";$previous=$null
                if(Test-Path $checkpoint){try{$previous=Get-Content $checkpoint -Raw|ConvertFrom-Json}catch{}}
                $latestPath="$Root\ProgressState\Latest\$($folder.Name).json"
                if(Test-Path $latestPath){$latest=(Get-Content $latestPath -Raw|ConvertFrom-Json).Status;$value=$latest}
                $retryPath="$state\retry-$($folder.Name).json"
                # Transitions are durable; normal heartbeats coalesce. After an
                # outage the current latest status supersedes the stale backlog.
                if(-not(Test-Path $retryPath)){
                    $pending=@(Get-ChildItem "$Root\ProgressState\Pending\$($folder.Name)" -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name)
                    $candidates=@($pending|ForEach-Object{Get-Content $_.FullName -Raw|ConvertFrom-Json})
                    $value=Select-ProgressRecord $value $candidates $previous ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0)
                }
                Assert-ProgressRecord $value $folder.Name
                $validRecord=$true
                $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
                if(-not(Test-ProgressDue $value $previous $now)){continue}
                if(Test-Path $retryPath){try{$retry=Get-Content $retryPath -Raw|ConvertFrom-Json;if($retry.AttemptId -eq $value.AttemptId -and $retry.Stage -eq $value.Stage -and $now-$retry.LastAttemptEpoch -lt 30){$errorsCount++;continue}}catch{}}
                $publicLock=$null
                try{
                    $publicLock=[IO.File]::Open("$Root\ProgressState\PublicLocks\$($folder.Name).lock",'OpenOrCreate','ReadWrite','None')
                    $temp="$Root\ProgressState\Staging\$([Guid]::NewGuid().ToString('N')).writing"
                    $value|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $temp -Encoding UTF8
                    [IO.File]::Replace($temp,$files[0].FullName,[System.Management.Automation.Language.NullString]::Value)
                    $output=Invoke-OfficeMediaResult -Command backup -NativeTimeoutSeconds 15 -Arguments @('--host','WORKER-PC','--tag','office-media-progress','--tag',('request:'+$folder.Name),'--',$folder.FullName.Replace('\','/'))
                }finally{if($publicLock){$publicLock.Dispose()}}
                $summary=@($output -split "`n"|Where-Object{$_.Trim()}|ForEach-Object{$_|ConvertFrom-Json}|Where-Object message_type -eq summary)
                if($summary.Count -ne 1 -or $summary[0].snapshot_id -cnotmatch '^[a-f0-9]{64}$'){throw 'Native progress snapshot summary missing.'}
                Write-AutoJson $checkpoint @{State='Published';AttemptId=$value.AttemptId;Stage=$value.Stage;Sequence=$value.Sequence;PublishedEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0;SnapshotId=$summary[0].snapshot_id;NativeExitCode=0;RequestId=$folder.Name}
                if(Test-Path $retryPath){Remove-Item -LiteralPath $retryPath}
                $sent++
            }catch{
                $errorsCount++
                if($validRecord){try{Write-AutoJson "$state\retry-$($folder.Name).json" @{State='RetryPending';AttemptId=$value.AttemptId;Stage=$value.Stage;LastAttemptEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0;Message='Progress transport unavailable; latest status retained.'}}catch{}}
                # Never write native diagnostics or credential-loader exception text.
            }
        }
        Write-AutoJson "$Root\Logs\progress-publisher-health.json" @{State=$(if($errorsCount){'RetryPending'}else{'Ready'});Errors=$errorsCount;SentThisTick=$sent;User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;Pid=$PID;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
        if($Once){break}
        Start-Sleep -Seconds 2
    }while(-not(Test-Path -LiteralPath "$Root\progress.stop"))
}finally{$lock.Dispose()}
