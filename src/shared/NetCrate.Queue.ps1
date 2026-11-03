function Add-NetCrateBackupQueue {
    param([string]$Root, $Settings, [string]$Project, [switch]$Sample, [string]$OccurrenceId, [string]$LocalDate, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    Invoke-NetCrateAdmissionLock $Root { Add-NetCrateBackupQueueCore $Root $Settings $Project -Sample:$Sample -OccurrenceId $OccurrenceId -LocalDate $LocalDate -Now $Now }
}

function Add-NetCrateBackupQueueCore {
    param([string]$Root, $Settings, [string]$Project, [switch]$Sample, [string]$OccurrenceId, [string]$LocalDate, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    $mode = Get-NetCrateBackupMode $Settings
    if ($Sample) {
        $Project = [IO.Path]::Combine($Settings.ActiveRoot, 'NetCrate sample-' + $Settings.InstallationId.Substring(0, 8))
        $marker = [IO.Path]::Combine($Root, 'sample-project.json')
        if (-not [IO.File]::Exists($marker)) {
            if ([IO.Directory]::Exists($Project)) { throw 'The sample folder name is already in use. Its contents were preserved.' }
            Write-NetCrateJson $marker @{ Version = 1; InstallationId = $Settings.InstallationId; Project = $Project }
        }
        $ownership = Read-NetCrateJson $marker
        if ($ownership.InstallationId -cne $Settings.InstallationId -or $ownership.Project -cne $Project) { throw 'The sample folder belongs to another setup.' }
        $null = Assert-NetCrateLocalPath $Project
        $null = [IO.Directory]::CreateDirectory($Project)
        $samplePath = [IO.Path]::Combine($Project, $(if ($mode -ceq 'Folder') { 'sample.txt' } else { 'sample.avi' }))
        if ($mode -ceq 'Folder') {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes("NetCrate folder backup sample`r`nKnown original bytes: 0123456789 日本語`r`n")
            if ([IO.File]::Exists($samplePath)) {
                if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($samplePath)) -cne [Convert]::ToBase64String($bytes)) { throw 'The sample file changed. Its contents were preserved.' }
            } else { [IO.File]::WriteAllBytes($samplePath, $bytes) }
        } else {
        $original = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../install/sample.avi'))
        if ([IO.File]::Exists($samplePath)) {
            if ((Get-FileHash -LiteralPath $samplePath).Hash -cne (Get-FileHash -LiteralPath $original).Hash) { throw 'The sample file changed. Its contents were preserved.' }
        } else {
            $stage = [IO.Path]::Combine($Project, '.netcrate-sample-' + [guid]::NewGuid().ToString('N') + '.writing')
            New-NetCrateSample $stage
            [IO.File]::Move($stage, $samplePath)
        }
        }
    }
    $path = Get-NetCrateBackupPath $Settings $Project $mode
    if (-not [IO.Directory]::Exists($path)) { throw 'The project folder is not available.' }
    $queue = [IO.Path]::Combine($Root, 'Queue'); $null = [IO.Directory]::CreateDirectory($queue)
    $associationFile = if ($OccurrenceId) { [IO.Path]::Combine($Root, 'ScheduleOccurrences', (Get-NetCrateHash $OccurrenceId) + '.json') } else { '' }
    if ($associationFile -and [IO.File]::Exists($associationFile)) {
        $association = Read-NetCrateJson $associationFile
        $id = $association.JobId
    } else {
        $active = @([IO.Directory]::EnumerateFiles($queue, '*.json') | ForEach-Object { Read-NetCrateJson $_ } | Where-Object {
            $_.Project.Equals($path, [StringComparison]::OrdinalIgnoreCase) -and $_.State -cin @('Queued','BackingUp','NeedsAttention') -and $_.SnapshotId -cnotmatch '^[a-f0-9]{64}$'
        } | Select-Object -First 1)
        $reservations = [IO.Path]::Combine($Root, 'ScheduleOccurrences')
        $reserved = @(if ([IO.Directory]::Exists($reservations)) { [IO.Directory]::EnumerateFiles($reservations, '*.json') | ForEach-Object { Read-NetCrateJson $_ } | Where-Object {
            $_.Project.Equals($path, [StringComparison]::OrdinalIgnoreCase) -and -not [IO.File]::Exists([IO.Path]::Combine($queue, $_.JobId + '.json'))
        } | Select-Object -First 1 })
        $id = if ($active.Count) { $active[0].Id } elseif ($Sample) { Get-NetCrateHash ('sample|' + $Settings.InstallationId) } elseif ($reserved.Count) { $reserved[0].JobId } elseif ($OccurrenceId) { Get-NetCrateHash ('schedule|' + $OccurrenceId) } else { [guid]::NewGuid().ToString('N') }
        # Durable assignment precedes queue creation and cursor advancement. Replay repairs a missing job using this ID.
        if ($associationFile) { Write-NetCrateJson $associationFile @{Version=1; OccurrenceId=$OccurrenceId; LocalDate=$LocalDate; JobId=$id; Project=$path} }
    }
    $file = [IO.Path]::Combine($queue, $id + '.json')
    if (-not $Sample -and [IO.File]::Exists($file)) { return $file }
    if ([IO.File]::Exists($file)) {
        $existing = Read-NetCrateJson $file
        if ($existing.State -ceq 'Ready') { return $file }
        $existing.State = 'Queued'; $existing.RetryAfterUtc = $Now.ToString('o'); Write-NetCrateJson $file $existing
    } else {
        Write-NetCrateJson $file ([ordered]@{ Version = 1; Id = $id; Project = $path; State = 'Queued'; Sample = [bool]$Sample; BackupMode = $mode
            BackupCompletedUtc = ''; MediaState = $(if ($mode -ceq 'Folder') { 'Off' } else { 'Pending' })
            SnapshotId = ''; RequestId = ''; CreatedUtc = $Now.ToString('o'); UpdatedUtc = $Now.ToString('o'); RetryAfterUtc = $Now.ToString('o') })
    }
    return $file
}

