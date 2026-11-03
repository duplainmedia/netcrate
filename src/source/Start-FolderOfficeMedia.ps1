#requires -Version 5.1
[CmdletBinding()]
param([string]$FolderPath=$env:OFFICE_MEDIA_FOLDER,[switch]$InspectOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLauncher.Common.ps1')
$lock=$null
try {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if($identity.Name -ne 'SOURCE-PC\sample-user' -or $identity.User.Value -ne 'S-1-5-21-100000000-200000000-300000000-1001'){throw 'Run this launcher on SOURCE-PC as sample-user.'}
    $wrapper='C:\Users\sample-user\OneDrive\Documents\Sample Studio\review-tools\Invoke-OfficeRestic.ps1'
    $control='C:\Users\sample-user\OneDrive\Documents\Sample Studio\backup-records\office-backup-queue-control.json'
    $excluded=@();if(Test-Path -LiteralPath $control){$excluded=@((Get-Content -LiteralPath $control -Raw|ConvertFrom-Json).ExcludedProjects)}
    $plan=Get-FolderMediaPlan -FolderPath $FolderPath -ExcludedProjects $excluded
    if($InspectOnly){$plan|ConvertTo-Json;exit 0}
    if(-not(Test-Path -LiteralPath $wrapper -PathType Leaf) -or -not(Test-Path -LiteralPath 'C:\ProgramData\OfficeMediaSource\config.json')){throw 'The automatic office media workflow is not installed completely.'}
    $lockRoot='C:\Users\sample-user\AppData\Local\OfficeBackup\LauncherLocks'
    New-Item -ItemType Directory -Path $lockRoot -Force|Out-Null
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$id=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($plan.ProjectPath.ToLowerInvariant()))).Replace('-','')}finally{$sha.Dispose()}
    try{$lock=[IO.File]::Open((Join-Path $lockRoot ($id+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'A backup of this project is already running. Leave its existing window open.'}
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class OfficeFolderBackupAwake { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags); }'
    [void][OfficeFolderBackupAwake]::SetThreadExecutionState([uint32]2147483649)
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    Write-Host ('Project: '+$plan.ProjectPath)
    Write-Host ('Video clips: '+$plan.VideoFiles+' (including subfolders)')
    Write-Host 'Backing up the project to the office. Leave this window open until the backup finishes.'
    $summary=$null;$lastPercent=-1
    & $wrapper -Operation backup -Arguments @('--json','--tag',('project:'+$plan.ProjectName),'--host','SOURCE-PC','--',$plan.ProjectPath.Replace('\','/')) | ForEach-Object {
        $entry=$null;try{$entry=$_|ConvertFrom-Json -ErrorAction Stop}catch{}
        if($entry){
            if($entry.message_type -eq 'summary'){$summary=$entry}
            elseif($entry.message_type -eq 'status'){
                $percent=[int][math]::Floor($entry.percent_done*100)
                if($percent -ge ($lastPercent+10)){Write-Host ('Backup progress: '+$percent+'%');$lastPercent=$percent}
            }
        }
    }
    $backupExit=$LASTEXITCODE
    if($backupExit -ne 0 -or -not $summary -or $summary.snapshot_id -notmatch '^[a-f0-9]{64}$'){throw 'The backup did not complete successfully. This backup has not started proxy generation.'}
    Write-Host ''
    Write-Host 'Backup completed.'
    Write-Host ('Snapshot: '+$summary.snapshot_id)
    $events=@(Get-ChildItem -LiteralPath 'C:\Users\sample-user\AppData\Local\OfficeBackup\Runs' -Filter '*.media-success.json' -File|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json}|Where-Object SnapshotId -eq $summary.snapshot_id)
    if($events.Count -ne 1 -or $events[0].State -ne 'Queued'){
        Write-Host 'The backup succeeded, but the media request is pending. Run this launcher again after checking the connection.' -ForegroundColor Yellow
        exit 2
    }
    Write-Host 'The request for proxies and contact sheets is queued. The office sender will pick it up automatically.'
    Write-Host ('Verified proxies and contact sheets will arrive in '+(Join-Path $plan.ProjectPath 'Proxies')+' when this computer is on and connected to NetBird.')
    Write-Host 'You can close this window now. Repeating this on unchanged footage will reuse the existing media job.'
    exit 0
} catch {
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host 'Keep NetBird connected and make sure the office computer is available.'
    exit 1
} finally {
    if('OfficeFolderBackupAwake' -as [type]){[void][OfficeFolderBackupAwake]::SetThreadExecutionState([uint32]2147483648)}
    if($lock){$lock.Dispose()}
}
