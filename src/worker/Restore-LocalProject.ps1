#requires -Version 7.0
# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
<#
.SYNOPSIS
Lists backed-up roots or restores one selected snapshot path into a new folder.
.EXAMPLE
.\Restore-LocalProject.ps1 -Action List
.EXAMPLE
.\Restore-LocalProject.ps1 -Action Restore -Snapshot 01234567 -ProjectPath '/D/Projects/sample-project' -Destination 'C:\Restores\sample-project'
#>
[CmdletBinding()]
param(
    [ValidateSet('List','Restore')][string]$Action = 'List',
    [string]$Snapshot,
    [string]$ProjectPath,
    [string]$Destination
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.Name -ine 'WORKER-PC\worker-user') { throw 'Run as WORKER-PC\worker-user.' }
$credentialRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OfficeBackupRestore'
$credentialPath = Join-Path $credentialRoot 'repository.dpapi.json'
$restic = 'C:\Program Files\NetCrate\Backup\restic.exe'
$repository = 'E:\NetCrate\Repositories\sample-user\source-pc'
$secure = $null

function Assert-PlainAncestors([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not allowed in this path.' }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
    }
}
function Test-Within([string]$Path, [string]$Parent) {
    return ($Path.TrimEnd('\') + '\').StartsWith(($Parent.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
}
function Assert-NewDestination([string]$Path) {
    if (!$Path -or $Path -notmatch '^[A-Za-z]:\\' -or $Path.IndexOf(':', 2) -ge 0) { throw 'Destination must be an absolute local drive path.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (Test-Path -LiteralPath $full) { throw 'Destination already exists; refusing to overwrite.' }
    if ((Test-Within $full $repository) -or (Test-Within $repository $full)) { throw 'Destination overlaps the repository.' }
    Assert-PlainAncestors $full
    $parent = [IO.Path]::GetDirectoryName($full)
    if (!(Test-Path -LiteralPath $parent -PathType Container)) { throw 'Create the destination parent folder first.' }
    return $full
}
function Invoke-ResticRead([string[]]$Arguments) {
    if ($Arguments[0] -notin @('snapshots','ls','restore')) { throw 'Only read-only restore operations are allowed.' }
    $psi = [Diagnostics.ProcessStartInfo]::new($restic)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    # Do not inherit password-file, password-command, repository, backend or filter overrides.
    foreach ($name in @($psi.Environment.Keys)) {
        if ($name -like 'RESTIC_*') { $null = $psi.Environment.Remove($name) }
    }
    foreach ($arg in @('--repo',$repository,'--no-lock','--no-cache','--json') + $Arguments) { $psi.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        $psi.Environment['RESTIC_PASSWORD'] = [Net.NetworkCredential]::new('', $secure).Password
        $null = $process.Start()
        $null = $psi.Environment.Remove('RESTIC_PASSWORD')
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result = $stdout.GetAwaiter().GetResult()
        $diagnostic = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Restic $($Arguments[0]) failed (exit $($process.ExitCode)); no unverified restore is marked complete." }
        return $result
    } finally {
        $null = $psi.Environment.Remove('RESTIC_PASSWORD')
        $psi.Environment.Clear()
        $process.Dispose()
        $diagnostic = $null
    }
}
function Read-Nodes([string]$Id, [string]$Path) {
    $text = Invoke-ResticRead @('ls','--recursive',$Id,$Path)
    return @($text -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.message_type -eq 'node' })
}
try {
    # Destination validation happens before loading any secret or launching Restic.
    if ($Action -eq 'Restore') { $Destination = Assert-NewDestination $Destination }
    Assert-PlainAncestors $credentialPath
    Assert-PlainAncestors $repository
    foreach ($path in @($credentialRoot,$credentialPath)) {
        $acl = Get-Acl -LiteralPath $path
        foreach ($rule in $acl.Access) {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($rule.AccessControlType -eq 'Allow' -and $sid -notin @($identity.User.Value,([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null).Value))) { throw 'Credential ACL permits an unexpected identity.' }
        }
    }
    $record = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json
    if ($record.Version -ne 1 -or $record.ProtectedForUserSid -ne $identity.User.Value -or $record.Repository -ine $repository) { throw 'Credential identity or repository mismatch.' }
    if ((Get-FileHash -LiteralPath (Join-Path $repository 'config') -Algorithm SHA256).Hash -ne $record.RepositoryConfigSHA256) { throw 'Repository fingerprint changed; refusing access.' }
    try { $secure = ConvertTo-SecureString -String $record.PasswordDpapi } catch { throw 'DPAPI unlock failed. Use the original WORKER-PC\worker-user Windows profile.' }
    $record = $null
    $snapshots = @(ConvertFrom-Json -InputObject (Invoke-ResticRead @('snapshots')))
    if ($Action -eq 'List') {
        foreach ($snap in $snapshots) {
            foreach ($path in $snap.paths) {
                $normalized = $path.Replace('\','/')
                if ($normalized -match '^([A-Za-z]):/(.*)$') { $normalized = '/' + $Matches[1] + '/' + $Matches[2] }
                [pscustomobject]@{ Project = ($normalized.TrimEnd('/') -split '/')[-1]; Snapshot = $snap.id; Time = $snap.time; ProjectPath = $normalized; Host = $snap.hostname; SnapshotBytes = $snap.summary.total_bytes_processed }
            }
        }
        return
    }
    if ($Snapshot -notmatch '^[a-fA-F0-9]{8,64}$') { throw 'Select a snapshot ID from List (at least 8 hex characters).' }
    $selected = @($snapshots | Where-Object { $_.id.StartsWith($Snapshot, [StringComparison]::OrdinalIgnoreCase) })
    if ($selected.Count -ne 1) { throw 'Snapshot ID is missing or ambiguous.' }
    $id = $selected[0].id
    if ($ProjectPath -notmatch '^/[^:*?\[\]\\]+$' -or $ProjectPath -match '(^|/)\.\.?(/|$)' -or $ProjectPath.EndsWith('/')) { throw 'Select an exact absolute snapshot directory path, without wildcards or traversal.' }
    $nodes = @(Read-Nodes $id $ProjectPath)
    $roots = @($nodes | Where-Object { $_.path -ceq $ProjectPath -and $_.type -eq 'dir' })
    if ($roots.Count -ne 1) { throw 'Selected project directory does not exist in the snapshot.' }
    $files = @($nodes | Where-Object { $_.type -eq 'file' -and $_.path.StartsWith($ProjectPath + '/', [StringComparison]::Ordinal) })
    if (@($nodes | Where-Object { $_.type -notin @('file','dir') }).Count) { throw 'Selected project contains unsupported links or special files.' }
    $bytes = [long]0
    $expected = [Collections.Generic.Dictionary[string,long]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $relative = $file.path.Substring($ProjectPath.Length + 1).Replace('/','\')
        if ($relative -match '(^|\\)\.\.?($|\\)|:|[. ]($|\\)' -or $expected.ContainsKey($relative)) { throw 'Unsafe or colliding Windows snapshot path.' }
        $expected.Add($relative,[long]$file.size); $bytes += [long]$file.size
    }
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Destination)).AvailableFreeSpace -lt ($bytes + 1GB)) { throw 'Insufficient free space (project size plus 1 GiB reserve required).' }
    $report = $Destination + '.verification'
    $null = Assert-NewDestination $report
    # New-Item without Force fails if either path already exists, including on a retry.
    $null = New-Item -ItemType Directory -Path $report
    $null = New-Item -ItemType Directory -Path $Destination
    Write-Host "Restoring $($files.Count) files ($bytes bytes) to $Destination. Content verification may take time."
    $null = Invoke-ResticRead @('restore',($id + ':' + $ProjectPath),'--target',$Destination,'--verify','--overwrite','never')
    $actual = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Force)
    if ($actual.Count -ne $expected.Count) { throw 'Restored file count mismatch.' }
    $manifest = foreach ($file in $actual) {
        $relative = [IO.Path]::GetRelativePath($Destination,$file.FullName)
        if (!$expected.ContainsKey($relative) -or $file.Length -ne $expected[$relative]) { throw 'Restored path or size mismatch.' }
        [pscustomobject]@{ RelativePath=$relative; Bytes=$file.Length; SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    $manifest | Export-Csv -LiteralPath (Join-Path $report 'sha256.csv') -NoTypeInformation
    [ordered]@{ SnapshotId=$id; ProjectPath=$ProjectPath; Destination=$Destination; Files=$actual.Count; Bytes=$bytes; ResticContentVerification=$true; VerifiedUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $report 'verified.json')
    Write-Output "Verified restore complete: $Destination"
    Write-Output "Receipt and SHA-256 manifest: $report"
} finally {
    if ($null -ne $secure) { $secure.Dispose() }
    $record = $null
    # No credential is ever placed in this PowerShell process's environment.
}
