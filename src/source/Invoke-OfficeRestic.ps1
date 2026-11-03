param(
    [Parameter(Mandatory)]
    [ValidateSet('init', 'backup', 'check', 'ls', 'restore', 'snapshots', 'stats')]
    [string]$Operation,
    [string[]]$Arguments = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$expectedSid = 'S-1-5-21-100000000-200000000-300000000-1001'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.Name -ne 'SOURCE-PC\sample-user' -or $identity.User.Value -ne $expectedSid) {
    throw 'Unexpected Windows identity; backup command was not run.'
}
$queueControl = 'C:\Users\sample-user\OneDrive\Documents\Sample Studio\backup-records\office-backup-queue-control.json'
$excludedProjects = @()
if (Test-Path -LiteralPath $queueControl) {
    $excludedProjects = @((Get-Content -LiteralPath $queueControl -Raw | ConvertFrom-Json).ExcludedProjects)
}
if ($Operation -eq 'backup' -and (Test-Path -LiteralPath $queueControl)) {
    $control = Get-Content -LiteralPath $queueControl -Raw | ConvertFrom-Json
    foreach ($excluded in $control.ExcludedProjects) {
        foreach ($argument in $Arguments) {
            if ($argument -eq ('project:' + $excluded) -or $argument.Replace('/', '\').TrimEnd('\') -eq ('D:\Video Projects\' + $excluded)) {
                throw ('Project removed from backup queue by user: ' + $excluded)
            }
        }
    }
}
$directory = 'C:\Users\sample-user\AppData\Local\OfficeBackup\Credentials'
$restic = 'C:\Users\sample-user\AppData\Local\Microsoft\WinGet\Packages\restic.restic_Microsoft.Winget.Source_8wekyb3d8bbwe\restic_0.19.1_windows_amd64.exe'
try {
    $transport = Get-Content -LiteralPath (Join-Path $directory 'transport.json') -Raw | ConvertFrom-Json
    $repository = Get-Content -LiteralPath (Join-Path $directory 'repository.json') -Raw | ConvertFrom-Json
} catch { throw 'Protected backup credential files could not be loaded.' }
if ($transport.ProtectedForUserSid -ne $expectedSid -or $repository.ProtectedForUserSid -ne $expectedSid -or
    $transport.User -ne 'sample-user' -or
    $repository.RepositoryUrl -ne 'rest:http://backup.example:8000/sample-user/source-pc/' -or
    [string]::IsNullOrWhiteSpace($repository.RecoveryCopyConfirmedUtc)) {
    throw 'Backup credential identity, destination, or recovery confirmation is invalid.'
}
$transportSecure = $null
$repositorySecure = $null
$prior = @{}
$result = $null
$environmentNames = @('RESTIC_REPOSITORY', 'RESTIC_PASSWORD', 'RESTIC_REST_USERNAME',
    'RESTIC_REST_PASSWORD', 'RESTIC_CACHE_DIR', 'RESTIC_PASSWORD_FILE',
    'RESTIC_PASSWORD_COMMAND', 'RESTIC_REPOSITORY_FILE', 'HTTP_PROXY', 'HTTPS_PROXY',
    'ALL_PROXY', 'NO_PROXY')
try {
    foreach ($name in $environmentNames) { $prior[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $transportSecure = ConvertTo-SecureString -String $transport.PasswordDpapi
    $repositorySecure = ConvertTo-SecureString -String $repository.PasswordDpapi
    $env:RESTIC_REPOSITORY = $repository.RepositoryUrl
    $env:RESTIC_PASSWORD = [Management.Automation.PSCredential]::new('repository', $repositorySecure).GetNetworkCredential().Password
    $env:RESTIC_REST_USERNAME = $transport.User
    $env:RESTIC_REST_PASSWORD = [Management.Automation.PSCredential]::new($transport.User, $transportSecure).GetNetworkCredential().Password
    $env:RESTIC_CACHE_DIR = 'C:\Users\sample-user\AppData\Local\OfficeBackup\Cache'
    $env:RESTIC_PASSWORD_FILE = $null
    $env:RESTIC_PASSWORD_COMMAND = $null
    $env:RESTIC_REPOSITORY_FILE = $null
    $env:HTTP_PROXY = $null
    $env:HTTPS_PROXY = $null
    $env:ALL_PROXY = $null
    $env:NO_PROXY = 'backup.example,ncs.netbird.cloud'
    New-Item -ItemType Directory -Path $env:RESTIC_CACHE_DIR -Force | Out-Null
    $runRoot = 'C:\Users\sample-user\AppData\Local\OfficeBackup\Runs'
    if ($Operation -eq 'backup') {
        . (Join-Path $PSScriptRoot 'automatic-proxies\FolderLauncher.Common.ps1')
        $Arguments = @(Get-OfficeBackupArguments -Arguments $Arguments)
        # Keep this invocation's output separate. Never infer a snapshot using "latest".
        if ($Arguments -notcontains '--json') { $Arguments = @('--json') + $Arguments }
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
        $backupJsonLog = Join-Path $runRoot ($runId + '.backup.jsonl')
        $runStatus = $null
        try {
            . (Join-Path $PSScriptRoot 'office-jobs-app\OfficeBackupStatus.ps1')
            $runStatus = New-OfficeBackupRunStatus -RunId $runId -LogPath $backupJsonLog -Arguments $Arguments
            $runStatusPath = Join-Path $runRoot ($runId + '.backup-status.json')
            $null = Save-OfficeBackupRunStatus -Record $runStatus -Path $runStatusPath
        } catch { $runStatus = $null } # Optional UI telemetry cannot prevent a backup.
        $writer = [IO.StreamWriter]::new($backupJsonLog, $false, [Text.UTF8Encoding]::new($false))
        try {
            & $restic $Operation @Arguments | ForEach-Object { $writer.WriteLine([string]$_); $writer.Flush(); $_ }
            $result = $LASTEXITCODE
        } finally {
            $writer.Dispose()
            try {
                if ($null -ne $runStatus) {
                    $runStatus.State = if ($null -eq $result) { 'Interrupted' } elseif ($result -eq 0) { 'Completed' } else { 'Failed' }
                    $runStatus.ExitCode = $result
                    $null = Save-OfficeBackupRunStatus -Record $runStatus -Path $runStatusPath
                }
            } catch { } # Keep the native exit/result authoritative.
        }
    } else {
        & $restic $Operation @Arguments
        $result = $LASTEXITCODE
    }
    if ($result -ne 0) { throw ('Restic ' + $Operation + ' failed with exit code ' + $result + '. No retention cleanup was requested.') }
    # Only a successful primary backup creates a durable media event. Hook failures
    # are reported separately and must never turn a good backup into a failed one.
    try {
        . (Join-Path $PSScriptRoot 'PrimaryBackupMediaHook.ps1')
        if ($Operation -eq 'backup') {
            $snapshot = Get-PrimaryBackupSnapshot -BackupExitCode $result -BackupJsonLogPath $backupJsonLog
            $event = [ordered]@{ Version=1; State='Pending'; BackupExitCode=$result; SnapshotId=$snapshot; BackupLog=$backupJsonLog; ProjectPaths=@(); Error=$null; CreatedUtc=[DateTime]::UtcNow.ToString('o'); UpdatedUtc=[DateTime]::UtcNow.ToString('o') }
            Save-PrimaryMediaEvent -Event $event -Path (Join-Path $runRoot ($runId + '.media-success.json'))
        }
        if (Test-Path -LiteralPath $runRoot) {
            Invoke-PrimaryMediaPending -RunRoot $runRoot -ResticExe $restic -ExcludedProjects $excludedProjects
        }
    } catch {
        # This record contains command metadata only. Never log credential values.
        try {
            if ($Operation -eq 'backup' -and $null -ne $runStatus) {
                $runStatus.MediaHookState = 'Failed'
                $null = Save-OfficeBackupRunStatus -Record $runStatus -Path $runStatusPath
            }
        } catch { }
        $failure = [ordered]@{ State='HookError'; Operation=$Operation; BackupExitCode=$result; Error=$_.Exception.Message; UpdatedUtc=[DateTime]::UtcNow.ToString('o') }
        try {
            $failure | ConvertTo-Json | Set-Content -LiteralPath 'C:\Users\sample-user\AppData\Local\OfficeBackup\media-hook-error.json' -Encoding UTF8
        } catch { } # Error reporting must not change the successful backup result.
        Write-Warning 'Restic succeeded, but the automatic media hook needs review. Check local hook metadata if available.' -WarningAction Continue
    }
} finally {
    foreach ($name in $environmentNames) {
        if ($prior.ContainsKey($name)) { [Environment]::SetEnvironmentVariable($name, $prior[$name], 'Process') }
    }
    if ($null -ne $transportSecure) { $transportSecure.Dispose() }
    if ($null -ne $repositorySecure) { $repositorySecure.Dispose() }
    $transport = $null
    $repository = $null
    if ($null -ne $result) { $global:LASTEXITCODE = $result }
}
