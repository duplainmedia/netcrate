#requires -Version 5.1
param([Parameter(Mandatory)][ValidateSet('Inspect', 'Prepare', 'Network', 'SaveRecovery', 'ExportConnection', 'ImportConnection', 'ConfirmConnection', 'CheckConnection', 'CheckSample', 'Finish', 'QueueBackup', 'ListBackups', 'ListBackupChildren', 'RestoreSelection', 'ListSchedules', 'SaveSchedule', 'DisableSchedule','StorageStatus','CheckStorage','PreviewRetention','ApplyRetention')][string]$Action,
    [Parameter(Mandatory)][string]$InputFile)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Both the PS5 producer/relay and PS7 producer must match the UTF8 C# reader.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
try {
    Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Configuration.psm1')
    $state = Read-NetCrateJson $InputFile -MaximumBytes 32768
    $restoreAction = $Action -cin @('ListBackups','ListBackupChildren','RestoreSelection')
    if ($restoreAction) {
        $root = [IO.Path]::Combine([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($InputFile)), 'Engine')
        $null = Assert-NetCrateLocalPath $root
        foreach ($name in @('RecoveryFile','RepositoryPath','DestinationParent')) {
            if ($state.PSObject.Properties.Name -contains $name -and $state.$name) {
                if ($state.$name -isnot [string] -or $state.$name.Length -gt 240) { throw 'Choose a shorter ordinary local path.' }
                $null = Assert-NetCrateLocalPath $state.$name
            }
        }
        foreach ($name in @('SnapshotId','RelativePath','Cursor')) {
            if ($state.PSObject.Properties.Name -contains $name -and $null -ne $state.$name -and ($state.$name -isnot [string] -or $state.$name.Length -gt 1024)) { throw 'The backup selection is invalid.' }
        }
        if ($state.Version -ne 1) { throw 'The recovery request is unsupported.' }
        $independent = $state.PSObject.Properties.Name -contains 'RecoveryFile' -and $state.RecoveryFile
        if ($independent -and (-not $state.RepositoryPath)) { throw 'Choose the attached originals backup folder.' }
        if (-not $independent -and ($state.Role -cne 'EditingComputer' -or $state.InstallationId -cnotmatch '^[a-f0-9]{32}$')) { throw 'Open restore from the source dashboard or choose a recovery file.' }
        $bootstrap = [IO.Path]::Combine([IO.Path]::GetDirectoryName($InputFile), 'Bootstrap')
        Import-Module (Join-Path $PSScriptRoot 'NetCrate.Dependencies.psm1')
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            $tools = Install-NetCrateRecoveryTools $bootstrap @('PowerShell')
            & $tools.PowerShell -NoLogo -NoProfile -NonInteractive -File $PSCommandPath -Action $Action -InputFile $InputFile
            exit $LASTEXITCODE
        }
        $restic = ''
        if ($independent) { $restic = (Install-NetCrateRecoveryTools $bootstrap @('Restic')).Restic }
        Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Restore.psm1')
        $result = Invoke-NetCrateRestoreAction $Action $state $root $restic
        $result | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }
    if ($state.Version -ne 1 -or $state.Role -cnotin @('EditingComputer', 'BackupServer') -or $state.InstallationId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid setup input.' }
    $mode = Get-NetCrateBackupMode $state
    foreach ($field in @('Folder','Path')) {
        if ($state.PSObject.Properties.Name -contains $field -and $state.$field) {
            if ($state.$field -isnot [string] -or $state.$field.Length -gt 240) { throw 'The selected path is too long or invalid.' }
            $null = Assert-NetCrateLocalPath $state.$field
        }
    }
    $root = [IO.Path]::Combine([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($InputFile)), 'Engine')
    $null = Assert-NetCrateLocalPath $root
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $bootstrap = [IO.Path]::Combine([IO.Path]::GetDirectoryName($InputFile), 'Bootstrap')
        Import-Module (Join-Path $PSScriptRoot 'NetCrate.Dependencies.psm1')
        $package = (Get-NetCrateDependencyCatalog).Packages | Where-Object Name -CEQ PowerShell
        if ($Action -ceq 'Inspect') {
            $probe = [IO.Path]::Combine($bootstrap, 'Tools', 'PowerShell', $package.Version, 'pwsh.exe')
            if (-not [IO.File]::Exists($probe) -or -not [IO.File]::Exists([IO.Path]::Combine($root, 'prepared.json'))) {
                @{ Succeeded = $false; Code = 'prepare-needed'; Message = 'Choose Prepare this computer to install the required software.' } | ConvertTo-Json -Compress
                exit 0
            }
            & $probe -NoLogo -NoProfile -NonInteractive -File $PSCommandPath -Action $Action -InputFile $InputFile
            exit $LASTEXITCODE
        }
        $archive = Get-NetCratePackageArchive $package ([IO.Path]::Combine($bootstrap, 'Downloads'))
        $runtime = Expand-NetCrateDependency $archive $package ([IO.Path]::Combine($bootstrap, 'Tools'))
        & ([IO.Path]::Combine($runtime, 'pwsh.exe')) -NoLogo -NoProfile -NonInteractive -File $PSCommandPath -Action $Action -InputFile $InputFile
        exit $LASTEXITCODE
    }
    Import-Module (Join-Path $PSScriptRoot 'NetCrate.Engine.psm1') -DisableNameChecking
    if ($Action -cin @('StorageStatus','CheckStorage','PreviewRetention','ApplyRetention')) {
        Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Maintenance.psm1')
        Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Credentials.psm1')
        $allowed=@('Version','InstallationId','Role')
        if($Action -ceq 'PreviewRetention'){$allowed+=@('Policy','Count')}
        if($Action -ceq 'ApplyRetention'){$allowed+=@('PreviewId','Confirm')}
        if(@($state.PSObject.Properties.Name|Where-Object {$_ -cnotin $allowed}).Count){throw 'The storage request contains unsupported fields.'}
        if($state.Role -cne 'BackupServer'){throw 'Open storage controls on the Backup Server.'}
        $owner=Get-NetCrateOwner $root
        $prepared=Read-NetCrateJson ([IO.Path]::Combine($root,'prepared.json'))
        if($owner.Role -cne 'Worker' -or $owner.InstallationId -cne $state.InstallationId -or $prepared.Role -cne 'Worker' -or $prepared.InstallationId -cne $owner.InstallationId){throw 'These storage controls do not match the owning installation.'}
        $preparedFolder=Assert-NetCrateLocalPath $prepared.Folder
        if($Action -cin @('PreviewRetention','ApplyRetention')){
            $context=Get-NetCrateMaintenanceContext $root $state.InstallationId
            if(-not $preparedFolder.Equals($context.Binding.StorageRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'These storage controls do not match the owning installation.'}
        }
        if($Action -cne 'StorageStatus'){
            $parameters=@{}
            foreach($name in @('Policy','Count','PreviewId','Confirm')){if($state.PSObject.Properties.Name -ccontains $name){$parameters[$name]=$state.$name}}
            $queued=Invoke-NetCrateMaintenanceRequest $root $state.InstallationId $Action $parameters
        }
        $result=@{Succeeded=$true;Code='ok';Message=$(if($Action -ceq 'StorageStatus'){'Storage status refreshed.'}else{'The storage request is queued for the signed-in Backup Server.'});Maintenance=(Get-NetCrateMaintenanceStatus $root $state.InstallationId);OperationId=$(if($Action -cne 'StorageStatus'){$queued.OperationId}else{''})}
    } elseif ($Action -cin @('QueueBackup', 'ListSchedules', 'SaveSchedule', 'DisableSchedule')) {
        Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Workflow.psm1')
        Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Credentials.psm1')
        $owner = Get-NetCrateOwner $root
        $prepared = Read-NetCrateJson ([IO.Path]::Combine($root, 'prepared.json'))
        if ($state.Role -cne 'EditingComputer' -or $owner.Role -cne 'Source' -or $owner.InstallationId -cne $state.InstallationId -or $prepared.Role -cne 'Source' -or $prepared.InstallationId -cne $owner.InstallationId -or (Get-NetCrateBackupMode $prepared) -cne $mode -or -not $prepared.Folder.Equals($state.Folder,[StringComparison]::OrdinalIgnoreCase)) { throw 'The backup action does not match this source installation.' }
        $settings = Import-NetCrateSettings ([IO.Path]::Combine($root, 'settings.json')) Source
        if ($settings.InstallationId -cne $owner.InstallationId -or (Get-NetCrateBackupMode $settings) -cne $mode -or -not $settings.StateRoot.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or -not $settings.ActiveRoot.Equals($prepared.Folder,[StringComparison]::OrdinalIgnoreCase)) { throw 'The backup settings do not match this installation.' }
        if ($Action -ceq 'QueueBackup') {
            $null = Add-NetCrateBackupQueue $root $settings $state.Path
            $result = @{ Succeeded = $true; Code = 'ok'; Message = 'The folder was added to the backup queue.' }
        } else {
            if ($Action -ceq 'SaveSchedule') {
                if ($state.PSObject.Properties.Name -notcontains 'TimeOfDay' -or $state.TimeOfDay -isnot [string] -or $state.TimeOfDay.Length -ne 5 -or $state.PSObject.Properties.Name -notcontains 'Enabled' -or $state.Enabled -isnot [bool]) { throw 'Choose a daily time in HH:mm format and whether to enable the schedule.' }
                $null = Save-NetCrateSchedule $root $settings $state.Path $state.TimeOfDay $state.Enabled
            } elseif ($Action -ceq 'DisableSchedule') { Disable-NetCrateSchedule $root $settings $state.Path }
            $result = @{ Succeeded=$true; Code='ok'; Message=$(if ($Action -ceq 'ListSchedules') {'Automatic backups require both computers to be on, signed in and connected.'} else {'The schedule was saved.'}); Schedules=@(Get-NetCrateSchedules $root) }
        }
    } else { $result = Invoke-NetCrateSetupAction $Action $state $root (Split-Path -Parent $PSScriptRoot) }
    $result | ConvertTo-Json -Depth 8 -Compress
} catch {
    $message = $_.Exception.Message
    if ($message.Length -gt 400 -or $message -match 'Exception|RESTIC_|password|token|[A-Za-z]:\\') { $message = 'This step could not finish. Check that both computers and drives are available, then try again.' }
    @{ Succeeded = $false; Code = 'action-required'; Message = $message } | ConvertTo-Json -Compress
    exit 1
}
