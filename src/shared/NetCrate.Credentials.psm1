#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Configuration.psm1')

function Set-NetCratePrivateDirectory {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $path = Assert-NetCrateLocalPath $LiteralPath
    $null = [IO.Directory]::CreateDirectory($path)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($owner, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($path), $acl)
    return $path
}

function Get-NetCrateOwner {
    param([Parameter(Mandatory)][string]$Root)
    $path = Assert-NetCrateLocalPath $Root
    $owner = Read-NetCrateJson ([IO.Path]::Combine($path, 'owner.json')) -MaximumBytes 16384
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($owner.Version -ne 1 -or $owner.InstallationId -cnotmatch '^[a-f0-9]{32}$' -or $owner.Role -cnotin @('Source', 'Worker') -or
        $owner.UserSid -cne $sid -or -not $owner.Root.Equals($path, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Open NetCrate using the Windows account that completed setup.'
    }
    return $owner
}

function Assert-NetCratePrivateRecord {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($LiteralPath))
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($ruleSid -notin @($sid, 'S-1-5-18')) { throw 'The NetCrate credential file has broader Windows access than expected.' }
    }
}

function Get-NetCrateEntropy {
    param($Owner, [string]$Name)
    $text = 'NetCrate|1|' + $Owner.InstallationId + '|' + $Owner.UserSid + '|' + $Owner.Root.ToUpperInvariant() + '|' + $Name
    return ,([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}

function Protect-NetCrateRecord {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,40}$')][string]$Name, [Parameter(Mandatory)]$Value)
    $owner = Get-NetCrateOwner $Root
    $directory = Set-NetCratePrivateDirectory ([IO.Path]::Combine($owner.Root, 'Secrets'))
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 32 -Compress))
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, (Get-NetCrateEntropy $owner $Name), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        Write-NetCrateJson ([IO.Path]::Combine($directory, $Name + '.json')) ([ordered]@{
            Version = 1; Scope = 'CurrentUser'; InstallationId = $owner.InstallationId; UserSid = $owner.UserSid
            Name = $Name; ProtectedData = [Convert]::ToBase64String($protected)
        })
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-NetCrateRecord {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,40}$')][string]$Name)
    $owner = Get-NetCrateOwner $Root
    $path = [IO.Path]::Combine($owner.Root, 'Secrets', $Name + '.json')
    Assert-NetCratePrivateRecord $path
    $record = Read-NetCrateJson $path -MaximumBytes 262144
    if ($record.Version -ne 1 -or $record.Scope -cne 'CurrentUser' -or $record.InstallationId -cne $owner.InstallationId -or
        $record.UserSid -cne $owner.UserSid -or $record.Name -cne $Name) { throw 'The protected record does not belong to this NetCrate installation.' }
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($record.ProtectedData),
        (Get-NetCrateEntropy $owner $Name), [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function New-NetCrateIdentity {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$InstallationId,
        [Parameter(Mandatory)][ValidateSet('Source', 'Worker')][string]$Role)
    $path = Assert-NetCrateLocalPath $Root
    $ownerPath = [IO.Path]::Combine($path, 'owner.json')
    if ([IO.File]::Exists($ownerPath)) {
        $owner = Get-NetCrateOwner $path
        if ($owner.InstallationId -cne $InstallationId -or $owner.Role -cne $Role) { throw 'This folder belongs to another NetCrate installation.' }
    } else {
        if ([IO.Directory]::Exists($path) -and [IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator().MoveNext()) {
            throw 'Choose an empty NetCrate application folder. Existing files were preserved.'
        }
        $null = Set-NetCratePrivateDirectory $path
        Write-NetCrateJson $ownerPath ([ordered]@{ Version = 1; InstallationId = $InstallationId; Role = $Role
            UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Root = $path })
    }
    $keyPath = [IO.Path]::Combine($path, 'Secrets', 'identity-key.json')
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    try {
        if ([IO.File]::Exists($keyPath)) {
            $key = Unprotect-NetCrateRecord $path 'identity-key'
            $rsa.ImportFromPem($key.PrivateKey)
        } else { Protect-NetCrateRecord $path 'identity-key' @{ PrivateKey = $rsa.ExportPkcs8PrivateKeyPem() } }
        return [pscustomobject]@{ InstallationId = $InstallationId; Role = $Role; PublicKey = $rsa.ExportSubjectPublicKeyInfoPem() }
    } finally { $rsa.Dispose() }
}

Export-ModuleMember -Function Set-NetCratePrivateDirectory, Get-NetCrateOwner, Protect-NetCrateRecord, Unprotect-NetCrateRecord, New-NetCrateIdentity
