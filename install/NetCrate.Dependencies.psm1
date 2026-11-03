#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\shared\NetCrate.Configuration.psm1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-NetCrateDependencyCatalog {
    $catalog = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dependencies.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($catalog.Version -ne 1) { throw 'The software download list is unsupported.' }
    return $catalog
}

function Send-NetCratePackageProgress {
    param($Package, [string]$Phase, [scriptblock]$Progress)
    if (-not $Progress) { return }
    # Only catalog-shaped identities and fixed phases cross the progress boundary.
    $name='Package'; $version='0.0'
    if ($Package.Name -cmatch '^[A-Za-z][A-Za-z0-9]{0,30}$') { $name=$Package.Name }
    if ($Package.Version -cmatch '^[0-9]+(\.[0-9]+){1,3}$') { $version=$Package.Version }
    $completed=0; if ($Phase -cin @('Ready','Reused')) { $completed=1 }
    try { $null=& $Progress ([pscustomobject][ordered]@{Name=$name;Version=$version;Phase=$Phase;Completed=$completed;Total=1}) *>&1 } catch { }
}

function Test-NetCrateInstalledPackage {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$Destination)
    try {
        $stamp = Read-NetCrateJson ([IO.Path]::Combine($Destination, '.netcrate-package.json')) -MaximumBytes 1048576
        if ($stamp.Version -ne 1 -or $stamp.Name -cne $Package.Name -or $stamp.PackageVersion -cne $Package.Version -or
            $stamp.ArchiveSHA256 -cne $Package.SHA256 -or @($stamp.Files).Count -eq 0 -or @($stamp.Files).Count -gt 20000) { return $false }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $stamp.Files) {
            $null = Assert-NetCrateRelativePath $file.Path
            if (-not $seen.Add($file.Path) -or $file.SHA256 -cnotmatch '^[a-f0-9]{64}$') { return $false }
            $path = ConvertTo-NetCrateFileSystemPath ([IO.Path]::Combine($Destination, $file.Path.Replace('/', '\')))
            if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path).Hash -ine $file.SHA256) { return $false }
        }
        return $seen.Contains($Package.Executable)
    } catch { return $false }
}

function Get-NetCrateBootstrapExecutable([string]$Root) {
    # Ordinary actions only need the pinned handoff executable, not a complete
    # installation/archive audit. Full package verification stays in preparation.
    try {
        $package=(Get-NetCrateDependencyCatalog).Packages | Where-Object Name -CEQ PowerShell
        $destination=[IO.Path]::Combine((Assert-NetCrateLocalPath $Root),'Tools','PowerShell',$package.Version)
        $stamp=Read-NetCrateJson ([IO.Path]::Combine($destination,'.netcrate-package.json')) -MaximumBytes 1048576
        if($stamp.Version -ne 1 -or $stamp.Name -cne 'PowerShell' -or $stamp.PackageVersion -cne $package.Version -or $stamp.ArchiveSHA256 -cne $package.SHA256){return ''}
        $entry=@($stamp.Files | Where-Object Path -CEQ $package.Executable)
        if($entry.Count -ne 1 -or $entry[0].SHA256 -cnotmatch '^[a-f0-9]{64}$'){return ''}
        $exe=Assert-NetCrateLocalPath ([IO.Path]::Combine($destination,$package.Executable))
        if([IO.File]::Exists($exe) -and (Get-FileHash -LiteralPath $exe).Hash -ieq $entry[0].SHA256){return $exe}
    } catch { }
    return ''
}

function Install-NetCratePackage {
    param($Package, [string]$Root, [scriptblock]$Progress)
    $rootPath = Assert-NetCrateLocalPath $Root
    if ($Package.Name -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,30}$' -or $Package.Version -cnotmatch '^[0-9]+(\.[0-9]+){1,3}$' -or
        $Package.SHA256 -cnotmatch '^[a-f0-9]{64}$') { throw 'The software download entry is invalid.' }
    $null = Assert-NetCrateRelativePath $Package.Executable
    $destination = [IO.Path]::Combine($rootPath, 'Tools', $Package.Name, $Package.Version)
    if (Test-NetCrateInstalledPackage $Package $destination) {
        Send-NetCratePackageProgress $Package 'Checking' $Progress
        Send-NetCratePackageProgress $Package 'Verifying' $Progress
        Send-NetCratePackageProgress $Package 'Reused' $Progress
        return $destination
    }
    # Archive readiness is an intermediate stage of installation, not package completion.
    $installObserver = $Progress
    $acquisitionProgress = { param($record) if ($record.Phase -cnotin @('Ready','Reused') -and $installObserver) { & $installObserver $record } }.GetNewClosure()
    $archive = Get-NetCratePackageArchive $Package ([IO.Path]::Combine($rootPath, 'Downloads')) -Progress $acquisitionProgress
    return Expand-NetCrateDependency $archive $Package ([IO.Path]::Combine($rootPath, 'Tools')) -Progress $Progress
}

