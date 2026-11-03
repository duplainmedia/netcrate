#requires -Version 7.4
param([Parameter(Mandatory)][string]$Root, [switch]$Once)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Workflow.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Credentials.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot '../../install/NetCrate.Engine.psm1')
$owner = Get-NetCrateOwner $Root
$created = $false
$mutex = [Threading.Mutex]::new($false, ('Local\NetCrate-Runtime-' + $owner.UserSid + '-' + $owner.InstallationId), [ref]$created)
$owned = $false; $server = $null
$startedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
    do {
        $scheduleStatus = $null
        try {
            Write-NetCrateJson ([IO.Path]::Combine($Root, 'runtime-status.json')) @{ State = 'Running'; ProcessId = $PID; ProcessStartedUtc = $startedUtc; UpdatedUtc = [DateTime]::UtcNow.ToString('o') }
            $settings = Import-NetCrateSettings ([IO.Path]::Combine($Root, 'settings.json')) $owner.Role
            if ($owner.Role -ceq 'Worker') {
                if (-not $server -or $server.HasExited) {
                    $start = [Diagnostics.ProcessStartInfo]::new($settings.Tools.RestServer)
                    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                    foreach ($arg in (Get-NetCrateServerArguments $Root)) { $start.ArgumentList.Add($arg) }
                    $server = [Diagnostics.Process]::Start($start)
                }
                if ($settings.BackupMode -ceq 'Media' -and -not ($settings.PSObject.Properties.Name -contains 'SourceBackupMode' -and $settings.SourceBackupMode -ceq 'Folder')) { Invoke-NetCrateWorker $Root $settings }
            } else {
                $scheduleStatus = Invoke-NetCrateSchedules $Root $settings
                Invoke-NetCrateQueue $Root $settings
                if ($settings.BackupMode -ceq 'Media') { Invoke-NetCrateReceiver $Root $settings }
                Update-NetCrateQueue $Root $settings
            }
            Write-NetCrateJson ([IO.Path]::Combine($Root, 'runtime-status.json')) @{ State = $(if ($scheduleStatus) { 'NeedsAttention' } else { 'Running' }); ProcessId = $PID; ProcessStartedUtc = $startedUtc; UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Code=$(if ($scheduleStatus) { $scheduleStatus.Code } else { '' }); Message=$(if ($scheduleStatus) { $scheduleStatus.Message } else { '' }) }
        } catch {
            Write-NetCrateJson ([IO.Path]::Combine($Root, 'runtime-status.json')) @{ State = 'NeedsAttention'; ProcessId = $PID; ProcessStartedUtc = $startedUtc; UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Code=$(if ($scheduleStatus) { $scheduleStatus.Code } else { '' }); Message=$(if ($scheduleStatus) { $scheduleStatus.Message } else { $_.Exception.Message }) }
        }
        if (-not $Once) { Start-Sleep -Seconds 5 }
    } while (-not $Once)
} finally {
    if ($server) { if (-not $server.HasExited) { $server.Kill($true) }; $server.Dispose() }
    if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
