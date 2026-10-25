function Add-NetCrateBackupQueue {
    param([string]$Root, $Settings, [string]$Project, [switch]$Sample)
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
        $samplePath = [IO.Path]::Combine($Project, 'sample.avi')
        $original = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../install/sample.avi'))
        if ([IO.File]::Exists($samplePath)) {
            if ((Get-FileHash -LiteralPath $samplePath).Hash -cne (Get-FileHash -LiteralPath $original).Hash) { throw 'The sample file changed. Its contents were preserved.' }
        } else {
            $stage = [IO.Path]::Combine($Project, '.netcrate-sample-' + [guid]::NewGuid().ToString('N') + '.writing')
            New-NetCrateSample $stage
            [IO.File]::Move($stage, $samplePath)
        }
    }
    $path = Assert-NetCrateLocalPath $Project
    $null = Get-NetCrateProjectPath $Settings (Get-NetCrateSnapshotRoot $path)
    if (-not [IO.Directory]::Exists($path)) { throw 'The project folder is not available.' }
    $queue = [IO.Path]::Combine($Root, 'Queue'); $null = [IO.Directory]::CreateDirectory($queue)
    $id = if ($Sample) { Get-NetCrateHash ('sample|' + $Settings.InstallationId) } else { [guid]::NewGuid().ToString('N') }
    $file = [IO.Path]::Combine($queue, $id + '.json')
    if ([IO.File]::Exists($file)) {
        $existing = Read-NetCrateJson $file
        if ($existing.State -ceq 'Ready') { return $file }
        $existing.State = 'Queued'; $existing.RetryAfterUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $existing
    } else {
        Write-NetCrateJson $file ([ordered]@{ Version = 1; Id = $id; Project = $path; State = 'Queued'; Sample = [bool]$Sample
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
            $status.State = 'BackingUp'; $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
            $request = Invoke-NetCrateBackup $Root $Settings $status.Project $file
            $status = Read-NetCrateJson $file
            $status.RequestId = Get-NetCrateRequestId $request.SnapshotId $request.ProjectPath $request.Recipe
            $status.State = 'WaitingForProxies'; $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
        } catch {
            $status = Read-NetCrateJson $file; $status.State = 'NeedsAttention'
            $status.RetryAfterUtc = [DateTime]::UtcNow.AddSeconds(30).ToString('o'); $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
        }
    }
}

function Update-NetCrateQueue {
    param([string]$Root, $Settings)
    foreach ($file in [IO.Directory]::EnumerateFiles([IO.Path]::Combine($Root, 'Queue'), '*.json')) {
        $status = Read-NetCrateJson $file
        $receipt = if ($status.RequestId -cmatch '^[a-f0-9]{64}$') { Get-NetCrateReceipt $Root $status.RequestId } else { $null }
        if ($receipt -and $receipt.State -ceq 'Ready' -and $status.State -cne 'Ready') {
            $status.State = 'Ready'; $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Write-NetCrateJson $file $status
        }
    }
}
