# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
$script:ProgressRoot='C:\ProgramData\NetCrate\Office'
function Start-OfficeProgress($Job,[switch]$OnlyIfMissing){
    try{
        $path="$script:ProgressRoot\ProgressState\Jobs\$($Job.JobId).json"
        if($OnlyIfMissing -and (Test-Path -LiteralPath $path)){return}
        $total=0
        try{if(Test-Path -LiteralPath $Job.InventoryPath){$total=@(Get-Content -LiteralPath $Job.InventoryPath -Raw|ConvertFrom-Json).Count}elseif(Test-Path -LiteralPath "$script:ProgressRoot\Jobs\$($Job.JobId)\footage.json"){$total=(Get-Content "$script:ProgressRoot\Jobs\$($Job.JobId)\footage.json" -Raw|ConvertFrom-Json).Clips}}catch{}
        $process=Get-Process -Id $PID
        $meta=@{JobId=$Job.JobId;AttemptId=[Guid]::NewGuid().ToString('N');Stage='Queued';TotalClips=[int]$total;CompletedClips=0;ProxyFilesCompleted=0;ContactSheetsCompleted=0;OwnerPid=$PID;OwnerStartedEpoch=([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()/1000.0;UpdatedEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0}
        New-Item -ItemType Directory -Path (Split-Path $path) -Force|Out-Null
        Write-AutoJson $path $meta
        Write-OfficeStageEvent $meta
    }catch{} # Progress must never change job success.
}
function Set-OfficeProgress([string]$JobId,[string]$Stage,$Complete=$null){
    try{
        $path="$script:ProgressRoot\ProgressState\Jobs\$JobId.json"
        $meta=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        try{
            $measured=Get-Content -LiteralPath "$script:ProgressRoot\ProgressState\Jobs\$JobId.telemetry.json" -Raw|ConvertFrom-Json
            if($measured.AttemptId -eq $meta.AttemptId){foreach($name in @('TotalClips','CompletedClips','ProxyFilesCompleted','ContactSheetsCompleted')){$meta.$name=$measured.$name}}
        }catch{}
        $changed=$meta.Stage -cne $Stage
        $meta.Stage=$Stage;$meta.UpdatedEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
        if($Complete){$meta.TotalClips=[int]$Complete.clips;$meta.CompletedClips=[int]$Complete.clips;$meta.ProxyFilesCompleted=[int]$Complete.proxy_files;$meta.ContactSheetsCompleted=[int]$Complete.contact_sheets}
        Write-AutoJson $path $meta
        if($changed){Write-OfficeStageEvent $meta}
    }catch{}
}
function Write-OfficeStageEvent($Meta){
    $directory="$script:ProgressRoot\ProgressState\Events\$($Meta.JobId)"
    New-Item -ItemType Directory -Path $directory -Force|Out-Null
    $stamp=([DateTime]::UtcNow.Ticks-621355968000000000)*100
    Write-AutoJson "$directory\$($stamp.ToString('D20'))-$([Guid]::NewGuid().ToString('N')).json" $Meta
}
function Start-OfficeProgressProcesses($Tools){
    try{
        foreach($name in @('Jobs','Publisher','Staging')){New-Item -ItemType Directory -Path "$script:ProgressRoot\ProgressState\$name" -Force|Out-Null}
        New-Item -ItemType Directory -Path "$script:ProgressRoot\ProgressPublish" -Force|Out-Null
        if(Test-Path -LiteralPath "$script:ProgressRoot\progress.stop"){return}
        # Each child holds its own singleton lock; scheduler restarts them after exit/reboot.
        foreach($entry in @(@($Tools.Python,@('-u',"$($Tools.Scripts)\progress_producer.py")),@("$($Tools.Scripts)\PowerShell\pwsh.exe",@('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-File',"$($Tools.Scripts)\OfficeMedia-ProgressPublisher.ps1")))){
            $psi=[Diagnostics.ProcessStartInfo]::new($entry[0]);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
            foreach($arg in $entry[1]){$psi.ArgumentList.Add($arg)}
            foreach($key in @($psi.Environment.Keys)){if($key -like 'RESTIC_*'){$null=$psi.Environment.Remove($key)}}
            $child=[Diagnostics.Process]::Start($psi);$child.Dispose();$psi.Environment.Clear()
        }
    }catch{
        try{Write-AutoJson "$script:ProgressRoot\Logs\progress-startup.json" @{State='RetryPending';Message='Progress startup failed; media worker continues.';CheckedUtc=[DateTime]::UtcNow.ToString('o')}}catch{}
    }
}
Export-ModuleMember -Function Start-OfficeProgress,Set-OfficeProgress,Start-OfficeProgressProcesses