function Get-NetCratePackageArchive {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$CacheRoot, [scriptblock]$Progress)
    Send-NetCratePackageProgress $Package 'Checking' $Progress
    try {
    $root = Assert-NetCrateLocalPath $CacheRoot
    $url = [uri]$Package.Url
    if ($Package.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $url.Scheme -cne 'https' -or $url.UserInfo -or
        $url.Host -cnotin @('github.com', 'www.python.org', 'files.pythonhosted.org')) { throw 'The software download entry is invalid.' }
    $null = [IO.Directory]::CreateDirectory((ConvertTo-NetCrateFileSystemPath $root))
    $path = [IO.Path]::Combine($root, $Package.SHA256 + '.package')
    $nativePath = ConvertTo-NetCrateFileSystemPath $path
    if ([IO.File]::Exists($nativePath)) {
        Send-NetCratePackageProgress $Package 'Verifying' $Progress
        if ((Get-FileHash -LiteralPath $nativePath).Hash -ieq $Package.SHA256) { Send-NetCratePackageProgress $Package 'Reused' $Progress; return $path }
        [IO.File]::Move($nativePath, (ConvertTo-NetCrateFileSystemPath ($path + '.rejected-' + [guid]::NewGuid().ToString('N'))))
    }
    $temporary = ConvertTo-NetCrateFileSystemPath ([IO.Path]::Combine($root, [guid]::NewGuid().ToString('N') + '.download'))
    $client = [Net.WebClient]::new()
    try {
        Send-NetCratePackageProgress $Package 'Downloading' $Progress
        $client.DownloadFile($url, $temporary)
        Send-NetCratePackageProgress $Package 'Verifying' $Progress
        if ((Get-FileHash -LiteralPath $temporary).Hash -ine $Package.SHA256) { throw 'The software download could not be verified. Try again.' }
        [IO.File]::Move($temporary, $nativePath)
        Send-NetCratePackageProgress $Package 'Ready' $Progress
        return $path
    } finally {
        $client.Dispose()
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    } catch { Send-NetCratePackageProgress $Package 'Failed' $Progress; throw }
}

