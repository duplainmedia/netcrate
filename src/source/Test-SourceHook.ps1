$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('om-hook-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
New-Item -ItemType Directory -Path "$root\Tools","$root\Outbox","$root\State" -Force|Out-Null
Copy-Item "$PSScriptRoot\OfficeMediaAuto.psm1" "$root\Tools"
$before=$env:COMPUTERNAME
try{
    $env:COMPUTERNAME='SOURCE-PC'
    $hook=Join-Path $PSScriptRoot 'Queue-OfficeMediaAfterBackup.ps1'
    & $hook -ServiceRoot $root -BackupExitCode 3 -BackupJsonLogPath 'missing-is-fine-for-failed-backup' -ProjectPaths @('D:\Video Projects\Example')
    if(@(Get-ChildItem "$root\Outbox").Count){throw 'Failed backup queued proxies.'}
    ('{"message_type":"summary","snapshot_id":"'+('a'*64)+'"}')|Set-Content "$root\backup.jsonl"
    & $hook -ServiceRoot $root -BackupExitCode 0 -BackupJsonLogPath "$root\backup.jsonl" -ProjectPaths @('D:\Video Projects\Example')
    & $hook -ServiceRoot $root -BackupExitCode 0 -BackupJsonLogPath "$root\backup.jsonl" -ProjectPaths @('D:\Video Projects\Example')
    $items=@(Get-ChildItem "$root\Outbox" -Directory)
    if($items.Count -ne 1){throw 'Outbox is not idempotent.'}
    $request=Get-Content ($items[0].FullName+'\request.json') -Raw|ConvertFrom-Json
    if($request.SnapshotId -ne ('a'*64) -or $request.ProjectPath -ne '/D/Video Projects/Example'){throw 'Success hook selected wrong snapshot/project.'}
    'PASS: failed backup suppressed, exact successful snapshot/project queued, repeated hook idempotent.'
}finally{$env:COMPUTERNAME=$before}

