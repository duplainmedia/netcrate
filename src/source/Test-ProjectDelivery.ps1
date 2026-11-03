#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OfficeMedia.Common.ps1')
$fixture=Join-Path $env:TEMP ('ProjectDeliveryTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
function Assert($condition,$message){if(-not $condition){throw $message}}
function Reject([scriptblock]$body){$blocked=$false;try{& $body|Out-Null}catch{$blocked=$true};Assert $blocked 'Unsafe or ambiguous placement was accepted.'}
try {
    $active=Join-Path $fixture 'Video Projects';$outbox=Join-Path $fixture 'Outbox'
    $project=Join-Path $active 'Example & project';$other=Join-Path $active 'Other'
    New-Item -ItemType Directory -Path $project,$other,$outbox -Force|Out-Null
    $source='a'*64;$result='b'*64
    $requests=@(@{SnapshotId=$source;ProjectPath='/D/Video Projects/Example & project';SourceComputer='SOURCE-PC';Repository='rest:http://backup.example:8000/sample-user/source-pc/';BackupExitCode=0;Kind='request';Version=1},@{SnapshotId=$source;ProjectPath='/D/Video Projects/Other';SourceComputer='SOURCE-PC';Repository='rest:http://backup.example:8000/sample-user/source-pc/';BackupExitCode=0;Kind='request';Version=1})
    for($i=0;$i -lt 2;$i++){$dir=Join-Path $outbox ((''+$i)*64);New-Item -ItemType Directory -Path $dir|Out-Null;$requests[$i]|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $dir 'request.json')}
    $settings=[pscustomobject]@{ActiveRoot=$active;RequestRoot=$outbox;LegacyProjects=@()}
    $complete=[pscustomobject]@{snapshot_id=$source;project='Example & project';verified=$true}
    $root=Resolve-OfficeProjectOutputRoot -Complete $complete -Settings $settings
    Assert ($root -eq (Join-Path $project 'Proxies')) 'Result was placed in the wrong project.'
    Assert (Test-Path -LiteralPath (Join-Path $root '.office-generated-media')) 'Generated folder lacks its backup-exclusion marker.'
    Assert (-not(Test-Path -LiteralPath (Join-Path $other 'Proxies'))) 'Another project in the same snapshot was touched.'
    $again=Resolve-OfficeProjectOutputRoot -Complete $complete -Settings $settings
    Assert ($again -eq $root) 'Repeated placement was not idempotent.'
    $bad=[pscustomobject]@{snapshot_id=('f'*64);project='Example & project';verified=$true}
    Reject {Resolve-OfficeProjectOutputRoot -Complete $bad -Settings $settings}
    $bad=[pscustomobject]@{snapshot_id=$source;project='../Other';verified=$true}
    Reject {Resolve-OfficeProjectOutputRoot -Complete $bad -Settings $settings}
    $complete.project='Other';New-Item -ItemType Directory -Path (Join-Path $other 'Proxies')|Out-Null
    'user media'|Set-Content -LiteralPath (Join-Path $other 'Proxies\keep.mov')
    Reject {Resolve-OfficeProjectOutputRoot -Complete $complete -Settings $settings}
    Assert ((Get-Content -LiteralPath (Join-Path $other 'Proxies\keep.mov')) -eq 'user media') 'Existing user media was changed.'
    $complete.project='Short historical name';$settings.LegacyProjects=@([pscustomobject]@{SnapshotId=$source;ProjectName='Example & project';DisplayName='Short historical name'})
    Assert ((Resolve-OfficeProjectOutputRoot -Complete $complete -Settings $settings) -eq $root) 'Exact historical mapping was not used.'
    $destination=Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId 'example-job' -SnapshotId $result
    New-Item -ItemType Directory -Path $destination|Out-Null
    @{ResultSnapshot=$result}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $destination 'DELIVERY.json')
    Assert ((Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId 'example-job' -SnapshotId ('c'*64)) -eq (Join-Path $root ('example-job--'+('c'*64)))) 'A newer publication would overwrite prior proxies.'
    'PASS: exact source/project mapping, multi-project snapshots, idempotence, traversal/unknown snapshot rejection, existing media protection, legacy mapping and version isolation.'
} finally {
    $resolved=(Resolve-Path -LiteralPath $fixture).ProviderPath
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^ProjectDeliveryTest-[a-f0-9]{32}$'){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
