#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('Configuration', 'Protocol', 'Credentials', 'Process', 'Pairing')) {
    Import-Module (Join-Path $PSScriptRoot ('NetCrate.' + $name + '.psm1'))
}

function Throw-WorkflowFailure([string]$Category, [string]$Message) {
    $error = [Exception]::new($Message); $error.Data['NetCrateCategory'] = $Category; throw $error
}

function Invoke-WorkflowRestic($Root, $Settings, [string]$Repository, [string[]]$Arguments, [string]$OutputFile) {
    $secrets = if ($Settings.Role -ceq 'Source') { Unprotect-NetCrateRecord $Root 'paired-secrets' } else { Unprotect-NetCrateRecord $Root 'repositories' }
    $binding = $Settings.Repositories.$Repository
    $environment = @{ RESTIC_PASSWORD = $secrets.($Repository + 'Password') }
    $common = @('--repo', $binding.Uri, '--cache-dir', [IO.Path]::Combine($Root, 'Cache'))
    if ($binding.Uri.StartsWith('rest:https://')) {
        $environment.RESTIC_REST_USERNAME = 'editing'; $environment.RESTIC_REST_PASSWORD = $secrets.TransportPassword
        $common += @('--cacert', [IO.Path]::Combine($Root, 'server.pem'))
    }
    $timeout = if ($Arguments[0] -in @('backup', 'restore')) { 86400 } else { 45 }
    $result = Invoke-NetCrateProcess -FilePath $Settings.Tools.Restic -Arguments ($common + $Arguments) -Environment $environment -OutputFile $OutputFile -TimeoutSeconds $timeout
    if ($result.ExitCode -ne 0) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::Combine($Root, 'Logs'))
        [IO.File]::WriteAllText([IO.Path]::Combine($Root, 'Logs', 'storage-error.log'), $result.Diagnostic)
        $category = if ($Arguments[0] -ceq 'backup' -and $result.ExitCode -eq 3) { 'source-incomplete' } else { 'storage-unavailable' }
        Throw-WorkflowFailure $category 'The backup operation did not finish. Existing data was retained for retry.'
    }
    return $result.Output
}

function Backup-WorkflowPath($Root, $Settings, [string]$Repository, [string]$Path, [string]$Tag, [string[]]$Extra = @()) {
    $hostName = if ($Settings.Role -ceq 'Source') { $Settings.SourceComputer } else { $Settings.WorkerComputer }
    $log = [IO.Path]::Combine($Root, 'Logs', [guid]::NewGuid().ToString('N') + '.jsonl')
    $output = Invoke-WorkflowRestic $Root $Settings $Repository (@('backup', '--json', '--host', $hostName, '--tag', ('netcrate-' + $Tag)) + $Extra + @('--', $Path)) $log
    $summary = @($output -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object message_type -CEQ summary)
    if ($summary.Count -ne 1 -or $summary[0].snapshot_id -cnotmatch '^[a-f0-9]{64}$') { throw 'A complete backup snapshot was not returned.' }
    return $summary[0].snapshot_id
}

function Write-WorkflowRecord($Root, $Settings, [string]$Kind, [string]$Id, $Data) {
    if ($Id -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid record identity.' }
    $folder = [IO.Path]::Combine($Root, 'Outbox', $Kind, $Id)
    $null = [IO.Directory]::CreateDirectory($folder)
    $record = [ordered]@{ Data = $Data; Signature = (Get-PairingSignature $Root $Data) }
    $path = [IO.Path]::Combine($folder, 'record.json')
    Write-NetCrateJson $path $record
    $null = Backup-WorkflowPath $Root $Settings Results $path $Kind
}

function Read-WorkflowRecords($Root, $Settings, [string]$Kind, [string]$HostName) {
    $snapshots = @(Invoke-WorkflowRestic $Root $Settings Results @('snapshots', '--json', '--host', $HostName, '--tag', ('netcrate-' + $Kind)) | ConvertFrom-Json)
    $peer = Unprotect-NetCrateRecord $Root 'runtime-peer'
    if (@($snapshots).Count -gt 20000) { throw 'The remote record list is larger than expected.' }
    foreach ($snapshot in @($snapshots)) {
        if ($snapshot.id -cnotmatch '^[a-f0-9]{64}$' -or @($snapshot.paths).Count -ne 1) { continue }
        $recordPath = Convert-WorkflowSnapshotPath $snapshot.paths[0]
        if (-not $recordPath.EndsWith('/record.json')) { continue }
        $cache = [IO.Path]::Combine($Root, 'Inbox', $Kind, $snapshot.id + '.json')
        if ([IO.File]::Exists($cache)) { $text = [IO.File]::ReadAllText($cache) }
        else { $text = Invoke-WorkflowRestic $Root $Settings Results @('dump', $snapshot.id, $recordPath) }
        if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 262144) { throw 'The remote record is larger than expected.' }
        $wire = $text | ConvertFrom-Json
        if (@($wire.PSObject.Properties).Count -ne 2) { throw 'The remote record has unsupported fields.' }
        Assert-PairingSignature $peer.PublicKey $wire.Data $wire.Signature
        if (-not [IO.File]::Exists($cache)) { Write-NetCrateJson $cache $wire }
        $wire.Data
    }
}

