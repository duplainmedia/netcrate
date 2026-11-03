#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($name in @('Configuration','Credentials','Process')) { Import-Module (Join-Path $PSScriptRoot "NetCrate.$name.psm1") }

# Maintenance has a stricter local binding than normal worker settings, which
# can also describe a remote URI. Never create or repair storage here.
function Get-NetCrateMaintenanceContext {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$InstallationId,[int]$ConfigTimeoutSeconds=120)
    $rootPath=Assert-NetCrateLocalPath $Root
    $owner=Get-NetCrateOwner $rootPath
    if($owner.Role -cne 'Worker' -or $owner.InstallationId -cne $InstallationId){throw 'Open storage controls on the owning Backup Server.'}
    $settings=Import-NetCrateSettings ([IO.Path]::Combine($rootPath,'settings.json')) Worker
    if($settings.InstallationId -cne $owner.InstallationId -or -not $settings.StateRoot.Equals($rootPath,[StringComparison]::OrdinalIgnoreCase)){throw 'The storage settings differ from the owner.'}
    $binding=Read-NetCrateJson ([IO.Path]::Combine($rootPath,'repositories.json')) -MaximumBytes 16384
    if($binding.Version -ne 1 -or $binding.InstallationId -cne $owner.InstallationId){throw 'The repository binding differs from the owner.'}
    $storage=Assert-NetCrateLocalPath $binding.StorageRoot
    $repoRoot=Assert-NetCrateLocalPath ([IO.Path]::Combine($storage,'NetCrate-'+$owner.InstallationId))
    if(-not $repoRoot.Equals($binding.RepositoryRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Directory]::Exists($repoRoot)){throw 'The bound backup folder is unavailable.'}
    $marker=Read-NetCrateJson ([IO.Path]::Combine($repoRoot,'netcrate-owner.json')) -MaximumBytes 16384
    if($marker.Version -ne 1 -or $marker.InstallationId -cne $owner.InstallationId){throw 'The storage owner marker differs from the installation.'}
    $secret=Unprotect-NetCrateRecord $rootPath repositories
    if(-not $secret.StorageRoot.Equals($storage,[StringComparison]::OrdinalIgnoreCase)){throw 'The protected storage binding differs from the installation.'}
    foreach($name in @('Primary','Results')){
        $leaf=if($name -ceq 'Primary'){'originals'}else{'results'}
        $path=Assert-NetCrateLocalPath ([IO.Path]::Combine($repoRoot,'editing',$leaf))
        $saved=[string]$binding.($name+'Path');$id=[string]$binding.($name+'Id')
        if(-not $path.Equals($saved,[StringComparison]::OrdinalIgnoreCase) -or -not $path.Equals([string]$settings.Repositories.$name.Uri,[StringComparison]::OrdinalIgnoreCase) -or $id -cnotmatch '^[a-f0-9]{64}$' -or $id -cne $settings.Repositories.$name.Id -or -not [IO.File]::Exists([IO.Path]::Combine($path,'config'))){throw 'A local repository binding is invalid.'}
        $password=[string]$secret.($name+'Password')
        if(-not $password -or $password.Length -gt 1024){throw 'The protected repository key is invalid.'}
        $result=Invoke-NetCrateProcess $settings.Tools.Restic @('--repo',$path,'--no-cache','cat','config') @{RESTIC_PASSWORD=$password} -TimeoutSeconds $ConfigTimeoutSeconds
        if($result.ExitCode -ne 0){throw 'The backup repository could not be verified.'}
        $config=$result.Output | ConvertFrom-Json
        if($config.id -cne $id){throw 'The actual repository identity differs from the binding.'}
    }
    if($binding.PrimaryId -ceq $binding.ResultsId){throw 'The repositories must be distinct.'}
    return [pscustomobject]@{Owner=$owner;Settings=$settings;Binding=$binding;Secrets=$secret}
}
function Assert-MaintenanceJsonUnique($Element) {
    if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object){
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()){
            if(-not $seen.Add($property.Name)){throw 'A storage record contains duplicate fields.'}
            Assert-MaintenanceJsonUnique $property.Value
        }
    } elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){foreach($item in $Element.EnumerateArray()){Assert-MaintenanceJsonUnique $item}}
}
function Invoke-MaintenanceRestic($Context,[string]$Name,[string[]]$Arguments) {
    $password=$Context.Secrets.($Name+'Password')
    $result=Invoke-NetCrateProcess $Context.Settings.Tools.Restic (@('--repo',$Context.Binding.($Name+'Path'),'--no-cache')+$Arguments) @{RESTIC_PASSWORD=$password} -TimeoutSeconds 120
    if($result.ExitCode -ne 0){throw 'The backup metadata could not be read. Reconnect the storage and retry.'}
    return $result.Output
}
function Assert-MaintenanceResultTree($Context,$Result,[string]$Base,[string]$Manifest,[long]$Clips) {
    $wire=Invoke-MaintenanceRestic $Context Results @('ls','--json','--long','--recursive',$Result.id,$Base)
    $nodes=@($wire -split '\r?\n'|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json}|Where-Object {$_.PSObject.Properties.Name -ccontains 'type'})
    if($nodes.Count -gt 100000){throw 'A Results file list is too large.'}
    $seen=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($node in $nodes){
        if($node.path -ceq $Base -and $node.type -ceq 'dir'){continue}
        if(-not $node.path.StartsWith($Base+'/',[StringComparison]::Ordinal) -or $node.type -cnotin @('file','dir')){throw 'A Results snapshot contains unsupported paths.'}
        $relative=Assert-NetCrateRelativePath $node.path.Substring($Base.Length+1)
        if($seen.ContainsKey($relative)){throw 'A Results snapshot contains colliding paths.'};$seen.Add($relative,$node)
    }
    foreach($name in @('COMPLETE.json','Files-SHA256.csv')){if(-not $seen.ContainsKey($name) -or $seen[$name].type -cne 'file' -or $seen[$name].size -gt 4MB){throw 'Result metadata is missing or too large.'}}
    $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null=$expected.Add('COMPLETE.json');$null=$expected.Add('Files-SHA256.csv')
    $rows=@($Manifest|ConvertFrom-Csv)
    if($rows.Count -ne (2*$Clips+1)){throw 'The Results manifest has an invalid media count.'}
    foreach($row in $rows){
        if(@($row.PSObject.Properties).Count -ne 3 -or @($row.PSObject.Properties.Name|Where-Object {$_ -cnotin @('Path','SHA256','Bytes')}).Count){throw 'The Results manifest has unsupported fields.'}
        $null=Assert-NetCrateRelativePath $row.Path
        $size=0L
        if(-not $expected.Add($row.Path) -or $row.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or -not [long]::TryParse([string]$row.Bytes,[ref]$size) -or $size -lt 0 -or -not $seen.ContainsKey($row.Path) -or $seen[$row.Path].type -cne 'file' -or $seen[$row.Path].size -ne $size){throw 'The Results manifest differs from its snapshot.'}
    }
    if(-not $expected.Contains('media_index.json')){throw 'The Results manifest has no media index.'}
    foreach($entry in $seen.GetEnumerator()){if($entry.Value.type -ceq 'file' -and -not $expected.Contains($entry.Key)){throw 'A Results snapshot contains an undeclared file.'}}
}
function Convert-MaintenanceSnapshotPath([string]$Path) {
    if($Path -cmatch '^/[A-Z]/'){$Path=$Path.Substring(1,1)+':'+$Path.Substring(2).Replace('/','\')}
    if($Path -cnotmatch '^[A-Za-z]:[\\/].+' -or $Path.Substring(3) -match '[\\/]{2}'){throw 'A backup has an unsupported source path.'}
    $relative=$Path.Substring(3).Replace('\','/');$null=Assert-NetCrateRelativePath $relative
    return '/'+$Path.Substring(0,1).ToUpperInvariant()+'/'+$relative
}
function Assert-MaintenancePreviewLimit([int]$Eligible,[int]$Candidates) {
    if($Eligible -gt 256 -or $Candidates -gt 256){throw [InvalidOperationException]::new('netcrate-preview-limit')}
}
function Select-MaintenanceCandidates([object[]]$Eligible,$Protected,[int]$Count) {
    $candidates=[Collections.Generic.List[string]]::new()
    foreach($group in @($Eligible|Group-Object {$_.Host.ToUpperInvariant()+'|'+$_.Path.ToUpperInvariant()})) {
        $ordered=@($group.Group|Sort-Object @{Expression='Time';Descending=$true},@{Expression='Id';Descending=$true})
        for($index=$Count;$index -lt $ordered.Count;$index++){if(-not $Protected.Contains($ordered[$index].Id)){$candidates.Add($ordered[$index].Id)}}
    }
    return $candidates.ToArray()
}
function Get-MaintenanceInventory($Context,[int]$Count) {
    if($Count -lt 1 -or $Count -gt 10000){throw 'Choose a valid number of backups to keep.'}
    $primaryWire=Invoke-MaintenanceRestic $Context Primary @('snapshots','--json')
    $resultsWire=Invoke-MaintenanceRestic $Context Results @('snapshots','--json')
    $snapshots=@($primaryWire|ConvertFrom-Json);$results=@($resultsWire|ConvertFrom-Json)
    if($snapshots.Count -gt 20000 -or $results.Count -gt 20000){throw 'The storage inventory is too large for this version.'}
    # Accept the ordinary setup acknowledgement only after strict source signature,
    # owner and request binding. Other formats remain a fail-closed condition.
    $protected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($results.Count){
        Import-Module (Join-Path $PSScriptRoot 'NetCrate.Pairing.psm1')
        Import-Module (Join-Path $PSScriptRoot 'NetCrate.Protocol.psm1')
        $peer=Unprotect-NetCrateRecord $Context.Owner.Root runtime-peer
        $pending=Unprotect-NetCrateRecord $Context.Owner.Root inbound-request
        if($pending.Request.RequestId -cnotmatch '^[a-f0-9]{32}$' -or $pending.Request.RecipientId -cnotmatch '^[a-f0-9]{32}$' -or $pending.Request.RecipientId -ceq $Context.Owner.InstallationId){throw 'The protected source pairing is invalid.'}
        $peerKey=[Security.Cryptography.RSA]::Create()
        try {$peerKey.ImportFromPem($peer.PublicKey);if($peerKey.KeySize -ne 3072){throw 'The protected source key is invalid.'}}finally{$peerKey.Dispose()}
        $requests=@{};$associations=[Collections.Generic.List[object]]::new();$progressRecords=[Collections.Generic.List[object]]::new();$deliveryRecords=[Collections.Generic.List[object]]::new();$resultData=@{};$resultsComplete=@{};$matchedResults=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $ownKey=Unprotect-NetCrateRecord $Context.Owner.Root identity-key
        $rsa=[Security.Cryptography.RSA]::Create()
        try {$rsa.ImportFromPem($ownKey.PrivateKey);if($rsa.KeySize -ne 3072){throw 'The worker identity key is invalid.'};$workerPublic=$rsa.ExportSubjectPublicKeyInfoPem()}finally{$rsa.Dispose()}
        foreach($result in $results){
            $resultTags=@($result.tags)
            if($resultTags.Count -eq 1 -and $resultTags[0] -cmatch '^netcrate-result-auto-[a-f0-9]{64}$'){
                if($result.id -cnotmatch '^[a-f0-9]{64}$' -or $result.hostname -cne $Context.Settings.WorkerComputer -or @($result.paths).Count -ne 1 -or $resultData.ContainsKey($result.id)){throw 'A Results snapshot has an invalid binding.'}
                $null=Convert-MaintenanceSnapshotPath $result.paths[0]
                $resultData[$result.id]=$result
                continue
            }
            if($result.id -cnotmatch '^[a-f0-9]{64}$' -or @($result.paths).Count -ne 1 -or @($result.tags).Count -ne 1 -or @($result.tags)[0] -cnotin @('netcrate-pairing-ack','netcrate-request','netcrate-association','netcrate-progress','netcrate-delivery-ack')){throw 'Storage dependency records need verification before retention can run.'}
            $kind=([string]@($result.tags)[0]).Substring(9)
            $expectedHost=if($kind -cin @('association','progress')){$Context.Settings.WorkerComputer}else{$Context.Settings.SourceComputer}
            if($result.hostname -cne $expectedHost){throw 'A storage record has the wrong signer.'}
            $selector=Convert-MaintenanceSnapshotPath $result.paths[0]
            $wire=Invoke-MaintenanceRestic $Context Results @('dump',$result.id,$selector)
            if([Text.Encoding]::UTF8.GetByteCount($wire) -gt 262144){throw 'A storage record is too large.'}
            $doc=[System.Text.Json.JsonDocument]::Parse($wire)
            try {Assert-MaintenanceJsonUnique $doc.RootElement}finally{$doc.Dispose()}
            $record=$wire|ConvertFrom-Json
            if(@($record.PSObject.Properties).Count -ne 2 -or @($record.PSObject.Properties.Name|Where-Object {$_ -cnotin @('Data','Signature')}).Count){throw 'A signed storage record is malformed.'}
            $data=$record.Data
            $public=if($kind -cin @('association','progress')){$workerPublic}else{$peer.PublicKey}
            Assert-PairingSignature $public $data $record.Signature
            if($kind -ceq 'pairing-ack'){
                $recordId=Get-NetCrateHash $pending.Request.RequestId
                if(@($data.PSObject.Properties).Count -ne 5 -or @($data.PSObject.Properties.Name|Where-Object {$_ -cnotin @('Version','Kind','RequestId','SourceId','ServerId')}).Count -or $data.Version -ne 1 -or $data.Kind -cne 'pairing-ack' -or $data.RequestId -cne $pending.Request.RequestId -or $data.SourceId -cne $pending.Request.RecipientId -or $data.ServerId -cne $Context.Owner.InstallationId){throw 'The pairing acknowledgement differs from this installation.'}
            } elseif($kind -ceq 'request') {
                $recordId=Get-NetCrateRequestId $data.SnapshotId $data.ProjectPath $data.Recipe
                $null=Test-NetCrateRequest $data $recordId $Context.Settings
                if($requests.ContainsKey($recordId) -and (ConvertTo-NetCrateCanonicalJson $requests[$recordId]) -cne (ConvertTo-NetCrateCanonicalJson $data)){throw 'Signed request records conflict.'}
                $requests[$recordId]=$data
                $null=$protected.Add($data.SnapshotId)
            } else {
                $recordId=[string]$data.RequestId
                if($recordId -cnotmatch '^[a-f0-9]{64}$'){throw 'An association identity is invalid.'}
                if($kind -ceq 'association'){$associations.Add($data)}elseif($kind -ceq 'progress'){$progressRecords.Add($data)}else{$deliveryRecords.Add($data)}
            }
            $expected='/Outbox/'+$kind+'/'+$recordId+'/record.json'
            if(-not $selector.EndsWith($expected,[StringComparison]::Ordinal)){throw 'A storage record has an invalid path.'}
        }
        foreach($progress in $progressRecords){
            $names=@('Version','Kind','RequestId','SnapshotId','Recipe','FootageFingerprint','State','UpdatedUtc')
            if(@($progress.PSObject.Properties).Count -ne 8 -or @($progress.PSObject.Properties.Name|Where-Object {$_ -cnotin $names}).Count -or $progress.Version -ne 2 -or $progress.Kind -cne 'progress' -or $progress.State -cnotin @('Processing','NeedsAttention') -or -not $requests.ContainsKey($progress.RequestId)){throw 'A worker progress record is invalid or has no request.'}
            $request=$requests[$progress.RequestId]
            if($progress.SnapshotId -cne $request.SnapshotId -or $progress.Recipe -cne $request.Recipe -or $progress.FootageFingerprint -cne $request.FootageFingerprint -or ([DateTimeOffset]$progress.UpdatedUtc).ToUniversalTime() -gt [DateTimeOffset]::UtcNow.AddMinutes(10)){throw 'A worker progress record differs from its request.'}
            $null=$protected.Add($progress.SnapshotId)
        }
        foreach($association in $associations){
            if(-not $requests.ContainsKey($association.RequestId)){throw 'A signed association has no matching request.'}
            $null=Test-NetCrateAssociation $association $requests[$association.RequestId] $Context.Settings
            if(-not $resultData.ContainsKey($association.ResultSnapshotId)){throw 'An association has no matching Results snapshot.'}
            $result=$resultData[$association.ResultSnapshotId]
            if(@($result.tags)[0] -cne ('netcrate-result-'+$association.JobId)){throw 'A Results snapshot has the wrong generation tag.'}
            $base=Convert-MaintenanceSnapshotPath $result.paths[0]
            $completion=Invoke-MaintenanceRestic $Context Results @('dump',$result.id,($base+'/COMPLETE.json'))
            $manifest=Invoke-MaintenanceRestic $Context Results @('dump',$result.id,($base+'/Files-SHA256.csv'))
            if([Text.Encoding]::UTF8.GetByteCount($completion) -gt 4MB -or [Text.Encoding]::UTF8.GetByteCount($manifest) -gt 4MB){throw 'Result evidence is too large.'}
            $completionHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($completion))).ToLowerInvariant()
            $manifestHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifest))).ToLowerInvariant()
            if($completionHash -cne $association.CompletionSHA256 -or $manifestHash -cne $association.ResultManifestSHA256){throw 'Result evidence hashes differ from the signed association.'}
            $doc=[System.Text.Json.JsonDocument]::Parse($completion)
            try {Assert-MaintenanceJsonUnique $doc.RootElement}finally{$doc.Dispose()}
            $complete=$completion|ConvertFrom-Json
            foreach($field in @('JobId','GenerationSnapshotId','ProjectPath','Recipe','FootageFingerprint','ResultManifestSHA256')){if($complete.$field -cne $association.$field){throw 'Result evidence differs from its association.'}}
            if(($complete.Clips -isnot [int] -and $complete.Clips -isnot [long]) -or $complete.Clips -lt 0){throw 'Result evidence has an invalid media count.'}
            Assert-MaintenanceResultTree $Context $result $base $manifest ([long]$complete.Clips)
            $resultsComplete[$association.ResultSnapshotId]=$complete
            $null=$matchedResults.Add($association.ResultSnapshotId)
            $null=$protected.Add($association.RequestedSnapshotId);$null=$protected.Add($association.GenerationSnapshotId)
        }
    }
    if($results.Count -and $matchedResults.Count -ne $resultData.Count){throw 'A Results snapshot has no verified association.'}
    if($results.Count){
        foreach($ack in $deliveryRecords){
            $names=@('Version','Kind','RequestId','RequestedSnapshotId','GenerationSnapshotId','ResultSnapshotId','JobId','Recipe','FootageFingerprint','MediaFiles')
            if(@($ack.PSObject.Properties).Count -ne 10 -or @($ack.PSObject.Properties.Name|Where-Object {$_ -cnotin $names}).Count -or $ack.Version -ne 2 -or $ack.Kind -cne 'delivery-ack' -or ($ack.MediaFiles -isnot [int] -and $ack.MediaFiles -isnot [long]) -or $ack.MediaFiles -lt 0){throw 'A delivery acknowledgement is invalid.'}
            $matching=@($associations|Where-Object { $a=$_;@('RequestId','RequestedSnapshotId','GenerationSnapshotId','ResultSnapshotId','JobId','Recipe','FootageFingerprint')|Where-Object {$ack.$_ -cne $a.$_} | Measure-Object | Where-Object Count -EQ 0 })
            if(-not $matching.Count -or -not $resultsComplete.ContainsKey($ack.ResultSnapshotId) -or $ack.MediaFiles -ne (2 * $resultsComplete[$ack.ResultSnapshotId].Clips)){throw 'A delivery acknowledgement has no matching signed association and result.'}
            $null=$protected.Add($ack.RequestedSnapshotId);$null=$protected.Add($ack.GenerationSnapshotId)
        }
    }
    $localEvidence=[Collections.Generic.List[string]]::new();$localBytes=0
    foreach($folder in @('WorkerJobs','Published','Generations')) {
        $path=[IO.Path]::Combine($Context.Owner.Root,$folder)
        if(-not [IO.Directory]::Exists($path)){continue}
        $entries=@([IO.Directory]::EnumerateFileSystemEntries($path)|Sort-Object)
        if($entries.Count -gt 20000){throw 'There are too many dependency records.'}
        foreach($file in $entries){
            $null=Assert-NetCrateLocalPath $file
            if(-not [IO.File]::Exists($file) -or [IO.Path]::GetExtension($file) -cne '.json'){throw 'A dependency entry is unsupported.'}
            $name=[IO.Path]::GetFileNameWithoutExtension($file)
            if($name -cnotmatch '^[a-f0-9]{64}$'){throw 'A dependency record identity is invalid.'}
            $item=Read-NetCrateJson $file -MaximumBytes 262144
            $raw=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8);$localBytes += [Text.Encoding]::UTF8.GetByteCount($raw)
            if($localBytes -gt 8MB){throw 'Dependency evidence is too large.'}
            $localEvidence.Add($folder+'/'+$name+':'+$raw)
            if($folder -ceq 'WorkerJobs'){
                $fields=@('State','RequestId','ProjectPath','SnapshotId','UpdatedUtc','RetryAfterUtc','Output')
                if(@($item.PSObject.Properties).Count -ne 7 -or @($item.PSObject.Properties.Name|Where-Object {$_ -cnotin $fields}).Count -or $item.RequestId -cne $name -or $item.State -cnotin @('Processing','Published','Delivered','NeedsAttention') -or -not $requests.ContainsKey($name)){throw 'A worker job has incomplete dependency evidence.'}
                $request=$requests[$name]
                if($item.SnapshotId -cne $request.SnapshotId -or $item.ProjectPath -cne $request.ProjectPath){throw 'A worker job differs from its request.'}
                $null=[DateTimeOffset]$item.UpdatedUtc;$null=[DateTimeOffset]$item.RetryAfterUtc
                $null=$protected.Add($item.SnapshotId)
            } else {
                $association=if($folder -ceq 'Published'){$item}else{$item.Association}
                if($folder -ceq 'Generations' -and (@($item.PSObject.Properties).Count -ne 2 -or $item.PSObject.Properties.Name -cnotcontains 'Output' -or $item.PSObject.Properties.Name -cnotcontains 'Association' -or $association.FootageFingerprint -cne $name)){throw 'A generation dependency is invalid.'}
                if($folder -ceq 'Published' -and $association.RequestId -cne $name){throw 'A published dependency has the wrong identity.'}
                $matching=@($associations|Where-Object {(ConvertTo-NetCrateCanonicalJson $_) -ceq (ConvertTo-NetCrateCanonicalJson $association)})
                if(-not $matching.Count){throw 'A local association has no matching signed evidence.'}
                $null=$protected.Add($association.RequestedSnapshotId);$null=$protected.Add($association.GenerationSnapshotId)
            }
        }
    }    $primaryIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($snapshot in $snapshots){if($snapshot.id -cnotmatch '^[a-f0-9]{64}$' -or -not $primaryIds.Add($snapshot.id)){throw 'The originals inventory contains invalid identities.'}}
    foreach($id in $protected){if(-not $primaryIds.Contains($id)){throw 'A dependency names a missing original snapshot.'}}
    $eligible=[Collections.Generic.List[object]]::new()
    foreach($s in $snapshots) {
        $tags=@($s.tags)
        if($tags -cnotcontains 'netcrate-v2-originals' -or $tags -cnotcontains 'netcrate-folder-originals'){continue}
        if($s.id -cnotmatch '^[a-f0-9]{64}$' -or $s.hostname -cne $Context.Settings.SourceComputer -or @($s.paths).Count -ne 1 -or $tags -ccontains 'netcrate-originals' -or $tags -ccontains 'netcrate-backup-receipt' -or $tags -ccontains 'netcrate-proxies' -or @($tags|Where-Object {$_ -cnotin @('netcrate-v2-originals','netcrate-folder-originals')}).Count){throw 'An originals snapshot has conflicting metadata.'}
        $path=Convert-MaintenanceSnapshotPath $s.paths[0];$active=Convert-MaintenanceSnapshotPath $Context.Settings.ActiveRoot
        if(-not ($path.Equals($active,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($active.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase))){throw 'An originals snapshot is outside the configured source folder.'}
        $matches=@($snapshots|Where-Object {@($_.tags) -ccontains ('netcrate-receipt-'+$s.id)})
        if($matches.Count -eq 0){continue}
        if($matches.Count -ne 1){throw 'A completed folder backup has conflicting receipts.'}
        $rs=$matches[0]
        if($rs.id -cnotmatch '^[a-f0-9]{64}$' -or $rs.hostname -cne $s.hostname -or @($rs.paths).Count -ne 1 -or @($rs.tags) -cnotcontains 'netcrate-backup-receipt' -or @($rs.tags).Count -ne 2){throw 'A backup receipt has an invalid binding.'}
        $selector=Convert-MaintenanceSnapshotPath $rs.paths[0]
        if(-not $selector.EndsWith('/BackupReceipts/'+$s.id+'.json',[StringComparison]::Ordinal)){throw 'A backup receipt has an invalid path.'}
        $wire=Invoke-MaintenanceRestic $Context Primary @('dump',$rs.id,$selector)
        if([Text.Encoding]::UTF8.GetByteCount($wire) -gt 16384){throw 'A backup receipt is too large.'}
        $doc=[System.Text.Json.JsonDocument]::Parse($wire)
        try {Assert-MaintenanceJsonUnique $doc.RootElement}finally{$doc.Dispose()}
        $receipt=$wire|ConvertFrom-Json
        $fields=@('Version','Kind','RepositoryId','SourceComputer','Project','SnapshotId','BackupMode','JobId','BackupCompletedUtc')
        if(@($receipt.PSObject.Properties).Count -ne 9 -or @($receipt.PSObject.Properties.Name|Where-Object {$_ -cnotin $fields}).Count -or $receipt.Version -ne 1 -or $receipt.Kind -cne 'backup-receipt' -or $receipt.RepositoryId -cne $Context.Binding.PrimaryId -or $receipt.SourceComputer -cne $s.hostname -or $receipt.SnapshotId -cne $s.id -or $receipt.BackupMode -cne 'Folder' -or $receipt.JobId -cnotmatch '^[a-zA-Z0-9_-]{1,128}$' -or -not (Convert-MaintenanceSnapshotPath $receipt.Project).Equals($path,[StringComparison]::OrdinalIgnoreCase)){throw 'A backup receipt does not match its snapshot.'}
        $time=([DateTimeOffset]$receipt.BackupCompletedUtc).ToUniversalTime()
        if($time -gt [DateTimeOffset]::UtcNow.AddMinutes(10)){throw 'A backup receipt has a future completion time.'}
        $eligible.Add([pscustomobject]@{Id=$s.id;Path=$path;Host=$s.hostname;Time=$time})
    }
    Assert-MaintenancePreviewLimit $eligible.Count 0
    $candidates=@(Select-MaintenanceCandidates $eligible.ToArray() $protected $Count)
    Assert-MaintenancePreviewLimit $eligible.Count $candidates.Count
    return [pscustomobject]@{Candidates=$candidates;Eligible=$eligible.ToArray();Protected=@($protected);SnapshotCount=$snapshots.Count;PrimaryWire=$primaryWire;ResultsWire=$resultsWire;LocalEvidence=$localEvidence.ToArray()}
}
function Get-MaintenanceFingerprint($Inventory) {
    $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach($part in @('NetCrate-maintenance-v1',$Inventory.PrimaryWire,$Inventory.ResultsWire)+@($Inventory.LocalEvidence)){
            $bytes=[Text.Encoding]::UTF8.GetBytes([string]$part)
            $length=[BitConverter]::GetBytes([long]$bytes.Length)
            $hash.AppendData($length);$hash.AppendData($bytes)
        }
        return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally {$hash.Dispose()}
}
function Get-MaintenanceCleanupPrior($Context,[string]$Id='') {
    $folder=[IO.Path]::Combine($Context.Owner.Root,'Maintenance','Requests')
    $eligible=@(); if([IO.Directory]::Exists($folder)) { foreach($file in [IO.Directory]::EnumerateFiles($folder,'*.json')) {
        $r=Read-NetCrateJson $file -MaximumBytes 32768
        if($r.Action -cne 'ApplyRetention' -or $r.InstallationId -cne $Context.Owner.InstallationId) {continue}
        if(($r.State -ceq 'Running' -and $r.PSObject.Properties.Name -ccontains 'Step' -and $r.Step -ceq 'ForgetStarted') -or ($r.State -ceq 'NeedsAttention' -and $r.PSObject.Properties.Name -ccontains 'Code' -and $r.Code -ceq 'forget-uncertain')) {throw 'A previous forget is uncertain. Review storage before cleanup.'}
        if($r.State -ceq 'NeedsAttention' -and $r.PSObject.Properties.Name -ccontains 'Code' -and $r.Code -ceq 'prune-interrupted' -and $r.Step -ceq 'PruneStarted' -and $r.PSObject.Properties.Name -cnotcontains 'CleanupOf' -and $r.PSObject.Properties.Name -cnotcontains 'CleanupOperationId') {
            if($r.OperationId -cnotmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFileNameWithoutExtension($file) -cne $r.OperationId -or $r.PreviewId -cnotmatch '^[a-f0-9]{32}$' -or $r.Confirm -isnot [bool] -or -not $r.Confirm) {throw 'A previous cleanup journal is invalid.'}
            $prior=Read-NetCrateJson ([IO.Path]::Combine($Context.Owner.Root,'Maintenance','Previews',$r.PreviewId+'.json')) -MaximumBytes 262144
            if($prior.Version -ne 1 -or $prior.PreviewId -cne $r.PreviewId -or $prior.Policy -cne 'KeepLatestPerFolder' -or $prior.InstallationId -cne $Context.Owner.InstallationId -or $prior.PrimaryId -cne $Context.Binding.PrimaryId -or $prior.ResultsId -cne $Context.Binding.ResultsId -or $prior.Used -isnot [bool] -or -not $prior.Used -or @($prior.Candidates).Count -eq 0 -or @($prior.Candidates).Count -gt 256 -or @($prior.Candidates|Where-Object {$_ -cnotmatch '^[a-f0-9]{64}$'}).Count) {throw 'The previous forget cannot be verified.'}
            $eligible+=@($r)
        }
    }}
    if($eligible.Count -ne 1 -or ($Id -and $eligible[0].OperationId -cne $Id)) {throw 'No unique verified previous forget is available for cleanup.'}
    return $eligible[0]
}
function New-MaintenancePreview($Context,[string]$Policy,[int]$Count) {
    if($Policy -cnotin @('KeepAll','KeepLatestPerFolder','CompleteCleanup')){throw 'Choose a supported retention policy.'}
    $prior=if($Policy -ceq 'CompleteCleanup'){Get-MaintenanceCleanupPrior $Context}else{$null}
    if($prior){$Count=1}
    $inventory=if($Policy -ceq 'KeepAll'){$null}else{Get-MaintenanceInventory $Context $Count}
    if($prior){$old=Read-NetCrateJson ([IO.Path]::Combine($Context.Owner.Root,'Maintenance','Previews',$prior.PreviewId+'.json'));$present=@($inventory.PrimaryWire|ConvertFrom-Json|ForEach-Object {$_.id});if(@($old.Candidates|Where-Object {$_ -cin $present}).Count){throw 'The previous forget is not reflected in storage.'}}
    $created=[DateTimeOffset]::UtcNow
    $fingerprint=if($inventory){Get-MaintenanceFingerprint $inventory}else{[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('keep-all'))).ToLowerInvariant()}
    $items=@();if($inventory){$items=@(foreach($item in $inventory.Eligible){
        $candidate=$Policy -cne 'CompleteCleanup' -and $item.Id -cin $inventory.Candidates
        $path=$item.Path.Substring(1,1)+':'+$item.Path.Substring(2).Replace('/','\')
        [pscustomobject]@{SnapshotId=$item.Id;Project=$path;BackupCompletedUtc=$item.Time.ToString('o');Candidate=$candidate;Reason=if($item.Id -cin $inventory.Protected){'Protected dependency'}else{'Latest retained'}}
    })}
    $newest='';if($inventory){$retained=@($inventory.Eligible|Where-Object {$Policy -ceq 'CompleteCleanup' -or $_.Id -cnotin $inventory.Candidates}|Sort-Object Time -Descending|Select-Object -First 1);if($retained.Count){$newest=$retained[0].Time.ToString('o')}}
    $candidateIds=@();if($inventory -and $Policy -cne 'CompleteCleanup'){$candidateIds=@($inventory.Candidates|Where-Object {$null -ne $_})}
    $preview=[ordered]@{Version=1;PreviewId=[guid]::NewGuid().ToString('N');InstallationId=$Context.Owner.InstallationId;PrimaryId=$Context.Binding.PrimaryId;ResultsId=$Context.Binding.ResultsId;Policy=$Policy;Count=$Count;CreatedUtc=$created.ToString('o');ExpiresUtc=$created.AddMinutes(15).ToString('o');Fingerprint=$fingerprint;Candidates=$candidateIds;Items=$items;EligibleCount=if($inventory){@($inventory.Eligible).Count}else{0};ProtectedCount=if($inventory){$inventory.SnapshotCount-$candidateIds.Count}else{0};NewestRetainedUtc=$newest;Used=$false}
    if($prior){$preview['PriorOperationId']=$prior.OperationId}
    $folder=Set-NetCratePrivateDirectory ([IO.Path]::Combine($Context.Owner.Root,'Maintenance','Previews'))
    Write-NetCrateJson ([IO.Path]::Combine($folder,$preview.PreviewId+'.json')) $preview
    return [pscustomobject]$preview
}
function Test-MaintenancePreview($Context,[string]$PreviewId,[DateTimeOffset]$Now) {
    if($PreviewId -cnotmatch '^[a-f0-9]{32}$'){throw 'Choose a current storage preview.'}
    $file=[IO.Path]::Combine($Context.Owner.Root,'Maintenance','Previews',$PreviewId+'.json')
    $preview=Read-NetCrateJson $file -MaximumBytes 262144
    if($preview.Version -ne 1 -or $preview.PreviewId -cne $PreviewId -or $preview.InstallationId -cne $Context.Owner.InstallationId -or $preview.PrimaryId -cne $Context.Binding.PrimaryId -or $preview.ResultsId -cne $Context.Binding.ResultsId -or $preview.Policy -cnotin @('KeepAll','KeepLatestPerFolder','CompleteCleanup') -or $preview.Used -isnot [bool] -or $preview.Used -or $preview.Fingerprint -cnotmatch '^[a-f0-9]{64}$'){throw 'This preview is invalid or already used. Create a new preview.'}
    $created=([DateTimeOffset]$preview.CreatedUtc).ToUniversalTime();$expires=([DateTimeOffset]$preview.ExpiresUtc).ToUniversalTime()
    if($expires -ne $created.AddMinutes(15) -or $Now.ToUniversalTime() -lt $created -or $Now.ToUniversalTime() -ge $expires){throw 'This preview expired. Create a new preview.'}
    $ids=@($preview.Candidates)
    if($ids.Count -gt 256 -or @($ids|Where-Object {$_ -cnotmatch '^[a-f0-9]{64}$'}).Count -or @($ids|Sort-Object -Unique).Count -ne $ids.Count){throw 'The preview candidate list is invalid.'}
    if($preview.Policy -ceq 'KeepAll'){
        if($ids.Count){throw 'Keep all cannot remove backups.'}
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('keep-all'))).ToLowerInvariant();$currentIds=@()
    }else{
        if(($preview.Count -isnot [int] -and $preview.Count -isnot [long]) -or $preview.Count -lt 1 -or $preview.Count -gt 10000){throw 'The preview policy is invalid.'}
        $inventory=Get-MaintenanceInventory $Context ([int]$preview.Count)
        $digest=Get-MaintenanceFingerprint $inventory
        $currentIds=@(if($preview.Policy -cne 'CompleteCleanup'){$inventory.Candidates})
        if($preview.Policy -ceq 'CompleteCleanup'){$null=Get-MaintenanceCleanupPrior $Context $preview.PriorOperationId}
        $items=@($preview.Items)
        if($items.Count -ne @($inventory.Eligible).Count -or $preview.EligibleCount -ne $items.Count -or $preview.ProtectedCount -ne ($inventory.SnapshotCount-$currentIds.Count)){throw 'The displayed preview differs from storage. Create a new preview.'}
        foreach($original in $inventory.Eligible){
            $match=@($items|Where-Object SnapshotId -CEQ $original.Id)
            $expectedPath=$original.Path.Substring(1,1)+':'+$original.Path.Substring(2).Replace('/','\')
            $expectedCandidate=$original.Id -cin $currentIds
            $expectedReason=if($original.Id -cin $inventory.Protected){'Protected dependency'}else{'Latest retained'}
            if($match.Count -ne 1 -or $match[0].Project -cne $expectedPath -or $match[0].Candidate -isnot [bool] -or $match[0].Candidate -ne $expectedCandidate -or $match[0].Reason -cne $expectedReason -or ([DateTimeOffset]$match[0].BackupCompletedUtc).ToUniversalTime() -ne $original.Time){throw 'The displayed preview differs from storage. Create a new preview.'}
        }
        $retained=@($inventory.Eligible|Where-Object {$_.Id -cnotin $currentIds}|Sort-Object Time -Descending|Select-Object -First 1)
        if(($retained.Count -eq 0 -and $preview.NewestRetainedUtc) -or ($retained.Count -and (-not $preview.NewestRetainedUtc -or ([DateTimeOffset]$preview.NewestRetainedUtc).ToUniversalTime() -ne $retained[0].Time))){throw 'The displayed preview differs from storage. Create a new preview.'}
    }
    if($digest -cne $preview.Fingerprint -or (($ids|Sort-Object) -join ',') -cne (($currentIds|Sort-Object) -join ',')){throw 'Storage changed since this preview. Create a new preview.'}
    return $preview
}
function Test-MaintenancePreviewForCleanup($Context,$Preview) {
    $null=Get-MaintenanceCleanupPrior $Context $Preview.PriorOperationId
    $inventory=Get-MaintenanceInventory $Context ([int]$Preview.Count)
    if((Get-MaintenanceFingerprint $inventory) -cne $Preview.Fingerprint -or [DateTimeOffset]::UtcNow -ge ([DateTimeOffset]$Preview.ExpiresUtc).ToUniversalTime()) {throw 'Storage changed since this cleanup preview.'}
}
# Runtime calls this only while it owns its worker mutex and has stopped its
# endpoint. Do not expose this function through the desktop action bridge.
function Invoke-MaintenanceApply($Context,$Operation,[string]$OperationFile) {
    if($Operation.Action -cne 'ApplyRetention' -or $Operation.Confirm -isnot [bool] -or -not $Operation.Confirm -or $Operation.InstallationId -cne $Context.Owner.InstallationId){throw 'A deliberate confirmation is required.'}
    $preview=Test-MaintenancePreview $Context $Operation.PreviewId ([DateTimeOffset]::UtcNow)
    $previewPath=[IO.Path]::Combine($Context.Owner.Root,'Maintenance','Previews',$preview.PreviewId+'.json')
    $preview.Used=$true;Write-NetCrateJson $previewPath $preview
    $Operation | Add-Member -NotePropertyName Step -NotePropertyValue 'Confirmed' -Force
    Write-NetCrateJson $OperationFile $Operation
    $ids=@($preview.Candidates)
    if($preview.Policy -ceq 'CompleteCleanup') {
        $Operation | Add-Member -NotePropertyName CleanupOf -NotePropertyValue $preview.PriorOperationId -Force
        $null=Test-MaintenancePreviewForCleanup $Context $preview
        $Operation.Step='PruneStarted'; Write-NetCrateJson $OperationFile $Operation
        try {
            $result=Invoke-NetCrateProcess $Context.Settings.Tools.Restic @('--repo',$Context.Binding.PrimaryPath,'--no-cache','prune') @{RESTIC_PASSWORD=$Context.Secrets.PrimaryPassword} -TimeoutSeconds 86400
            if($result.ExitCode -ne 0){throw 'Prune did not finish.'}
            $priorPath=[IO.Path]::Combine($Context.Owner.Root,'Maintenance','Requests',$preview.PriorOperationId+'.json')
            $prior=Get-MaintenanceCleanupPrior $Context $preview.PriorOperationId
            $prior | Add-Member -NotePropertyName CleanupOperationId -NotePropertyValue $Operation.OperationId -Force; $prior.State='Succeeded'; $prior.Step='Completed'; $prior.Code='cleanup-completed'; Write-NetCrateJson $priorPath $prior
            $Operation.Step='Completed';Write-NetCrateJson $OperationFile $Operation;return
        } catch { $Operation.State='NeedsAttention';$Operation | Add-Member -NotePropertyName Code -NotePropertyValue 'prune-interrupted' -Force;Write-NetCrateJson $OperationFile $Operation;throw 'Cleanup did not finish. Create a new cleanup preview.' }
    }
    if(-not $ids.Count){$Operation.Step='Completed';Write-NetCrateJson $OperationFile $Operation;return}
    # Re-enumerate immediately before the destructive command, and refuse any
    # change since the saved preview. All IDs remain server-generated full IDs.
    $inventory=Get-MaintenanceInventory $Context ([int]$preview.Count)
    $digest=Get-MaintenanceFingerprint $inventory
    if($digest -cne $preview.Fingerprint -or ((@($inventory.Candidates)|Sort-Object) -join ',') -cne (($ids|Sort-Object) -join ',')){throw 'Storage changed since this preview. Create a new preview.'}
    if([DateTimeOffset]::UtcNow -ge ([DateTimeOffset]$preview.ExpiresUtc).ToUniversalTime()){throw 'The preview expired before maintenance could start. Create a new preview.'}
    $before=@($inventory.PrimaryWire|ConvertFrom-Json)
    $expected=@($before|Where-Object {$_.id -cnotin $ids}|ForEach-Object {$_.id}|Sort-Object)
    $Operation.Step='ForgetStarted';Write-NetCrateJson $OperationFile $Operation
    try {
        $args=@('--repo',$Context.Binding.PrimaryPath,'--no-cache','forget')+$ids
        $result=Invoke-NetCrateProcess $Context.Settings.Tools.Restic $args @{RESTIC_PASSWORD=$Context.Secrets.PrimaryPassword} -TimeoutSeconds 86400
        if($result.ExitCode -ne 0){throw 'Forget did not finish.'}
        $afterWire=Invoke-MaintenanceRestic $Context Primary @('snapshots','--json')
        $after=@($afterWire|ConvertFrom-Json|ForEach-Object {$_.id}|Sort-Object)
        $resultsAfter=Invoke-MaintenanceRestic $Context Results @('snapshots','--json')
        if(($expected -join ',') -cne ($after -join ',') -or $resultsAfter -cne $inventory.ResultsWire){throw 'The repository changed during forget.'}
        $Operation.Step='ForgetVerified';Write-NetCrateJson $OperationFile $Operation
        $Operation.Step='PruneStarted';Write-NetCrateJson $OperationFile $Operation
        $result=Invoke-NetCrateProcess $Context.Settings.Tools.Restic @('--repo',$Context.Binding.PrimaryPath,'--no-cache','prune') @{RESTIC_PASSWORD=$Context.Secrets.PrimaryPassword} -TimeoutSeconds 86400
        if($result.ExitCode -ne 0){throw 'Prune did not finish.'}
        $Operation.Step='Completed';Write-NetCrateJson $OperationFile $Operation
    } catch {
        $Operation.State='NeedsAttention'
        $Operation | Add-Member -NotePropertyName Code -NotePropertyValue $(if($Operation.Step -ceq 'PruneStarted'){'prune-interrupted'}else{'forget-uncertain'}) -Force
        Write-NetCrateJson $OperationFile $Operation
        throw 'Storage maintenance did not finish. Review its status and create a new preview before trying again.'
    }
}
function Invoke-MaintenanceCheck($Context) {
    $root=$Context.Owner.Root
    $path=[IO.Path]::Combine($root,'Maintenance','health.json')
    $old=if([IO.File]::Exists($path)){Read-NetCrateJson $path -MaximumBytes 16384}else{$null}
    $health=[ordered]@{Version=1;InstallationId=$Context.Owner.InstallationId}
    foreach($name in @('Primary','Results')) {
        $prior=if($old -and $old.PSObject.Properties.Name -ccontains $name){$old.$name}else{$null}
        $last=if($prior -and $prior.LastSuccessUtc){([DateTimeOffset]$prior.LastSuccessUtc).ToUniversalTime().ToString('o')}else{''}
        $now=[DateTimeOffset]::UtcNow.ToString('o');$state='Failed';$code='check-failed'
        try {
            $repo=$Context.Binding.($name+'Path');$password=$Context.Secrets.($name+'Password')
            $result=Invoke-NetCrateProcess $Context.Settings.Tools.Restic @('--repo',$repo,'--no-cache','check') @{RESTIC_PASSWORD=$password} -TimeoutSeconds 86400
            if($result.ExitCode -eq 0){$state='Succeeded';$code='ok';$last=[DateTimeOffset]::UtcNow.ToString('o')}elseif($result.ExitCode -eq 11){$code='locked'}elseif($result.ExitCode -eq 10){$code='unavailable'}elseif($result.ExitCode -eq 12){$code='credentials'}
        } catch [UnauthorizedAccessException] { $code='permission' } catch [IO.DriveNotFoundException] { $code='unavailable' } catch { $code='check-failed' }
        if($state -ceq 'Failed' -and $code -ceq 'check-failed'){try{if((Get-MaintenanceFreeSpace $Context.Binding.StorageRoot) -eq 0){$code='full'}}catch{}}
        $health[$name]=[ordered]@{State=$state;Code=$code;LastAttemptUtc=$now;LastSuccessUtc=$last;Coverage='Repository metadata and structure; file data was not fully read.'}
        # Persist each result, including a previous success when this attempt fails.
        if($name -ceq 'Primary' -and $old -and $old.PSObject.Properties.Name -ccontains 'Results'){$health.Results=$old.Results}
        Write-NetCrateJson $path $health
    }
    return [pscustomobject]$health
}
function Invoke-NetCrateMaintenanceRequest {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$InstallationId,
        [Parameter(Mandatory)][ValidateSet('CheckStorage','PreviewRetention','ApplyRetention')][string]$Action,
        [Parameter(Mandatory)][hashtable]$Parameters)
    if($Action -ceq 'CheckStorage'){
        $owner=Get-NetCrateOwner $Root
        if($owner.Role -cne 'Worker' -or $owner.InstallationId -cne $InstallationId){throw 'Open storage controls on the owning Backup Server.'}
    } else {$owner=(Get-NetCrateMaintenanceContext $Root $InstallationId).Owner}
    $allowed=switch -CaseSensitive ($Action) {'CheckStorage'{@()} 'PreviewRetention'{@('Policy','Count')} 'ApplyRetention'{@('PreviewId','Confirm')}}
    foreach($key in $Parameters.Keys){if($key -cnotin $allowed){throw 'The storage request contains an unsupported field.'}}
    $record=[ordered]@{Version=1;InstallationId=$InstallationId;OperationId=[guid]::NewGuid().ToString('N');Action=$Action;State='Queued';CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    if($Action -ceq 'PreviewRetention'){
        if($Parameters.Policy -cnotin @('KeepAll','KeepLatestPerFolder','CompleteCleanup')){throw 'Choose a supported retention policy.'}
        $record.Policy=$Parameters.Policy
        if($Parameters.Policy -ceq 'KeepLatestPerFolder'){
            $count=$Parameters.Count
            if(($count -isnot [int] -and $count -isnot [long]) -or $count -lt 1 -or $count -gt 10000){throw 'Choose a whole number of backups to keep.'}
            $record.Count=[int]$count
        } elseif($Parameters.ContainsKey('Count')){throw 'Keep all does not need a count.'}
    }
    if($Action -ceq 'ApplyRetention'){
        if($Parameters.PreviewId -isnot [string] -or $Parameters.PreviewId -cnotmatch '^[a-f0-9]{32}$' -or $Parameters.Confirm -isnot [bool] -or -not $Parameters.Confirm){throw 'Confirm the specific current preview.'}
        $record.PreviewId=$Parameters.PreviewId; $record.Confirm=$true
    }
    $mutex=[Threading.Mutex]::new($false,('Global\NetCrate-Maintenance-'+$owner.UserSid+'-'+$InstallationId));$held=$false
    try {
        try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Storage controls are busy. Try again.'}
        $folder=Set-NetCratePrivateDirectory ([IO.Path]::Combine($Root,'Maintenance','Requests'))
        $existing=@([IO.Directory]::EnumerateFiles($folder,'*.json'))
        if($existing.Count -ge 256){
            $terminal=@(@(foreach($file in $existing){
                $item=Read-NetCrateJson $file -MaximumBytes 32768
                if($item.Version -ne 1 -or $item.InstallationId -cne $InstallationId -or $item.OperationId -cnotmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFileNameWithoutExtension($file) -cne $item.OperationId){throw 'A storage operation record is invalid.'}
                if($item.State -cin @('Succeeded','Failed','NeedsAttention')){[pscustomobject]@{Path=$file;CreatedUtc=[DateTimeOffset]$item.CreatedUtc}}
            })|Sort-Object CreatedUtc)
            $remove=$existing.Count-255
            if($terminal.Count -lt $remove){throw 'Too many storage requests are active. Wait for the Backup Server and try again.'}
            for($i=0;$i -lt $remove;$i++){[IO.File]::Delete($terminal[$i].Path)}
        }
        Write-NetCrateJson ([IO.Path]::Combine($folder,$record.OperationId+'.json')) $record
    } finally {if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
    return [pscustomobject]@{State='Queued';OperationId=$record.OperationId}
}
# Called only by the runtime while holding its installation mutex. Interrupted
# running operations require attention; they are never silently replayed.
function Set-MaintenanceCheckFailure([string]$Root,[string]$InstallationId,[string]$Code='check-failed') {
    if($Code -cnotin @('unavailable','permission','full','check-failed')){$Code='check-failed'}
    $owner=Get-NetCrateOwner $Root
    if($owner.Role -cne 'Worker' -or $owner.InstallationId -cne $InstallationId){throw 'The storage owner is invalid.'}
    $path=[IO.Path]::Combine($Root,'Maintenance','health.json')
    $old=if([IO.File]::Exists($path)){Read-NetCrateJson $path -MaximumBytes 16384}else{$null}
    $state=[ordered]@{Version=1;InstallationId=$InstallationId}
    foreach($name in @('Primary','Results')){
        $prior=if($old -and $old.PSObject.Properties.Name -ccontains $name){$old.$name}else{$null}
        $last=if($prior -and $prior.LastSuccessUtc){([DateTimeOffset]$prior.LastSuccessUtc).ToUniversalTime().ToString('o')}else{''}
        $state[$name]=@{State='Failed';Code=$Code;LastAttemptUtc=[DateTimeOffset]::UtcNow.ToString('o');LastSuccessUtc=$last;Coverage='Repository metadata and structure; file data was not fully read.'}
    }
    Write-NetCrateJson $path $state
}
function Invoke-NetCrateMaintenancePass([string]$Root,[string]$InstallationId,[scriptblock]$Quiesce,[scriptblock]$Resume) {
    $folder=[IO.Path]::Combine($Root,'Maintenance','Requests')
    if(-not [IO.Directory]::Exists($folder)){return}
    $files=@([IO.Directory]::EnumerateFiles($folder,'*.json')|Sort-Object)
    if($files.Count -gt 256){throw 'There are too many storage requests.'}
    foreach($file in $files){
        $record=Read-NetCrateJson $file -MaximumBytes 32768
        if($record.Version -ne 1 -or $record.InstallationId -cne $InstallationId -or $record.OperationId -cnotmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFileNameWithoutExtension($file) -cne $record.OperationId -or $record.Action -cnotin @('CheckStorage','PreviewRetention','ApplyRetention')){throw 'A storage request record is invalid.'}
        if($record.State -ceq 'Running'){
            $record.State='NeedsAttention';$code=if($record.Action -ceq 'ApplyRetention' -and $record.PSObject.Properties.Name -ccontains 'Step' -and $record.Step -cin @('ForgetVerified','PruneStarted')){'prune-interrupted'}elseif($record.Action -ceq 'ApplyRetention' -and $record.PSObject.Properties.Name -ccontains 'Step' -and $record.Step -ceq 'ForgetStarted'){'forget-uncertain'}else{'interrupted'};if($code -ceq 'prune-interrupted'){$record.Step='PruneStarted'};$record|Add-Member -NotePropertyName Code -NotePropertyValue $code -Force;Write-NetCrateJson $file $record;continue
        }
        if($record.State -cne 'Queued'){continue}
        $record.State='Running';Write-NetCrateJson $file $record
        try {
            $context=Get-NetCrateMaintenanceContext $Root $InstallationId
            if($record.Action -ceq 'CheckStorage'){
                $health=Invoke-MaintenanceCheck $context
                $record.State=if($health.Primary.State -ceq 'Succeeded' -and $health.Results.State -ceq 'Succeeded'){'Succeeded'}else{'Failed'}
            } elseif($record.Action -ceq 'PreviewRetention'){
                $count=if($record.Policy -cin @('KeepAll','CompleteCleanup')){0}else{[int]$record.Count}
                $preview=New-MaintenancePreview $context $record.Policy $count
                $record|Add-Member -NotePropertyName PreviewId -NotePropertyValue $preview.PreviewId -Force
                $record.State='Succeeded'
            } else {
                if(-not $Quiesce -or -not $Resume){throw 'The storage endpoint cannot be controlled safely.'}
                try {
                    & $Quiesce
                    $context=Get-NetCrateMaintenanceContext $Root $InstallationId
                    Invoke-MaintenanceApply $context $record $file
                } finally { try { & $Resume } catch {$record.State='NeedsAttention';$record|Add-Member -NotePropertyName Code -NotePropertyValue 'endpoint-restart' -Force;throw} }
                $record.State='Succeeded'
            }
        } catch {
            if($record.Action -ceq 'CheckStorage'){try {$status=Get-NetCrateMaintenanceStatus $Root $InstallationId;Set-MaintenanceCheckFailure $Root $InstallationId $status.StorageCode} catch {}}
            if($record.State -cne 'NeedsAttention'){$record.State='Failed'}
            if($record.PSObject.Properties.Name -cnotcontains 'Code'){$code=if($record.Action -ceq 'ApplyRetention'){'preview-stale'}elseif($record.Action -ceq 'PreviewRetention' -and $_.Exception.Message -ceq 'netcrate-preview-limit'){'preview-limit'}elseif($record.Action -ceq 'PreviewRetention'){'preview-unavailable'}else{'check-unavailable'};$record|Add-Member -NotePropertyName Code -NotePropertyValue $code -Force}
        }
        Write-NetCrateJson $file $record
        break
    }
}
function Get-MaintenanceFreeSpace([string]$StorageRoot) {
    $null=Get-Item -LiteralPath $StorageRoot -Force -ErrorAction Stop
    $volume=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($StorageRoot))
    if(-not $volume.IsReady){throw [IO.DriveNotFoundException]::new('The backup drive is unavailable.')}
    return $volume.AvailableFreeSpace
}
function Get-NetCrateMaintenanceStatus {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$InstallationId)
    $owner=Get-NetCrateOwner $Root
    if($owner.Role -cne 'Worker' -or $owner.InstallationId -cne $InstallationId){throw 'Open storage controls on the owning Backup Server.'}
    $bytes=-1L;$storageCode='unverified'
    try {
        $binding=Read-NetCrateJson ([IO.Path]::Combine($Root,'repositories.json')) -MaximumBytes 16384
        if($binding.Version -ne 1 -or $binding.InstallationId -cne $InstallationId){throw 'The local storage binding is invalid.'}
        $storage=Assert-NetCrateLocalPath $binding.StorageRoot
        $expected=Assert-NetCrateLocalPath ([IO.Path]::Combine($storage,'NetCrate-'+$InstallationId))
        if(-not $expected.Equals($binding.RepositoryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'The local storage binding is invalid.'}
        $secret=Unprotect-NetCrateRecord $Root repositories
        if(-not $secret.StorageRoot.Equals($storage,[StringComparison]::OrdinalIgnoreCase)){throw 'The protected storage binding is invalid.'}
        $bytes=Get-MaintenanceFreeSpace $storage
        $storageCode=if($bytes -eq 0){'full'}else{'available'}
        if(-not [IO.File]::Exists([IO.Path]::Combine($expected,'netcrate-owner.json')) -or -not [IO.File]::Exists([IO.Path]::Combine($expected,'editing','originals','config')) -or -not [IO.File]::Exists([IO.Path]::Combine($expected,'editing','results','config'))){$storageCode='unverified'}
        if($storageCode -cin @('available','full')){try{$null=Get-NetCrateMaintenanceContext $Root $InstallationId -ConfigTimeoutSeconds 5}catch{$storageCode='unverified'}}
    } catch [UnauthorizedAccessException] {$storageCode='permission';$bytes=-1L}
      catch [IO.DriveNotFoundException] {$storageCode='unavailable';$bytes=-1L}
      catch [System.Management.Automation.ItemNotFoundException] {$storageCode='unavailable';$bytes=-1L}
      catch {$storageCode='unverified';$bytes=-1L}
    $path=[IO.Path]::Combine($Root,'Maintenance','health.json')
    $health=if([IO.File]::Exists($path)){Read-NetCrateJson $path -MaximumBytes 16384}else{$null}
    if($health -and ($health.Version -ne 1 -or $health.InstallationId -cne $InstallationId)){throw 'The storage health record differs from this installation.'}
    $folder=[IO.Path]::Combine($Root,'Maintenance','Requests');$operations=@()
    if([IO.Directory]::Exists($folder)){
        $files=@([IO.Directory]::EnumerateFiles($folder,'*.json'))
        if($files.Count -gt 256){throw 'There are too many storage requests to display.'}
        $operations=@(foreach($file in $files){
            $r=Read-NetCrateJson $file -MaximumBytes 32768
            if($r.Version -ne 1 -or $r.InstallationId -cne $InstallationId -or $r.OperationId -cnotmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFileNameWithoutExtension($file) -cne $r.OperationId -or $r.Action -cnotin @('CheckStorage','PreviewRetention','ApplyRetention') -or $r.State -cnotin @('Queued','Running','Succeeded','Failed','NeedsAttention')){throw 'A storage operation record is invalid.'}
            [pscustomobject]@{OperationId=$r.OperationId;Action=$r.Action;State=$r.State;CreatedUtc=$r.CreatedUtc;Code=if($r.PSObject.Properties.Name -ccontains 'Code'){$r.Code}else{''};PreviewId=if($r.PSObject.Properties.Name -ccontains 'PreviewId'){$r.PreviewId}else{''}}
        })
    }
    $operations=@($operations|Sort-Object CreatedUtc -Descending)
    $current=$null
    foreach($operation in @($operations|Where-Object {$_.Action -ceq 'PreviewRetention' -and $_.State -ceq 'Succeeded' -and $_.PreviewId -cmatch '^[a-f0-9]{32}$'}|Sort-Object CreatedUtc -Descending)){
        $previewPath=[IO.Path]::Combine($Root,'Maintenance','Previews',$operation.PreviewId+'.json')
        $preview=Read-NetCrateJson $previewPath -MaximumBytes 262144
        if($preview.Version -ne 1 -or $preview.InstallationId -cne $InstallationId -or $preview.PreviewId -cne $operation.PreviewId -or @($preview.Items).Count -gt 256 -or @($preview.Candidates).Count -gt 256){throw 'A stored preview is invalid.'}
        if(-not $preview.Used -and ([DateTimeOffset]$preview.ExpiresUtc).ToUniversalTime() -gt [DateTimeOffset]::UtcNow){$current=[pscustomobject]@{PreviewId=$preview.PreviewId;ExpiresUtc=$preview.ExpiresUtc;Policy=$preview.Policy;CandidateCount=@($preview.Candidates).Count;EligibleCount=$preview.EligibleCount;ProtectedCount=$preview.ProtectedCount;NewestRetainedUtc=$preview.NewestRetainedUtc;Items=@($preview.Items)};break}
    }
    return [pscustomobject]@{FreeBytes=$bytes;LowSpace=($bytes -ge 0 -and $bytes -lt 5GB);StorageCode=$storageCode;Health=$health;Operations=$operations;Preview=$current}
}
Export-ModuleMember -Function Get-NetCrateMaintenanceContext, Invoke-NetCrateMaintenanceRequest, Get-NetCrateMaintenanceStatus, Invoke-NetCrateMaintenancePass
