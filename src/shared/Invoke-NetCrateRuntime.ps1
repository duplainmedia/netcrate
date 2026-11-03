#requires -Version 7.4
param([Parameter(Mandatory)][string]$Root, [switch]$Once)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Workflow.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Credentials.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot '../../install/NetCrate.Engine.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Maintenance.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Endpoint.psm1')
$owner = Get-NetCrateOwner $Root
$created = $false
$mutex = [Threading.Mutex]::new($false, ('Local\NetCrate-Runtime-' + $owner.UserSid + '-' + $owner.InstallationId), [ref]$created)
$owned = $false; $workerMutex=$null; $workerOwned=$false; $endpointState = [pscustomobject]@{Process=$null;Job=$null}
$startedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
    if ($owner.Role -ceq 'Worker') {
        # Local mutexes do not span Windows sessions. A second signed-in session
        # must never start another worker or maintenance writer for this owner.
        $workerMutex=[Threading.Mutex]::new($false,('Global\NetCrate-Worker-'+$owner.UserSid+'-'+$owner.InstallationId))
        try {$workerOwned=$workerMutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$workerOwned=$true}
        if(-not $workerOwned){exit 0}
    }
    $scheduleStatus = $null
    $statusFile = [IO.Path]::Combine($Root, 'runtime-status.json')
    if ($owner.Role -ceq 'Source' -and [IO.File]::Exists($statusFile)) {
        try {
            $previous = Read-NetCrateJson $statusFile
            if ($previous.State -ceq 'NeedsAttention' -and $previous.PSObject.Properties.Name -contains 'Code' -and $previous.Code -ceq 'schedule-admission') {
                $scheduleStatus = [pscustomobject]@{ NeedsAttention=$true; Code=$previous.Code; Message=$previous.Message }
            }
        } catch { } # An invalid old heartbeat must not prevent a fresh owner pass.
    }
    do {
        try {
            # Retain known schedule attention until this pass reevaluates it.
            Write-NetCrateJson $statusFile @{ State = $(if ($scheduleStatus) { 'NeedsAttention' } else { 'Running' }); ProcessId = $PID; ProcessStartedUtc = $startedUtc; UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Code=$(if ($scheduleStatus) { $scheduleStatus.Code } else { '' }); Message=$(if ($scheduleStatus) { $scheduleStatus.Message } else { '' }) }
            $settings = Import-NetCrateSettings ([IO.Path]::Combine($Root, 'settings.json')) $owner.Role
            if ($owner.Role -ceq 'Worker') {
                # Drain a queued health request even when an offline drive prevents
                # the endpoint from starting. Apply still proves quiescence itself.
                $quiesce={Stop-NetCrateOwnedEndpoint $endpointState $Root}.GetNewClosure()
                $resume={Start-NetCrateOwnedEndpoint $endpointState $Root $settings}.GetNewClosure()
                Invoke-NetCrateMaintenancePass $Root $owner.InstallationId $quiesce $resume
                Start-NetCrateOwnedEndpoint $endpointState $Root $settings
                if ($settings.BackupMode -ceq 'Media' -and -not ($settings.PSObject.Properties.Name -contains 'SourceBackupMode' -and $settings.SourceBackupMode -ceq 'Folder')) { Invoke-NetCrateWorker $Root $settings }
            } else {
                $scheduleStatus = Invoke-NetCrateSchedules $Root $settings
                # Queue work can run for hours or be interrupted. Publish the
                # scheduler result before entering any synchronous backup work.
                Write-NetCrateJson $statusFile @{ State = $(if ($scheduleStatus) { 'NeedsAttention' } else { 'Running' }); ProcessId = $PID; ProcessStartedUtc = $startedUtc; UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                    Code=$(if ($scheduleStatus) { $scheduleStatus.Code } else { '' }); Message=$(if ($scheduleStatus) { $scheduleStatus.Message } else { '' }) }
                Invoke-NetCrateQueue $Root $settings
                if ($settings.BackupMode -ceq 'Media') { Invoke-NetCrateReceiver $Root $settings }
                Update-NetCrateQueue $Root $settings
            }
            Write-NetCrateJson ([IO.Path]::Combine($Root, 'runtime-status.json')) @{ State = $(if ($scheduleStatus) { 'NeedsAttention' } else { 'Running' }); ProcessId = $PID; ProcessStartedUtc = $startedUtc; UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Code=$(if ($scheduleStatus) { $scheduleStatus.Code } else { '' }); Message=$(if ($scheduleStatus) { $scheduleStatus.Message } else { '' }) }
        } catch {
            Write-NetCrateJson ([IO.Path]::Combine($Root, 'runtime-status.json')) @{ State = 'NeedsAttention'; ProcessId = $PID; ProcessStartedUtc = $startedUtc; UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Code=$(if ($scheduleStatus) { $scheduleStatus.Code } else { '' }); Message=$(if ($scheduleStatus) { $scheduleStatus.Message } elseif ($owner.Role -ceq 'Worker') { 'The Backup Server needs attention. Check its storage and private connection.' } else { $_.Exception.Message }) }
        }
        if (-not $Once) { Start-Sleep -Seconds 5 }
    } while (-not $Once)
} finally {
    try { if ($endpointState.Process -or $endpointState.Job) { Stop-NetCrateOwnedEndpoint $endpointState $Root } } catch { }
    if ($workerMutex) { if ($workerOwned) { $workerMutex.ReleaseMutex() }; $workerMutex.Dispose() }
    if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
