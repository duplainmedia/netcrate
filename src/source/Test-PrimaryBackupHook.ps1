param([string]$HelperPath=(Join-Path $PSScriptRoot 'PrimaryBackupMediaHook.ps1'))
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $HelperPath){. $HelperPath}
$root=Join-Path $env:TEMP ('PrimaryHookTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $log=Join-Path $root 'backup.jsonl'
    $snapshot='a'*64
    ('{"message_type":"summary","snapshot_id":"'+$snapshot+'"}')|Set-Content -LiteralPath $log
    if((Get-PrimaryBackupSnapshot -BackupExitCode 0 -BackupJsonLogPath $log) -ne $snapshot){throw 'Exact current successful snapshot was not selected.'}
    foreach($code in @(1,3,10)) {if($null -ne (Get-PrimaryBackupSnapshot -BackupExitCode $code -BackupJsonLogPath 'missing')){throw 'Unsuccessful backup selected a snapshot.'}}
    Add-Content -LiteralPath $log ('{"message_type":"summary","snapshot_id":"'+('b'*64)+'"}')
    $rejected=$false;try{$null=Get-PrimaryBackupSnapshot -BackupExitCode 0 -BackupJsonLogPath $log}catch{$rejected=$true};if(-not $rejected){throw 'Multiple summaries accepted.'}
    '{"message_type":"status"}'|Set-Content -LiteralPath $log
    $rejected=$false;try{$null=Get-PrimaryBackupSnapshot -BackupExitCode 0 -BackupJsonLogPath $log}catch{$rejected=$true};if(-not $rejected){throw 'Missing summary accepted.'}
    $metadata=Join-Path $root 'snapshot.jsonl'
    @(
      @{type='file';path='/D/Video Projects/ProjectOne/camera/a.MOV'},
      @{type='file';path='/D/Video Projects/ProjectOne/camera/b.mp4'},
      @{type='file';path='/D/Video Projects/ProjectTwo/deep/clip.MXF'},
      @{type='file';path='/D/02_Delivered/Old/clip.MOV'},
      @{type='file';path='/D/Video Projects/Notes/readme.txt'},
      @{type='dir';path='/D/Video Projects/Empty.MOV'}
    )|ForEach-Object{$_|ConvertTo-Json -Compress}|Set-Content -LiteralPath $metadata
    $paths=@(Get-PrimarySnapshotProjects -MetadataPath $metadata -ExcludedProjects @('ProjectTwo'))
    if($paths.Count -ne 1 -or $paths[0] -ne '/D/Video Projects/ProjectOne'){throw 'Snapshot-based project selection or exclusion failed.'}
    $wrapper=Join-Path $PSScriptRoot 'Invoke-OfficeRestic.ps1'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
    $catch=$ast.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Extent.Text -like '*State=''HookError''*'},$true)|Select-Object -First 1
    if(-not $catch){throw 'Real wrapper hook boundary was not found.'}
    $body=$catch.Body.Extent.Text;$handler=[scriptblock]::Create($body.Substring(1,$body.Length-2))
    & {
        $Operation='backup';$result=0
        function Set-Content {throw 'Synthetic failure writing the error record.'}
        try {throw 'Synthetic media hook failure.'} catch {& $handler 3>$null}
    }
    'PASS: exact successful snapshot, nonzero exits, missing/duplicate summaries, snapshot-derived direct projects, video filtering, exclusions, and failure-log I/O isolation.'
} finally {
    $resolved=(Resolve-Path -LiteralPath $root).ProviderPath;$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^PrimaryHookTest-[a-f0-9]{32}$'){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
