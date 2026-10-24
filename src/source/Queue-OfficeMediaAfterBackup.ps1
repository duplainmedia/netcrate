#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][int]$BackupExitCode,[string]$BackupJsonLogPath,[string[]]$ProjectPaths,[string]$ServiceRoot='C:\ProgramData\OfficeMediaSource')
$ErrorActionPreference='Stop'
if($BackupExitCode -ne 0){'Backup did not finish successfully; no proxy requests queued.';return}
if($env:COMPUTERNAME -ine 'SOURCE-PC'){throw 'Source hook is for SOURCE-PC.'}
Import-Module "$ServiceRoot\Tools\OfficeMediaAuto.psm1" -Force
try{
    if(-not $ProjectPaths.Count -or -not(Test-Path -LiteralPath $BackupJsonLogPath -PathType Leaf) -or (Get-Item -LiteralPath $BackupJsonLogPath).Length -gt 64MB){throw 'Successful backup JSON log and exact backed-up project paths are required.'}
    $lines=Get-Content -LiteralPath $BackupJsonLogPath -Raw
    $requests=@(foreach($path in $ProjectPaths){
        $canonical=$path.Replace('\','/').TrimEnd('/')
        if($canonical -cmatch '^D:/(.*)$'){$canonical='/D/'+$Matches[1]}
        New-AutoBackupRequest -BackupExitCode $BackupExitCode -BackupJsonLines $lines -ProjectPath $canonical
    })
    foreach($request in $requests){
        $id=Get-AutoHash ($request.SnapshotId+'|'+$request.ProjectPath)
        $directory="$ServiceRoot\Outbox\$id"
        New-Item -ItemType Directory -Path $directory -Force|Out-Null
        if(-not(Test-Path -LiteralPath "$directory\request.json")){Write-AutoJson "$directory\request.json" $request}
    }
    'Queued '+$requests.Count+' successful footage-backup request(s). The sender retries until WORKER-PC accepts transport.'
}catch{
    Write-AutoJson "$ServiceRoot\State\enqueue-error.json" @{State='Error';Message=$_.Exception.Message;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
    throw
}
