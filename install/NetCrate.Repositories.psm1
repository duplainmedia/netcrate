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

function Export-NetCrateRecovery {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$LiteralPath)
    $owner = Get-NetCrateOwner $Root
    $binding = Read-NetCrateJson ([IO.Path]::Combine($Root, 'repositories.json'))
    $secrets = Get-NetCrateRepositorySecrets $Root
    $path = Assert-NetCrateLocalPath $LiteralPath
    foreach ($forbidden in @($owner.Root, $binding.StorageRoot)) {
        if ($path.StartsWith($forbidden.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Save recovery details outside NetCrate and the backup drive folder.' }
    }
    $recovery = [ordered]@{ Version = 1; Kind = 'netcrate-recovery'; InstallationId = $owner.InstallationId; CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Primary = @{ Id = $binding.PrimaryId; Path = $binding.PrimaryPath; Password = $secrets.PrimaryPassword }
        Results = @{ Id = $binding.ResultsId; Path = $binding.ResultsPath; Password = $secrets.ResultsPassword }
        Instructions = 'Keep this file on another computer or removable drive. It unlocks your backups. Restore using Restic and the repository password even if NetCrate or the original Windows account is unavailable.' }
    $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
        }
    $stream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($path), [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $acl)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($recovery | ConvertTo-Json -Depth 8))
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    } finally { $stream.Dispose() }
    Write-NetCrateJson ([IO.Path]::Combine($Root, 'recovery-export.json')) @{ Version = 1; ExportedUtc = [DateTime]::UtcNow.ToString('o'); PrimaryId = $binding.PrimaryId; ResultsId = $binding.ResultsId }
}

Export-ModuleMember -Function Initialize-NetCrateRepositories, Get-NetCrateRepositorySecrets, Export-NetCrateRecovery