function Get-WorkflowNodes($Root, $Settings, [string]$SnapshotId, [string]$ProjectPath) {
    $snapshot = Invoke-WorkflowRestic $Root $Settings Primary @('cat', 'snapshot', $SnapshotId) | ConvertFrom-Json
    if ($snapshot.hostname -cne $Settings.SourceComputer -or @($snapshot.paths).Count -ne 1 -or
        (Convert-WorkflowSnapshotPath $snapshot.paths[0]) -cne $ProjectPath -or $snapshot.tags -cnotcontains 'netcrate-originals') { throw 'The source snapshot does not match the requested project and computer.' }
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($ProjectPath)
    $nodes = [Collections.Generic.List[object]]::new()
    while ($pending.Count) {
        $current = $pending.Pop()
        $tree = Invoke-WorkflowRestic $Root $Settings Primary @('cat', 'tree', ($SnapshotId + ':' + $current)) | ConvertFrom-Json
        foreach ($node in @($tree.nodes)) {
            $null = Assert-NetCrateRelativePath $node.name
            $node | Add-Member -NotePropertyName path -NotePropertyValue ($current + '/' + $node.name)
            $nodes.Add($node)
            if ($node.type -ceq 'dir') { $pending.Push($node.path) }
        }
    }
    return @($nodes.ToArray())
}

function Assert-WorkflowTree([string]$Path) {
    $null = Assert-NetCrateLocalPath $Path
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        if (([IO.File]::GetAttributes($part) -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) -ne 0) { Throw-WorkflowFailure 'unsupported-entry' 'Linked, offline or online-only entries are not supported. Make the folder fully available locally first.' }
        $part = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Path)
    while ($pending.Count) {
        $current = $pending.Pop()
        foreach ($item in [IO.DirectoryInfo]::new($current).EnumerateFileSystemInfos()) {
            # Inspect before descending: do not hydrate cloud placeholders or follow links.
            if (([long]$item.Attributes -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) -ne 0) { Throw-WorkflowFailure 'unsupported-entry' 'Linked, offline or online-only entries are not supported. Make the folder fully available locally first.' }
            try { $null = Assert-NetCrateRelativePath $item.Name } catch { Throw-WorkflowFailure 'unsupported-name' 'A source entry has an unsupported name.' }
            $null = Assert-NetCrateLocalPath $item.FullName
            if (-not $seen.Add($item.FullName)) { throw 'The folder contains colliding file names.' }
            if ($item -is [IO.DirectoryInfo]) { $pending.Push($item.FullName) }
        }
    }
}

function Assert-WorkflowBackupReceipt($Receipt, $Expected) {
    if (@($Receipt.PSObject.Properties).Count -ne 9) { throw 'The backup completion receipt has unsupported fields.' }
    foreach ($name in @('Version','Kind','RepositoryId','SourceComputer','Project','SnapshotId','BackupMode','JobId')) {
        if ([string]$Receipt.$name -cne [string]$Expected.$name) { throw 'The backup completion receipt differs from its original snapshot checkpoint.' }
    }
    if (([DateTimeOffset]$Receipt.BackupCompletedUtc).UtcTicks -ne ([DateTimeOffset]$Expected.BackupCompletedUtc).UtcTicks) { throw 'The backup completion receipt has a different completion time.' }
}

