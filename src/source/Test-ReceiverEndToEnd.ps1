#requires -Version 5.1
param([string]$ReceiverPath=(Join-Path $PSScriptRoot 'Receive-OfficeMedia.ps1'),[switch]$ProjectDelivery,[switch]$MigrateExisting)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
$restic='C:\Users\sample-user\AppData\Local\Microsoft\WinGet\Packages\restic.restic_Microsoft.Winget.Source_8wekyb3d8bbwe\restic_0.19.1_windows_amd64.exe'
$fixture=Join-Path $env:TEMP ('OfficeMediaIntegration-'+[guid]::NewGuid().ToString('N'))
$oldPassword=$env:RESTIC_PASSWORD
$oldCache=$env:RESTIC_CACHE_DIR
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $repository=Join-Path $fixture 'repository';$source=Join-Path $fixture 'source';$service=Join-Path $fixture 'service';$output=Join-Path $fixture 'output'
    New-Item -ItemType Directory -Path $source,$service,$output,(Join-Path $service 'State'),(Join-Path $service 'Cache') | Out-Null
    $active=Join-Path $fixture 'Video Projects';$project=Join-Path $active 'Example';$outbox=Join-Path $fixture 'Outbox';$sourceSnapshot='a'*64
    New-Item -ItemType Directory -Path $project,(Join-Path $outbox ('b'*64)) -Force|Out-Null
    'source stays intact'|Set-Content -LiteralPath (Join-Path $project 'original.mp4')
    @{SnapshotId=$sourceSnapshot;ProjectPath='/D/Video Projects/Example';Kind='request';Version=1;BackupExitCode=0;SourceComputer='SOURCE-PC';Repository='rest:http://backup.example:8000/sample-user/source-pc/'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $outbox (('b'*64)+'\request.json'))
    $env:RESTIC_PASSWORD=[guid]::NewGuid().ToString('N');$env:RESTIC_CACHE_DIR=Join-Path $fixture 'cache'
    $null=& $restic --repo $repository init
    if($LASTEXITCODE -ne 0){throw 'Synthetic repository initialization failed.'}
    $snapshots=@();$expectedHashes=@()
    for($version=1;$version -le 2;$version++) {
        ('synthetic proxy version '+$version)|Set-Content -LiteralPath (Join-Path $source 'proxy.mov')
        'synthetic contact sheet'|Set-Content -LiteralPath (Join-Path $source 'sheet.jpg')
        $rows=@(foreach($name in @('proxy.mov','sheet.jpg')) {$file=Get-Item -LiteralPath (Join-Path $source $name);[pscustomobject]@{RelativePath=$name;Bytes=$file.Length;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash}})
        $expectedHashes+=($rows|Where-Object RelativePath -eq 'proxy.mov').SHA256
        $rows|Export-Csv -LiteralPath (Join-Path $source 'Files-SHA256.csv') -NoTypeInformation
        @{verified=$true;proxy_files=1;contact_sheets=1;snapshot_id=$sourceSnapshot;project='Example'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $source 'COMPLETE.json')
        $lines=& $restic --repo $repository backup --json --tag office-media-result --tag job:synthetic-job -- $source
        if($LASTEXITCODE -ne 0){throw 'Synthetic result snapshot creation failed.'}
        $summary=$lines|ForEach-Object{$_|ConvertFrom-Json}|Where-Object message_type -eq summary|Select-Object -Last 1
        $snapshots+=$summary.snapshot_id
    }
    $settings=@{Repository=$repository;ResticExe=$restic;OutputRoot=$output;ProjectDeliveryEnabled=($ProjectDelivery -and -not $MigrateExisting);ActiveRoot=$active;RequestRoot=$outbox;LegacyProjects=@()}
    $settings|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $service 'settings.json')
    $record=@{ResultsRepository=$repository;ResultsPassword=$env:RESTIC_PASSWORD;RestUsername='synthetic';RestPassword='synthetic'}|ConvertTo-Json -Compress
    $bytes=[Text.Encoding]::UTF8.GetBytes($record)
    try {[IO.File]::WriteAllBytes((Join-Path $service 'credential.dpapi'),[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))}finally{[Array]::Clear($bytes,0,$bytes.Length);$record=$null}
    & $ReceiverPath -ServiceRoot $service
    if($MigrateExisting){$settings.ProjectDeliveryEnabled=$true;$settings|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $service 'settings.json');& $ReceiverPath -ServiceRoot $service}
    $receipts=@(foreach($snapshot in $snapshots){Get-Content -LiteralPath (Join-Path $service ('State\'+$snapshot+'.json')) -Raw|ConvertFrom-Json})
    if($receipts[0].Destination -eq $receipts[1].Destination){throw 'Different snapshots incorrectly reused the same delivered media.'}
    for($i=0;$i -lt 2;$i++) {
        if($receipts[$i].ResultSnapshot -ne $snapshots[$i] -or $receipts[$i].MediaFiles -ne 2){throw 'Snapshot receipt does not identify verified media.'}
        $actual=(Get-FileHash -LiteralPath (Join-Path $receipts[$i].Destination 'proxy.mov')).Hash
        if($actual -ne $expectedHashes[$i]){throw 'Delivered proxy does not match its own published snapshot.'}
        if($ProjectDelivery -and -not $receipts[$i].Destination.StartsWith((Join-Path $project 'Proxies')+'\')){throw 'Verified media did not arrive inside the original project.'}
    }
    & $ReceiverPath -ServiceRoot $service
    $deliveryRoot=if($ProjectDelivery){Join-Path $project 'Proxies'}else{$output}
    if(@(Get-ChildItem -LiteralPath $deliveryRoot -Directory | Where-Object Name -ne '.incoming').Count -ne 2){throw 'Repeat run produced extra output directories.'}
    if($ProjectDelivery){
        Remove-Item -LiteralPath (Join-Path $service ('State\'+$snapshots[0]+'.json'))
        & $ReceiverPath -ServiceRoot $service
        $recovered=Get-Content -LiteralPath (Join-Path $service ('State\'+$snapshots[0]+'.json')) -Raw|ConvertFrom-Json
        if($recovered.Destination -ne $receipts[0].Destination -or (Get-FileHash -LiteralPath (Join-Path $recovered.Destination 'proxy.mov')).Hash -ne $expectedHashes[0]){throw 'A missing receipt did not recover its promoted project delivery.'}
        if(@(Get-ChildItem -LiteralPath (Join-Path $output '.incoming') -Recurse -File).Count){throw 'Receipt recovery restored a duplicate of already promoted media.'}
        if((Get-Content -LiteralPath (Join-Path $project 'original.mp4')) -ne 'source stays intact'){throw 'Original source footage was changed.'}
    }
    'PASS: two actual Restic snapshots with the same job ID delivered separately; each content hash matched its own snapshot; repeat run preserved both deliveries.'
} finally {
    $env:RESTIC_PASSWORD=$oldPassword;$env:RESTIC_CACHE_DIR=$oldCache
    $resolved=(Resolve-Path -LiteralPath $fixture).ProviderPath
    $temporary=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^OfficeMediaIntegration-[a-f0-9]{32}$'){throw 'Unsafe integration fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
