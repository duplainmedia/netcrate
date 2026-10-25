#requires -Version 5.1
param([Parameter(Mandatory)][ValidateSet('Inspect', 'Prepare', 'Network', 'SaveRecovery', 'ExportConnection', 'ImportConnection', 'ConfirmConnection', 'CheckConnection', 'CheckSample', 'Finish', 'QueueBackup')][string]$Action,
    [Parameter(Mandatory)][string]$InputFile)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Configuration.psm1')
    $state = Read-NetCrateJson $InputFile -MaximumBytes 32768
    if ($state.Version -ne 1 -or $state.Role -cnotin @('EditingComputer', 'BackupServer') -or $state.InstallationId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid setup input.' }
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
    if ($Action -ceq 'QueueBackup') {
        Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Workflow.psm1')
        $settings = Import-NetCrateSettings ([IO.Path]::Combine($root, 'settings.json')) Source
        $null = Add-NetCrateBackupQueue $root $settings $state.Path
        $result = @{ Succeeded = $true; Code = 'ok'; Message = 'The project was added to the backup queue.' }
    } else { $result = Invoke-NetCrateSetupAction $Action $state $root (Split-Path -Parent $PSScriptRoot) }
    $result | ConvertTo-Json -Depth 8 -Compress
} catch {
    $message = $_.Exception.Message
    if ($message.Length -gt 400 -or $message -match 'Exception|RESTIC_|password|token|[A-Za-z]:\\') { $message = 'This step could not finish. Check that both computers and drives are available, then try again.' }
    @{ Succeeded = $false; Code = 'action-required'; Message = $message } | ConvertTo-Json -Compress
    exit 1
}
