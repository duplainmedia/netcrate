#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\shared\NetCrate.Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot '..\src\shared\NetCrate.Credentials.psm1')
Import-Module (Join-Path $PSScriptRoot '..\src\shared\NetCrate.Process.psm1')

function Get-NetCrateRepositorySecrets {
    param([Parameter(Mandatory)][string]$Root)
    return Unprotect-NetCrateRecord $Root 'repositories'
}

function Initialize-NetCrateRepositories {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$StorageRoot, [Parameter(Mandatory)][string]$ResticExe)
    $owner = Get-NetCrateOwner $Root
    if ($owner.Role -cne 'Worker') { throw 'Create repositories on the Backup Server.' }
    $storage = Assert-NetCrateLocalPath $StorageRoot
    $repositoryRoot = [IO.Path]::Combine($storage, 'NetCrate-' + $owner.InstallationId)
    $bindingPath = [IO.Path]::Combine($Root, 'repositories.json')
    $secretsPath = [IO.Path]::Combine($Root, 'Secrets', 'repositories.json')
    if ([IO.File]::Exists($secretsPath)) {
        $secrets = Get-NetCrateRepositorySecrets $Root
        if (-not $secrets.StorageRoot.Equals($storage, [StringComparison]::OrdinalIgnoreCase)) { throw 'This installation already uses another backup folder. Its repositories were preserved.' }
    } else {
        if ([IO.Directory]::Exists($repositoryRoot)) { throw 'The backup folder already contains a NetCrate repository. It was not initialized again.' }
        $secrets = [pscustomobject]@{ StorageRoot = $storage
            PrimaryPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
            ResultsPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
            TransportPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) }
        Protect-NetCrateRecord $Root 'repositories' $secrets
    }
    $null = Set-NetCratePrivateDirectory $repositoryRoot
    $storageOwner = [IO.Path]::Combine($repositoryRoot, 'netcrate-owner.json')
    if ([IO.File]::Exists($storageOwner)) {
        if ((Read-NetCrateJson $storageOwner).InstallationId -cne $owner.InstallationId) { throw 'The backup folder belongs to another installation.' }
    } else {
        if ([IO.Directory]::EnumerateFileSystemEntries($repositoryRoot).GetEnumerator().MoveNext()) { throw 'The backup folder contains unidentified files. Its contents were preserved.' }
        Write-NetCrateJson $storageOwner @{ Version = 1; InstallationId = $owner.InstallationId }
    }
    $binding = [ordered]@{ Version = 1; InstallationId = $owner.InstallationId; StorageRoot = $storage; RepositoryRoot = $repositoryRoot }
    foreach ($name in @('Primary', 'Results')) {
        $leaf = if ($name -eq 'Primary') { 'originals' } else { 'results' }
        $path = [IO.Path]::Combine($repositoryRoot, 'editing', $leaf)
        $null = Assert-NetCrateLocalPath $path
        $password = $secrets.($name + 'Password')
        if (-not [IO.File]::Exists([IO.Path]::Combine($path, 'config'))) {
            if ([IO.Directory]::Exists($path) -and [IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator().MoveNext()) { throw 'An existing repository folder cannot be initialized.' }
            $init = Invoke-NetCrateProcess $ResticExe @('--repo', $path, '--no-cache', 'init') @{ RESTIC_PASSWORD = $password }
            if ($init.ExitCode -ne 0) { throw 'The backup repository could not be created. Existing data was preserved.' }
        }
        $config = Invoke-NetCrateProcess $ResticExe @('--repo', $path, '--no-cache', '--no-lock', 'cat', 'config') @{ RESTIC_PASSWORD = $password }
        if ($config.ExitCode -ne 0) { throw 'The existing repository could not be unlocked with this installation key.' }
        $record = $config.Output | ConvertFrom-Json
        if ($record.id -cnotmatch '^[a-f0-9]{64}$') { throw 'The repository identity is invalid.' }
        $binding[$name + 'Path'] = $path
        $binding[$name + 'Id'] = $record.id
    }
    if ([IO.File]::Exists($bindingPath)) {
        $previous = Read-NetCrateJson $bindingPath
        if ($previous.PrimaryId -cne $binding.PrimaryId -or $previous.ResultsId -cne $binding.ResultsId) { throw 'A repository identity changed. Existing bindings were preserved.' }
    }
    Write-NetCrateJson $bindingPath $binding
    return [pscustomobject]$binding
}

function Get-NetCrateRecoveryDocument {
    param([Parameter(Mandatory)][string]$Root)
    $owner = Get-NetCrateOwner $Root
    if ($owner.Role -cne 'Worker') { throw 'Export recovery details on the Backup Server.' }
    $binding = Read-NetCrateJson ([IO.Path]::Combine($Root, 'repositories.json'))
    $secrets = Get-NetCrateRepositorySecrets $Root
    if ($binding.InstallationId -cne $owner.InstallationId -or $binding.PrimaryId -cnotmatch '^[a-f0-9]{64}$' -or $binding.ResultsId -cnotmatch '^[a-f0-9]{64}$' -or
        $binding.PrimaryId -ceq $binding.ResultsId -or -not $secrets.PrimaryPassword -or -not $secrets.ResultsPassword) { throw 'The recovery keys do not match this Backup Server.' }
    $recovery = [ordered]@{ Version = 1; Kind = 'netcrate-recovery'; InstallationId = $owner.InstallationId; CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Primary = @{ Id = $binding.PrimaryId; Path = $binding.PrimaryPath; Password = $secrets.PrimaryPassword }
        Results = @{ Id = $binding.ResultsId; Path = $binding.ResultsPath; Password = $secrets.ResultsPassword }
        Instructions = 'Keep a separate accessible copy outside this computer. These details unlock your backups. Restore using Restic and the repository password even if NetCrate or the original Windows account is unavailable.' }
    return ($recovery | ConvertTo-Json -Depth 8)
}

function Export-NetCrateRecovery {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$LiteralPath)
    $document = Get-NetCrateRecoveryDocument $Root
    $owner = Get-NetCrateOwner $Root
    $binding = Read-NetCrateJson ([IO.Path]::Combine($Root, 'repositories.json'))
    $path = Assert-NetCrateLocalPath $LiteralPath
    foreach ($forbidden in @($owner.Root, $binding.StorageRoot, [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))) {
        $other = $forbidden.TrimEnd('\')
        if ($path.Equals($other, [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($other + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $other.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Save recovery details outside NetCrate and the selected backup folder.' }
    }
    foreach ($cloud in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($cloud -and ($path.Equals($cloud.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($cloud.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'Choose an ordinary local folder outside OneDrive.' }
    }
    $part = [IO.Path]::GetDirectoryName($path)
    if (-not [IO.Directory]::Exists($part)) { throw 'Choose an existing ordinary local folder for recovery details.' }
    while ($part) {
        if (([IO.File]::GetAttributes($part) -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) -ne 0) { throw 'Choose a fully available ordinary local folder without links.' }
        $part = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
    }
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) { throw 'That destination already exists. Choose a new recovery filename; the existing file was preserved.' }
    $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
        }
    $stream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($path), [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $acl)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($document)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    } finally { $stream.Dispose() }
    Write-NetCrateJson ([IO.Path]::Combine($Root, 'recovery-export.json')) @{ Version = 1; ExportedUtc = [DateTime]::UtcNow.ToString('o'); PrimaryId = $binding.PrimaryId; ResultsId = $binding.ResultsId }
}

Export-ModuleMember -Function Initialize-NetCrateRepositories, Get-NetCrateRepositorySecrets, Get-NetCrateRecoveryDocument, Export-NetCrateRecovery
