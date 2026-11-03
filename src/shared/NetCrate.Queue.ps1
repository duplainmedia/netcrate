function Add-NetCrateBackupQueue {
    param([string]$Root, $Settings, [string]$Project, [switch]$Sample)
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
    $id = if ($Sample) { Get-NetCrateHash ('sample|' + $Settings.InstallationId) } else { [guid]::NewGuid().ToString('N') }
    $file = [IO.Path]::Combine($queue, $id + '.json')
    if ([IO.File]::Exists($file)) {
        $existing = Read-NetCrateJson $file
        if ($existing.State -ceq 'Ready') { return $file }
        $existing.State = 'Queued'; $existing.RetryAfterUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $existing
    } else {
        Write-NetCrateJson $file ([ordered]@{ Version = 1; Id = $id; Project = $path; State = 'Queued'; Sample = [bool]$Sample; BackupMode = $mode
            BackupCompletedUtc = ''; MediaState = $(if ($mode -ceq 'Folder') { 'Off' } else { 'Pending' })
            SnapshotId = ''; RequestId = ''; CreatedUtc = [DateTime]::UtcNow.ToString('o'); UpdatedUtc = [DateTime]::UtcNow.ToString('o'); RetryAfterUtc = [DateTime]::UtcNow.ToString('o') })
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
                    $restore = [IO.Path]::Combine($Root, 'SampleVerification', [guid]::NewGuid().ToString('N'))
                    $null = Invoke-WorkflowRestic $Root $Settings Primary @('restore', ($status.SnapshotId + ':' + (Get-NetCrateSnapshotRoot $status.Project)), '--target', $restore, '--verify')
                    $expected = [Text.UTF8Encoding]::new($false).GetBytes("NetCrate folder backup sample`r`nKnown original bytes: 0123456789 日本語`r`n")
                    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes([IO.Path]::Combine($restore, 'sample.txt'))) -cne [Convert]::ToBase64String($expected)) { throw 'The sample restore differs from its known original bytes.' }
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
        if ($receipt -and $receipt.State -ceq 'Ready' -and $status.State -cne 'Ready') {
            $status | Add-Member -NotePropertyName MediaState -NotePropertyValue 'Ready' -Force
            $status.State = 'Ready'; $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
        } elseif ($status.RequestId -cmatch '^[a-f0-9]{64}$') {
            $progressFile = [IO.Path]::Combine($Root, 'JobProgress', $status.RequestId + '.json')
            $progress = if ([IO.File]::Exists($progressFile)) { Read-NetCrateJson $progressFile } else { $null }
            if (($receipt -and $receipt.State -ceq 'NeedsAttention') -or ($progress -and $progress.SnapshotId -ceq $status.SnapshotId -and $progress.State -ceq 'NeedsAttention')) {
                $status | Add-Member -NotePropertyName MediaState -NotePropertyValue 'NeedsAttention' -Force
                $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
            }
        }
    }
}