function Invoke-NetCrateQueue {
    param([string]$Root, $Settings)
    $queue = [IO.Path]::Combine($Root, 'Queue'); $null = [IO.Directory]::CreateDirectory($queue)
    foreach ($file in [IO.Directory]::EnumerateFiles($queue, '*.json')) {
        $status = Read-NetCrateJson $file
        if ($status.State -notin @('Queued', 'BackingUp', 'NeedsAttention') -or [DateTimeOffset]$status.RetryAfterUtc -gt [DateTimeOffset]::UtcNow) { continue }
        try {
            $mode = Get-NetCrateBackupMode $status
            $status.State = 'BackingUp'; $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
            if ($mode -ceq 'Folder') {
                $status = Invoke-NetCrateOriginals $Root $Settings $status.Project $file Folder
                if ($status.Sample) {
                    $verificationRoot = Assert-NetCrateLocalPath ([IO.Path]::Combine($Root, 'SampleVerification'))
                    $restore = [IO.Path]::Combine($verificationRoot, [guid]::NewGuid().ToString('N'))
                    try {
                        $null = [IO.Directory]::CreateDirectory($restore)
                        $null = Invoke-WorkflowRestic $Root $Settings Primary @('restore', ($status.SnapshotId + ':' + (Get-NetCrateSnapshotRoot $status.Project)), '--include', '/sample.txt', '--target', $restore, '--verify')
                        $expected = [Text.UTF8Encoding]::new($false).GetBytes("NetCrate folder backup sample`r`nKnown original bytes: 0123456789 日本語`r`n")
                        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes([IO.Path]::Combine($restore, 'sample.txt'))) -cne [Convert]::ToBase64String($expected)) { throw 'The sample restore differs from its known original bytes.' }
                    } finally {
                        if ([IO.Directory]::Exists($restore)) {
                            $resolved = Assert-NetCrateLocalPath $restore
                            if ([IO.Path]::GetDirectoryName($resolved) -cne $verificationRoot -or [IO.Path]::GetFileName($resolved) -cnotmatch '^[a-f0-9]{32}$') { throw 'The disposable sample restore is outside its verification folder.' }
                            [IO.Directory]::Delete($resolved, $true)
                        }
                    }
                }
                $status.State = 'Ready'; $status.MediaState = 'Off'; $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
                continue
            }
            $request = Invoke-NetCrateBackup $Root $Settings $status.Project $file
            $status = Read-NetCrateJson $file
            $status.RequestId = Get-NetCrateRequestId $request.SnapshotId $request.ProjectPath $request.Recipe
            $status.MediaState = 'Pending'; $status.State = 'WaitingForProxies'; $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
        } catch {
            $status = Read-NetCrateJson $file; $status.State = 'NeedsAttention'
            if ((Get-NetCrateBackupMode $status) -ceq 'Media') { $status | Add-Member -NotePropertyName MediaState -NotePropertyValue 'NeedsAttention' -Force }
            $status.RetryAfterUtc = [DateTime]::UtcNow.AddSeconds(30).ToString('o'); $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
        }
    }
}

function Update-NetCrateQueue {
    param([string]$Root, $Settings)
    foreach ($file in [IO.Directory]::EnumerateFiles([IO.Path]::Combine($Root, 'Queue'), '*.json')) {
        $status = Read-NetCrateJson $file
        if ((Get-NetCrateBackupMode $status) -ceq 'Folder') { continue }
        $receipt = if ($status.RequestId -cmatch '^[a-f0-9]{64}$') { Get-NetCrateReceipt $Root $status.RequestId } else { $null }
        $media = if ($status.PSObject.Properties.Name -contains 'MediaState') { $status.MediaState } else { '' }
        $nextState = $status.State; $nextMedia = $media
        if ($receipt -and $receipt.State -ceq 'Ready') {
            # Verified local delivery takes precedence over stale worker progress.
            $nextState = 'Ready'; $nextMedia = 'Ready'
        } elseif ($status.RequestId -cmatch '^[a-f0-9]{64}$') {
            $progressFile = [IO.Path]::Combine($Root, 'JobProgress', $status.RequestId + '.json')
            $progress = if ([IO.File]::Exists($progressFile)) { Read-NetCrateJson $progressFile } else { $null }
            if (($receipt -and $receipt.State -ceq 'NeedsAttention') -or ($progress -and $progress.SnapshotId -ceq $status.SnapshotId -and $progress.State -ceq 'NeedsAttention')) {
                $nextMedia = 'NeedsAttention'
            }
        }
        if ($nextState -cne $status.State -or $nextMedia -cne $media) {
            $status.State = $nextState
            $status | Add-Member -NotePropertyName MediaState -NotePropertyValue $nextMedia -Force
            $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
        }
    }
}