function Write-NetCrateBackupReceipt($Root, $Settings, $Completion) {
    $path = [IO.Path]::Combine($Root, 'BackupReceipts', $Completion.SnapshotId + '.json')
    $expected = [pscustomobject][ordered]@{ Version = 1; Kind = 'backup-receipt'; RepositoryId = $Settings.Repositories.Primary.Id
        SourceComputer = $Settings.SourceComputer; Project = $Completion.Project; SnapshotId = $Completion.SnapshotId
        BackupMode = $Completion.BackupMode; JobId = $Completion.Id; BackupCompletedUtc = $Completion.BackupCompletedUtc }
    if ([IO.File]::Exists($path)) { Assert-WorkflowBackupReceipt (Read-NetCrateJson $path) $expected }
    else { Write-NetCrateJson $path $expected }
    $tag = 'netcrate-receipt-' + $Completion.SnapshotId
    $existing = @(Invoke-WorkflowRestic $Root $Settings Primary @('snapshots', '--json', '--host', $Settings.SourceComputer, '--tag', $tag) | ConvertFrom-Json)
    if ($existing.Count -gt 1000) { throw 'The backup completion receipt list is larger than expected.' }
    foreach ($snapshot in $existing) {
        if ($snapshot.id -cnotmatch '^[a-f0-9]{64}$' -or $snapshot.hostname -cne $Settings.SourceComputer -or @($snapshot.paths).Count -ne 1 -or $snapshot.tags -cnotcontains 'netcrate-backup-receipt') { throw 'The stored completion receipt has an invalid snapshot binding.' }
        $wire = Invoke-WorkflowRestic $Root $Settings Primary @('dump', $snapshot.id, (Convert-WorkflowSnapshotPath $snapshot.paths[0]))
        if ([Text.Encoding]::UTF8.GetByteCount($wire) -gt 16384) { throw 'The backup completion receipt is too large.' }
        Assert-WorkflowBackupReceipt ($wire | ConvertFrom-Json) $expected
    }
    if (-not $existing.Count) { $null = Backup-WorkflowPath $Root $Settings Primary $path backup-receipt @('--tag', $tag) }
}

function Get-WorkflowOriginalTime($Root, $Settings, [string]$SnapshotId, [string]$Project, [string]$BackupMode) {
    $config = Invoke-WorkflowRestic $Root $Settings Primary @('cat', 'config') | ConvertFrom-Json
    if ($config.id -cne $Settings.Repositories.Primary.Id) { throw 'The original repository identity differs from this checkpoint.' }
    $snapshot = Invoke-WorkflowRestic $Root $Settings Primary @('cat', 'snapshot', $SnapshotId) | ConvertFrom-Json
    $tag = if ($BackupMode -ceq 'Folder') { 'netcrate-folder-originals' } else { 'netcrate-originals' }
    if ($snapshot.hostname -cne $Settings.SourceComputer -or @($snapshot.paths).Count -ne 1 -or $snapshot.tags -cnotcontains $tag -or
        -not (Convert-WorkflowSnapshotPath $snapshot.paths[0]).Equals((Get-NetCrateSnapshotRoot $Project), [StringComparison]::OrdinalIgnoreCase)) { throw 'The original snapshot does not match this source and folder.' }
    return ([DateTimeOffset]$snapshot.time).UtcDateTime.ToString('o')
}