function Expand-NetCrateDependency {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$ToolsRoot, [scriptblock]$Progress)
    Send-NetCratePackageProgress $Package 'Checking' $Progress
    try {
    $root = Assert-NetCrateLocalPath $ToolsRoot
    $nativeArchive = ConvertTo-NetCrateFileSystemPath $Archive
    Send-NetCratePackageProgress $Package 'Verifying' $Progress
    if ($Package.Name -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,30}$' -or $Package.Version -cnotmatch '^[0-9]+(\.[0-9]+){1,3}$' -or
        $Package.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $nativeArchive).Hash -ine $Package.SHA256) {
        throw 'The software archive failed its identity check.'
    }
    $null = Assert-NetCrateRelativePath $Package.Executable
    $destination = [IO.Path]::Combine($root, $Package.Name, $Package.Version)
    $nativeDestination = ConvertTo-NetCrateFileSystemPath $destination
    $stampPath = [IO.Path]::Combine($destination, '.netcrate-package.json')
    if ([IO.Directory]::Exists($nativeDestination)) {
        $stamp = Read-NetCrateJson $stampPath -MaximumBytes 1048576
        if ($stamp.Version -ne 1 -or $stamp.Name -cne $Package.Name -or $stamp.PackageVersion -cne $Package.Version -or
            $stamp.ArchiveSHA256 -cne $Package.SHA256) { throw 'An existing software folder has a different identity. Its files were preserved.' }
        if (Test-NetCrateInstalledPackage $Package $destination) { Send-NetCratePackageProgress $Package 'Reused' $Progress; return $destination }
        $preserved = $destination + '.damaged-' + [guid]::NewGuid().ToString('N')
        $null = Assert-NetCrateLocalPath $preserved
        if (-not $preserved.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The repair destination is outside the owned tools folder.' }
        [IO.Directory]::Move($nativeDestination, (ConvertTo-NetCrateFileSystemPath $preserved))
    }
    $null = [IO.Directory]::CreateDirectory((ConvertTo-NetCrateFileSystemPath $root))
    Send-NetCratePackageProgress $Package 'Extracting' $Progress
    $stage = [IO.Path]::Combine($root, '.stage-' + [guid]::NewGuid().ToString('N'))
    $nativeStage = ConvertTo-NetCrateFileSystemPath $stage
    $null = [IO.Directory]::CreateDirectory($nativeStage)
    $zip = [IO.Compression.ZipFile]::OpenRead($nativeArchive)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [Collections.Generic.List[object]]::new()
    $total = [long]0
    try {
        if ($zip.Entries.Count -gt 20000) { throw 'The software archive has too many files.' }
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Replace('\', '/').TrimEnd('/')
            if (-not $relative) { continue }
            $null = Assert-NetCrateRelativePath $relative
            if (-not $seen.Add($relative) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'The software archive contains colliding names or links.'
            }
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($stage, $relative.Replace('/', '\')))
            if (-not $target.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The software archive path is outside its installation folder.' }
            $nativeTarget = ConvertTo-NetCrateFileSystemPath $target
            $total += $entry.Length
            if ($total -gt 2GB) { throw 'The software archive is larger than expected.' }
            if ($entry.FullName.EndsWith('/')) { $null = [IO.Directory]::CreateDirectory($nativeTarget); continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($nativeTarget))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $nativeTarget, $false)
            $files.Add([pscustomobject]@{ Path = $relative; SHA256 = (Get-FileHash -LiteralPath $nativeTarget).Hash.ToLowerInvariant() })
        }
    } finally { $zip.Dispose() }
    if (-not [IO.File]::Exists((ConvertTo-NetCrateFileSystemPath ([IO.Path]::Combine($stage, $Package.Executable.Replace('/', '\')))))) { throw 'The expected software file is missing from the archive.' }
    Write-NetCrateJson ([IO.Path]::Combine($stage, '.netcrate-package.json')) ([ordered]@{
        Version = 1; Name = $Package.Name; PackageVersion = $Package.Version; ArchiveSHA256 = $Package.SHA256; Files = @($files.ToArray())
    })
    $null = [IO.Directory]::CreateDirectory((ConvertTo-NetCrateFileSystemPath ([IO.Path]::GetDirectoryName($destination))))
    [IO.Directory]::Move($nativeStage, $nativeDestination)
    Send-NetCratePackageProgress $Package 'Ready' $Progress
    return $destination
    } catch { Send-NetCratePackageProgress $Package 'Failed' $Progress; throw }
}

function Install-NetCrateTools {
    param([Parameter(Mandatory)][ValidateSet('Source', 'Worker')][string]$Role, [Parameter(Mandatory)][string]$Root,
        [ValidateSet('Folder','Media')][string]$BackupMode = 'Media', [scriptblock]$Progress)
    $catalog = Get-NetCrateDependencyCatalog
    $tools = [ordered]@{}
    foreach ($package in $catalog.Packages) {
        if ($Role -cnotin $package.Roles) { continue }
        if ($BackupMode -ceq 'Folder' -and $package.Name -cin @('FFmpeg','Pillow')) { continue }
        $directory = Install-NetCratePackage $package $Root -Progress $Progress
        $tools[$package.Name] = [IO.Path]::Combine($directory, $package.Executable.Replace('/', '\'))
        if ($package.Name -in @('Pillow', 'Bcrypt')) { $tools[$package.Name] = $directory }
    }
    if ($Role -eq 'Worker') {
        if ($BackupMode -ceq 'Media') { $tools.FFprobe = [IO.Path]::Combine([IO.Path]::GetDirectoryName($tools.FFmpeg), 'ffprobe.exe') }
        $site = [IO.Path]::Combine([IO.Path]::GetDirectoryName($tools.Python), 'Lib', 'site-packages')
        $null = [IO.Directory]::CreateDirectory($site)
        $libraries = @($tools.Bcrypt)
        if ($BackupMode -ceq 'Media') { $libraries = @($tools.Pillow) + $libraries }
        [IO.File]::WriteAllLines([IO.Path]::Combine($site, 'netcrate.pth'), [string[]]$libraries, [Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]$tools
}

Export-ModuleMember -Function Get-NetCrateDependencyCatalog, Get-NetCratePackageArchive, Expand-NetCrateDependency, Install-NetCrateTools, Test-NetCrateInstalledPackage

function Install-NetCrateRecoveryTools {
    param([Parameter(Mandatory)][string]$Root, [ValidateSet('PowerShell','Restic')][string[]]$Names=@('PowerShell','Restic'), [scriptblock]$Progress)
    $tools=[ordered]@{}
    foreach($package in (Get-NetCrateDependencyCatalog).Packages) {
        if($package.Name -cnotin $Names){continue}
        $directory=Install-NetCratePackage $package $Root -Progress $Progress
        $tools[$package.Name]=[IO.Path]::Combine($directory,$package.Executable.Replace('/','\'))
    }
    return [pscustomobject]$tools
}
Export-ModuleMember -Function Install-NetCrateRecoveryTools
Export-ModuleMember -Function Get-NetCrateBootstrapExecutable
