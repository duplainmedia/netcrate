# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('netcrate-watch-test-'+[Guid]::NewGuid().ToString('N'))
foreach($dir in @('Tools','Queue','Jobs','Logs','Fixtures','AutoState\Requests','AutoState\Generations')){New-Item -ItemType Directory -Path "$root\$dir" -Force|Out-Null}
Copy-Item "$PSScriptRoot\..\..\src\worker\OfficeMediaAuto.psm1" "$root\Tools"
@{Enabled=$true;AcceptAfterUtc=[DateTime]::UtcNow.AddHours(-1).ToString('o')}|ConvertTo-Json|Set-Content "$root\auto-config.json"
@{Fingerprint=('9'*64);Clips=2;Bytes=20;Files=@();Recipe='test'}|ConvertTo-Json|Set-Content "$root\identity.json"
@'
function Get-PrimaryFootage {param($SnapshotId,$ProjectPath) Get-Content "$PSScriptRoot\..\identity.json" -Raw|ConvertFrom-Json}
Export-ModuleMember Get-PrimaryFootage
'@|Set-Content "$root\Tools\OfficeMediaPrimary.psm1"
@'
function Invoke-OfficeMediaResult {param($Command,$Arguments)
 if($Command -eq 'snapshots'){$tag=$Arguments[1];$items=@(Get-Content "$PSScriptRoot\..\snapshots.json" -Raw|ConvertFrom-Json|Where-Object{$_.tags -contains $tag});return ConvertTo-Json -InputObject $items -Depth 8}
 if($Command -eq 'restore'){$id=$Arguments[0].Split(':')[0];$target=$Arguments[[Array]::IndexOf($Arguments,'--target')+1];Get-ChildItem "$PSScriptRoot\..\Fixtures\$id"|Copy-Item -Destination $target -Force;return ''}
 throw 'Unexpected result write in watcher test.'
}
Export-ModuleMember Invoke-OfficeMediaResult
'@|Set-Content "$root\Tools\OfficeMediaResults.psm1"
$snaps=@();$ids=@(('a'*64),('b'*64),('c'*64))
foreach($id in $ids){
 New-Item -ItemType Directory -Path "$root\Fixtures\$id"|Out-Null
 $path=if($id -eq ('c'*64)){'/D/Projects/../escape'}else{'/D/Projects/Example'}
 @{Version=1;Kind='request';SourceComputer='SOURCE-PC';Repository='rest:https://backup.example:8000/sample-user/source-pc/';BackupExitCode=0;SnapshotId=('f'*64);ProjectPath=$path;CompletedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content "$root\Fixtures\$id\request.json"
 $snaps+=@{id=$id;hostname='SOURCE-PC';paths=@("C:\ProgramData\NetCrate\Source\Outbox\$id");tags=@('office-media-request');summary=@{total_bytes_processed=800;total_files_processed=1};time=[DateTime]::UtcNow.ToString('o')}
}
ConvertTo-Json -InputObject $snaps -Depth 8|Set-Content "$root\snapshots.json"
$text=Get-Content "$PSScriptRoot\..\..\src\worker\Watch-OfficeMediaRequests.ps1" -Raw
$text=$text.Replace("'C:\ProgramData\NetCrate\Office'",("'"+$root+"'"))
$text|Set-Content "$root\watch.ps1"
& "$root\watch.ps1"
if(@(Get-ChildItem "$root\Queue" -Filter '*.json').Count -ne 1){throw 'Duplicate request created multiple jobs.'}
$bad=Get-Content "$root\AutoState\Requests\$($ids[2]).json" -Raw|ConvertFrom-Json
if($bad.State -ne 'Rejected'){throw 'Malformed path was not isolated/rejected.'}
& "$root\watch.ps1"
if(@(Get-ChildItem "$root\Queue" -Filter '*.json').Count -ne 1){throw 'Restart duplicated an accepted job.'}
$jobPath=(Get-ChildItem "$root\Queue" -Filter '*.json')[0].FullName
$job=Get-Content $jobPath -Raw|ConvertFrom-Json
$job.State='Published';$job|Add-Member ResultSnapshot ('8'*64)
New-Item -ItemType Directory -Path $job.OutputPath -Force|Out-Null
@{proxy_files=2;contact_sheets=2}|ConvertTo-Json|Set-Content ($job.OutputPath+'\COMPLETE.json')
$job|ConvertTo-Json|Set-Content $jobPath
foreach($id in @(('d'*64),('e'*64))){
    New-Item -ItemType Directory -Path "$root\Fixtures\$id"|Out-Null
    $count=if($id -eq ('d'*64)){3}else{4}
    @{Version=1;Kind='delivery';SourceComputer='SOURCE-PC';JobId=$job.JobId;ResultSnapshot=('8'*64);MediaFiles=$count;VerifiedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content "$root\Fixtures\$id\delivery.json"
    $snaps+=@{id=$id;hostname='SOURCE-PC';paths=@("C:\ProgramData\NetCrate\Source\Outbox\$id");tags=@('office-media-delivery');summary=@{total_bytes_processed=800;total_files_processed=1};time=[DateTime]::UtcNow.ToString('o')}
}
ConvertTo-Json -InputObject $snaps -Depth 8|Set-Content "$root\snapshots.json"
& "$root\watch.ps1"
$badAck=Get-Content "$root\AutoState\Requests\$('d'*64).json" -Raw|ConvertFrom-Json
$goodAck=Get-Content "$root\AutoState\Requests\$('e'*64).json" -Raw|ConvertFrom-Json
$delivered=Get-Content $jobPath -Raw|ConvertFrom-Json
if($badAck.State -ne 'Rejected' -or $goodAck.State -ne 'Delivered' -or -not $delivered.DeliveryConfirmed -or $delivered.State -ne 'Published'){throw 'Delivery acknowledgement binding failed.'}
'PASS: new job, deduplication, invalid request isolation, restart idempotence, matching delivery confirmation and wrong-count ACK rejection.'

Remove-Item -LiteralPath $root -Recurse -Force