function Invoke-NetCrateOriginals {
    param([string]$Root, $Settings, [string]$Project, [string]$Checkpoint, [ValidateSet('Folder','Media')][string]$BackupMode)
    $path = Get-NetCrateBackupPath $Settings $Project $BackupMode
    $status = if ($Checkpoint) { Read-NetCrateJson $Checkpoint } else { [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N'); SnapshotId = ''; BackupCompletedUtc = '' } }
    if ($Checkpoint -and $status.PSObject.Properties.Name -contains 'BackupMode' -and $status.PSObject.Properties.Name -notcontains 'ReceiptConfirmed' -and ($status.PSObject.Properties.Name -notcontains 'State' -or ($status.State -cnotin @('Ready','WaitingForProxies') -and ($status.PSObject.Properties.Name -notcontains 'RequestId' -or $status.RequestId -cnotmatch '^[a-f0-9]{64}$')))) { $status | Add-Member -NotePropertyName ReceiptConfirmed -NotePropertyValue $false -Force; Write-NetCrateJson $Checkpoint $status }
    if ($status.PSObject.Properties.Name -notcontains 'BackupCompletedUtc') { $status | Add-Member BackupCompletedUtc '' }
    if ($status.PSObject.Properties.Name -notcontains 'BackupMode') { $status | Add-Member BackupMode $BackupMode }
    if ($status.PSObject.Properties.Name -notcontains 'Project') { $status | Add-Member Project $path }
    if ($status.PSObject.Properties.Name -notcontains 'MediaState') { $status | Add-Member MediaState $(if ($BackupMode -ceq 'Folder') { 'Off' } else { 'Pending' }) }
    if ($status.SnapshotId -cnotmatch '^[a-f0-9]{64}$') {
        Assert-WorkflowTree $path
        $tag = if ($BackupMode -ceq 'Folder') { 'folder-originals' } else { 'originals' }
        $extra = @('--tag', 'netcrate-v2-originals')
        if ($BackupMode -ceq 'Media') { $extra += @('--exclude', ($path + '\Proxies\NetCrate'), '--exclude', ($path + '\.office-generated-media')) }
        # Backup-WorkflowPath only returns after exit zero and exactly one full ID.
        $status | Add-Member -NotePropertyName ReceiptConfirmed -NotePropertyValue $false -Force
        $status.SnapshotId = Backup-WorkflowPath $Root $Settings Primary $path $tag $extra
        $status.BackupCompletedUtc = [DateTime]::UtcNow.ToString('o')
        if ($Checkpoint) { Write-NetCrateJson $Checkpoint $status }
    }
    if (-not $status.BackupCompletedUtc) {
        $status.BackupCompletedUtc = Get-WorkflowOriginalTime $Root $Settings $status.SnapshotId $path $BackupMode
        if ($Checkpoint) { Write-NetCrateJson $Checkpoint $status }
    }
    Write-NetCrateBackupReceipt $Root $Settings $status
    $status | Add-Member -NotePropertyName ReceiptConfirmed -NotePropertyValue $true -Force
    if ($Checkpoint) { Write-NetCrateJson $Checkpoint $status }
    return $status
}

function Invoke-NetCrateBackup {
    param([string]$Root, $Settings, [string]$Project, [string]$Checkpoint)
    $path = Get-NetCrateBackupPath $Settings $Project Media
    $snapshotPath = Get-NetCrateSnapshotRoot $path
    $status = Invoke-NetCrateOriginals $Root $Settings $path $Checkpoint Media
    $id = $status.SnapshotId
    $recipe = Get-NetCrateRecipe $Settings.Recipe
    $identity = Get-NetCrateFootageIdentity $snapshotPath (Get-WorkflowNodes $Root $Settings $id $snapshotPath) $recipe.FingerprintRecipe
    $request = [pscustomobject][ordered]@{ Version = 2; Kind = 'request'; SourceComputer = $Settings.SourceComputer
        Repository = $Settings.Repositories.Primary.Uri; BackupExitCode = 0; SnapshotId = $id; ProjectPath = $snapshotPath
        CompletedUtc = $status.BackupCompletedUtc; Recipe = $recipe.FingerprintRecipe; FootageFingerprint = $identity.Fingerprint }
    $requestId = Get-NetCrateRequestId $id $snapshotPath $recipe.FingerprintRecipe
    $null = Test-NetCrateRequest $request $requestId $Settings
    Write-NetCrateJson ([IO.Path]::Combine($Root, 'Requests', $requestId + '.json')) $request
    Write-WorkflowRecord $Root $Settings request $requestId $request
    return $request
}

function Test-WorkflowResult([string]$Path, $Association, [switch]$AvailabilityOnly) {
    Assert-WorkflowTree $Path
    $completePath = [IO.Path]::Combine($Path, 'COMPLETE.json')
    $manifestPath = [IO.Path]::Combine($Path, 'Files-SHA256.csv')
    if ((Get-FileHash -LiteralPath $completePath).Hash.ToLowerInvariant() -cne $Association.CompletionSHA256 -or
        (Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant() -cne $Association.ResultManifestSHA256) { throw 'The result metadata hashes differ from the verified association.' }
    $complete = Read-NetCrateJson $completePath
    foreach ($field in @('JobId', 'GenerationSnapshotId', 'ProjectPath', 'Recipe', 'FootageFingerprint', 'ResultManifestSHA256')) {
        if ($complete.$field -cne $Association.$field) { throw 'The generated files do not match the requested footage.' }
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $expected.Add('COMPLETE.json'); $null = $expected.Add('Files-SHA256.csv')
    $rows = @(Import-Csv -LiteralPath $manifestPath -Encoding utf8)
    foreach ($row in $rows) {
        $null = Assert-NetCrateRelativePath $row.Path
        if (-not $expected.Add($row.Path) -or $row.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $row.Bytes -cnotmatch '^\d+$') { throw 'The result manifest contains invalid or colliding files.' }
        $file = [IO.Path]::Combine($Path, $row.Path.Replace('/', '\'))
        if (-not [IO.File]::Exists($file) -or [IO.FileInfo]::new($file).Length -ne [long]$row.Bytes) { throw 'A returned file is missing or changed.' }
        if (-not $AvailabilityOnly -and (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -cne $row.SHA256) { throw 'A returned file did not pass verification.' }
    }
    foreach ($file in [IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::AllDirectories)) {
        if (-not $expected.Contains([IO.Path]::GetRelativePath($Path, $file).Replace('\', '/'))) { throw 'The result contains an undeclared file.' }
    }
    $items = @(Read-NetCrateJson ([IO.Path]::Combine($Path, 'media_index.json')))
    if ($items.Count -ne $complete.Clips -or $rows.Count -ne (2 * $complete.Clips + 1)) { throw 'The returned media count differs from its manifest.' }
    foreach ($item in $items) {
        foreach ($name in @('Proxy', 'ContactSheet')) { if (-not $expected.Contains($item.$name)) { throw 'A proxy or contact sheet is missing.' } }
    }
    return $complete
}

function Invoke-NetCrateWorker {
    param([string]$Root, $Settings)
    if ((Get-NetCrateBackupMode $Settings) -ceq 'Folder') { return }
    if ($Settings.PSObject.Properties.Name -contains 'SourceBackupMode' -and $Settings.SourceBackupMode -ceq 'Folder') { return }
    $workspace = if ($Settings.PSObject.Properties.Name -contains 'WorkRoot') { Assert-NetCrateLocalPath $Settings.WorkRoot } else { $Root }
    $requests = @(Read-WorkflowRecords $Root $Settings request $Settings.SourceComputer)
    foreach ($request in $requests) {
      $requestId = $null
      try {
        $requestId = Get-NetCrateRequestId $request.SnapshotId $request.ProjectPath $request.Recipe
        $null = Test-NetCrateRequest $request $requestId $Settings
        $published = [IO.Path]::Combine($Root, 'Published', $requestId + '.json')
        if ([IO.File]::Exists($published)) { continue }
        $jobState = [IO.Path]::Combine($Root, 'WorkerJobs', $requestId + '.json')
        if ([IO.File]::Exists($jobState) -and [DateTimeOffset](Read-NetCrateJson $jobState).RetryAfterUtc -gt [DateTimeOffset]::UtcNow) { continue }
        $progress = [ordered]@{ Version = 2; Kind = 'progress'; RequestId = $requestId; SnapshotId = $request.SnapshotId; Recipe = $request.Recipe
            FootageFingerprint = $request.FootageFingerprint; State = 'Processing'; UpdatedUtc = [DateTime]::UtcNow.ToString('o') }
        Write-NetCrateJson $jobState @{ State = 'Processing'; RequestId = $requestId; ProjectPath = $request.ProjectPath; SnapshotId = $request.SnapshotId
            UpdatedUtc = [DateTime]::UtcNow.ToString('o'); RetryAfterUtc = [DateTime]::UtcNow.ToString('o'); Output = '' }
        Write-WorkflowRecord $Root $Settings progress $requestId $progress
        $identity = Get-NetCrateFootageIdentity $request.ProjectPath (Get-WorkflowNodes $Root $Settings $request.SnapshotId $request.ProjectPath) $request.Recipe
        if ($identity.Fingerprint -cne $request.FootageFingerprint) { throw 'The footage identity differs from the successful source backup.' }
        $jobId = 'auto-' + $identity.Fingerprint
        $cache = [IO.Path]::Combine($Root, 'Generations', $identity.Fingerprint + '.json')
        if ([IO.File]::Exists($cache)) {
            $generation = Read-NetCrateJson $cache
            $null = Test-WorkflowResult $generation.Output $generation.Association
            $association = New-NetCrateAssociation $request $Settings $generation.Association.GenerationSnapshotId $generation.Association.ResultSnapshotId $generation.Association.CompletionSHA256 $generation.Association.ResultManifestSHA256
        } else {
            $work = [IO.Path]::Combine($workspace, 'Work', [guid]::NewGuid().ToString('N'))
            $restore = [IO.Path]::Combine($work, 'restore')
            $null = Invoke-WorkflowRestic $Root $Settings Primary @('restore', ($request.SnapshotId + ':' + $request.ProjectPath), '--target', $restore, '--verify')
            Assert-WorkflowTree $restore
            $files = @($identity.Files | ForEach-Object { @{ RelativePath = $_.RelativePath; Source = [IO.Path]::Combine($restore, $_.RelativePath.Replace('/', '\')) } })
            $output = [IO.Path]::Combine($workspace, 'Outputs', $jobId)
            if ([IO.Directory]::Exists($output)) { $output += '-' + [guid]::NewGuid().ToString('N') }
            $spec = [ordered]@{ Output = $output; Work = [IO.Path]::Combine($work, 'media'); Files = $files; JobId = $jobId; SnapshotId = $request.SnapshotId
                ProjectPath = $request.ProjectPath; Project = ($request.ProjectPath.Split('/')[-1]); Recipe = $request.Recipe
                FootageFingerprint = $identity.Fingerprint; FFmpeg = $Settings.Tools.FFmpeg }
            $specPath = [IO.Path]::Combine($work, 'media.json'); Write-NetCrateJson $specPath $spec
            $media = Invoke-NetCrateProcess $Settings.Tools.Python @('-I', [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../worker/netcrate_media.py')), $specPath) @{} 86400
            [IO.File]::WriteAllText([IO.Path]::Combine($work, 'media-error.log'), $media.Diagnostic)
            if ($media.ExitCode -ne 0) { throw 'Proxy generation did not pass media verification. Check the server job log, then retry.' }
            $resultId = Backup-WorkflowPath $Root $Settings Results $output ('result-' + $jobId)
            $association = New-NetCrateAssociation $request $Settings $request.SnapshotId $resultId (Get-FileHash -LiteralPath "$output/COMPLETE.json").Hash (Get-FileHash -LiteralPath "$output/Files-SHA256.csv").Hash
            $null = Test-WorkflowResult $output $association
            Write-NetCrateJson $cache @{ Output = $output; Association = $association }
        }
        Write-WorkflowRecord $Root $Settings association $requestId $association
        Write-NetCrateJson $published $association
        $outputPath = if ([IO.File]::Exists($cache)) { (Read-NetCrateJson $cache).Output } else { '' }
        Write-NetCrateJson $jobState @{ State = 'Published'; RequestId = $requestId; ProjectPath = $request.ProjectPath; SnapshotId = $request.SnapshotId
            UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Output = $outputPath; RetryAfterUtc = [DateTime]::UtcNow.ToString('o') }
      } catch {
        if ($requestId -cmatch '^[a-f0-9]{64}$') {
            Write-NetCrateJson $jobState @{ State = 'NeedsAttention'; RequestId = $requestId; ProjectPath = $request.ProjectPath; SnapshotId = $request.SnapshotId
                UpdatedUtc = [DateTime]::UtcNow.ToString('o'); RetryAfterUtc = [DateTime]::UtcNow.AddMinutes(5).ToString('o'); Output = '' }
            $progress = [ordered]@{ Version = 2; Kind = 'progress'; RequestId = $requestId; SnapshotId = $request.SnapshotId; Recipe = $request.Recipe
                FootageFingerprint = $request.FootageFingerprint; State = 'NeedsAttention'; UpdatedUtc = [DateTime]::UtcNow.ToString('o') }
            Write-WorkflowRecord $Root $Settings progress $requestId $progress
        }
      }
    }
    foreach ($ack in @(Read-WorkflowRecords $Root $Settings delivery-ack $Settings.SourceComputer)) {
        if ($ack.Version -ne 2 -or $ack.Kind -cne 'delivery-ack' -or $ack.RequestId -cnotmatch '^[a-f0-9]{64}$') { continue }
        $published = [IO.Path]::Combine($Root, 'Published', $ack.RequestId + '.json')
        if (-not [IO.File]::Exists($published)) { continue }
        $association = Read-NetCrateJson $published
        $matches = $true
        foreach ($field in @('RequestId', 'RequestedSnapshotId', 'GenerationSnapshotId', 'ResultSnapshotId', 'JobId', 'Recipe', 'FootageFingerprint')) {
            if ($ack.$field -cne $association.$field) { $matches = $false }
        }
        if (-not $matches) { continue }
        $generation = Read-NetCrateJson ([IO.Path]::Combine($Root, 'Generations', $association.FootageFingerprint + '.json'))
        $complete = Read-NetCrateJson ([IO.Path]::Combine($generation.Output, 'COMPLETE.json'))
        if ($ack.MediaFiles -ne (2 * $complete.Clips)) { continue }
        $jobPath = [IO.Path]::Combine($Root, 'WorkerJobs', $ack.RequestId + '.json')
        $job = Read-NetCrateJson $jobPath
        $job.State = 'Delivered'; $job.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $jobPath $job
    }
}

function Send-WorkflowDeliveryAck($Root, $Settings, $Receipt) {
    $path = [IO.Path]::Combine($Root, 'Acknowledged', $Receipt.RequestId + '.json')
    if ([IO.File]::Exists($path)) { return }
    $complete = Read-NetCrateJson ([IO.Path]::Combine($Receipt.LocalPath, 'COMPLETE.json'))
    $association = $Receipt.Association
    $ack = [ordered]@{ Version = 2; Kind = 'delivery-ack'; RequestId = $Receipt.RequestId; RequestedSnapshotId = $Receipt.RequestedSnapshotId
        GenerationSnapshotId = $Receipt.GenerationSnapshotId; ResultSnapshotId = $Receipt.ResultSnapshotId; JobId = $Receipt.JobId
        Recipe = $Receipt.Recipe; FootageFingerprint = $association.FootageFingerprint; MediaFiles = (2 * $complete.Clips) }
    Write-WorkflowRecord $Root $Settings delivery-ack $Receipt.RequestId $ack
    Write-NetCrateJson $path @{ RequestId = $Receipt.RequestId; ResultSnapshotId = $Receipt.ResultSnapshotId }
}

function Get-NetCrateReceipt {
    param([string]$Root, [string]$RequestId)
    if ($RequestId -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid request identity.' }
    $path = [IO.Path]::Combine($Root, 'Receipts', $RequestId + '.json')
    if ([IO.File]::Exists($path)) { return Read-NetCrateJson $path }
    return $null
}

function Invoke-NetCrateReceiver {
    param([string]$Root, $Settings)
    if ((Get-NetCrateBackupMode $Settings) -ceq 'Folder') { return }
    foreach ($progress in @(Read-WorkflowRecords $Root $Settings progress $Settings.WorkerComputer)) {
        if ($progress.Version -ne 2 -or $progress.Kind -cne 'progress' -or $progress.RequestId -cnotmatch '^[a-f0-9]{64}$' -or $progress.State -cnotin @('Processing', 'NeedsAttention')) { continue }
        $requestPath = [IO.Path]::Combine($Root, 'Requests', $progress.RequestId + '.json')
        if (-not [IO.File]::Exists($requestPath)) { continue }
        $request = Read-NetCrateJson $requestPath
        if ($progress.SnapshotId -cne $request.SnapshotId -or $progress.Recipe -cne $request.Recipe -or $progress.FootageFingerprint -cne $request.FootageFingerprint) { continue }
        $path = [IO.Path]::Combine($Root, 'JobProgress', $progress.RequestId + '.json')
        if (-not [IO.File]::Exists($path) -or [DateTimeOffset]$progress.UpdatedUtc -ge [DateTimeOffset](Read-NetCrateJson $path).UpdatedUtc) { Write-NetCrateJson $path $progress }
    }
    foreach ($association in @(Read-WorkflowRecords $Root $Settings association $Settings.WorkerComputer)) {
        if ($association.RequestId -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid association identity.' }
        $requestPath = [IO.Path]::Combine($Root, 'Requests', $association.RequestId + '.json')
        if (-not [IO.File]::Exists($requestPath)) { continue }
        $request = Read-NetCrateJson $requestPath
        $null = Test-NetCrateAssociation $association $request $Settings
        $existingReceipt = Get-NetCrateReceipt $Root $association.RequestId
        if ($existingReceipt) {
            $available = $false
            try {
                $availabilityOnly = $existingReceipt.State -ceq 'Ready'
                $null = Test-WorkflowResult $existingReceipt.LocalPath $association -AvailabilityOnly:$availabilityOnly
                if (-not $availabilityOnly) {
                    $existingReceipt.State = 'Ready'; $existingReceipt.VerifiedUtc = [DateTime]::UtcNow.ToString('o')
                    Write-NetCrateJson ([IO.Path]::Combine($Root, 'Receipts', $association.RequestId + '.json')) $existingReceipt
                }
                $available = $true
            } catch {
                $existingReceipt.State = 'NeedsAttention'
                Write-NetCrateJson ([IO.Path]::Combine($Root, 'Receipts', $association.RequestId + '.json')) $existingReceipt
            }
            if ($available) { Send-WorkflowDeliveryAck $Root $Settings $existingReceipt }
            continue
        }
        $project = Get-NetCrateProjectPath $Settings $association.ProjectPath
        $versions = [IO.Path]::Combine($project, 'Proxies', 'NetCrate')
        $null = Assert-NetCrateLocalPath $versions
        $destination = [IO.Path]::Combine($versions, $association.ResultSnapshotId)
        if ([IO.Directory]::Exists($destination)) { $null = Test-WorkflowResult $destination $association }
        else {
            $snapshots = @(Invoke-WorkflowRestic $Root $Settings Results @('snapshots', '--json', $association.ResultSnapshotId) | ConvertFrom-Json)
            if ($snapshots.Count -ne 1 -or $snapshots[0].hostname -cne $Settings.WorkerComputer -or @($snapshots[0].paths).Count -ne 1) { throw 'The result snapshot does not belong to the configured Backup Server.' }
            $remotePath = Convert-WorkflowSnapshotPath $snapshots[0].paths[0]
            $null = Assert-NetCrateRelativePath $remotePath.TrimStart('/')
            Test-WorkflowRemoteResult $Root $Settings $association $remotePath
            $stage = [IO.Path]::Combine($versions, '.incoming-' + [guid]::NewGuid().ToString('N'))
            $null = Invoke-WorkflowRestic $Root $Settings Results @('restore', ($association.ResultSnapshotId + ':' + $remotePath), '--target', $stage, '--verify')
            Assert-WorkflowTree $stage
            $restored = $stage
            $null = Test-WorkflowResult $restored $association
            [IO.Directory]::Move($restored, $destination)
        }
        $receipt = [ordered]@{ State = 'Ready'; RequestId = $association.RequestId; RequestedSnapshotId = $association.RequestedSnapshotId
            GenerationSnapshotId = $association.GenerationSnapshotId; ResultSnapshotId = $association.ResultSnapshotId; JobId = $association.JobId
            Recipe = $association.Recipe; LocalPath = $destination; Association = $association; VerifiedUtc = [DateTime]::UtcNow.ToString('o') }
        Write-NetCrateJson ([IO.Path]::Combine($Root, 'Receipts', $association.RequestId + '.json')) $receipt
        Send-WorkflowDeliveryAck $Root $Settings ([pscustomobject]$receipt)
    }
}

function New-NetCrateSample {
    param([string]$LiteralPath)
    $null = Assert-NetCrateLocalPath $LiteralPath
    if ([IO.File]::Exists($LiteralPath)) { throw 'The sample file already exists.' }
    # The package contains a small generated clip, with no personal footage.
    [IO.File]::Copy([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../install/sample.avi')), $LiteralPath, $false)
}

function Convert-WorkflowSnapshotPath([string]$Path) {
    if ($Path -match '^[A-Za-z]:\\') { return '/' + $Path.Substring(0, 1).ToUpperInvariant() + $Path.Substring(2).Replace('\', '/') }
    if ($Path -notmatch '^/[A-Z]/') { throw 'Unsupported snapshot path.' }
    return $Path
}

. (Join-Path $PSScriptRoot 'NetCrate.Schedule.ps1')
. (Join-Path $PSScriptRoot 'NetCrate.Queue.ps1')
. (Join-Path $PSScriptRoot 'NetCrate.RemoteResult.ps1')
Export-ModuleMember -Function Invoke-NetCrateBackup, Invoke-NetCrateWorker, Invoke-NetCrateReceiver, Get-NetCrateReceipt,
    New-NetCrateSample, Invoke-WorkflowRestic, Write-WorkflowRecord, Read-WorkflowRecords, Test-WorkflowResult, Assert-WorkflowTree,
    Add-NetCrateBackupQueue, Invoke-NetCrateQueue, Update-NetCrateQueue, Invoke-NetCrateOriginals,
    Save-NetCrateSchedule, Disable-NetCrateSchedule, Get-NetCrateSchedules, Invoke-NetCrateSchedules, Get-NetCrateScheduleOccurrence
