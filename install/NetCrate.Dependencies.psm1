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

function Get-NetCratePackageArchive {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$CacheRoot)
    $root = Assert-NetCrateLocalPath $CacheRoot
    $url = [uri]$Package.Url
    if ($Package.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $url.Scheme -cne 'https' -or $url.UserInfo -or
        $url.Host -cnotin @('github.com', 'www.python.org', 'files.pythonhosted.org')) { throw 'The software download entry is invalid.' }
    $null = [IO.Directory]::CreateDirectory($root)
    $path = [IO.Path]::Combine($root, $Package.SHA256 + '.package')
    if ([IO.File]::Exists($path)) {
        if ((Get-FileHash -LiteralPath $path).Hash -ieq $Package.SHA256) { return $path }
        [IO.File]::Move($path, $path + '.rejected-' + [guid]::NewGuid().ToString('N'))
    }
    $temporary = [IO.Path]::Combine($root, [guid]::NewGuid().ToString('N') + '.download')
    $client = [Net.WebClient]::new()
    try {
        $client.DownloadFile($url, $temporary)
        if ((Get-FileHash -LiteralPath $temporary).Hash -ine $Package.SHA256) { throw 'The software download could not be verified. Try again.' }
        [IO.File]::Move($temporary, $path)
        return $path
    } finally {
        $client.Dispose()
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Expand-NetCrateDependency {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$ToolsRoot)
    $root = Assert-NetCrateLocalPath $ToolsRoot
    if ($Package.Name -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,30}$' -or $Package.Version -cnotmatch '^[0-9]+(\.[0-9]+){1,3}$' -or
        $Package.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Archive).Hash -ine $Package.SHA256) {
        throw 'The software archive failed its identity check.'
    }
    $null = Assert-NetCrateRelativePath $Package.Executable
    $destination = [IO.Path]::Combine($root, $Package.Name, $Package.Version)
    $stampPath = [IO.Path]::Combine($destination, '.netcrate-package.json')
    if ([IO.Directory]::Exists($destination)) {
        $stamp = Read-NetCrateJson $stampPath -MaximumBytes 1048576
        if ($stamp.Version -ne 1 -or $stamp.Name -cne $Package.Name -or $stamp.PackageVersion -cne $Package.Version -or
            $stamp.ArchiveSHA256 -cne $Package.SHA256) { throw 'An existing software folder has a different identity. Its files were preserved.' }
        $damaged = $false
        foreach ($file in $stamp.Files) {
            $null = Assert-NetCrateRelativePath $file.Path
            $path = [IO.Path]::Combine($destination, $file.Path.Replace('/', '\'))
            $null = Assert-NetCrateLocalPath $path
            if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path).Hash -ine $file.SHA256) { $damaged = $true }
        }
        if (-not $damaged) { return $destination }
        $preserved = $destination + '.damaged-' + [guid]::NewGuid().ToString('N')
        $null = Assert-NetCrateLocalPath $preserved
        if (-not $preserved.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The repair destination is outside the owned tools folder.' }
        [IO.Directory]::Move($destination, $preserved)
    }
    $null = [IO.Directory]::CreateDirectory($root)
    $stage = [IO.Path]::Combine($root, '.stage-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($stage)
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
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
            $total += $entry.Length
            if ($total -gt 2GB) { throw 'The software archive is larger than expected.' }
            if ($entry.FullName.EndsWith('/')) { $null = [IO.Directory]::CreateDirectory($target); continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            $files.Add([pscustomobject]@{ Path = $relative; SHA256 = (Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() })
        }
    } finally { $zip.Dispose() }
    if (-not [IO.File]::Exists([IO.Path]::Combine($stage, $Package.Executable.Replace('/', '\')))) { throw 'The expected software file is missing from the archive.' }
    Write-NetCrateJson ([IO.Path]::Combine($stage, '.netcrate-package.json')) ([ordered]@{
        Version = 1; Name = $Package.Name; PackageVersion = $Package.Version; ArchiveSHA256 = $Package.SHA256; Files = @($files.ToArray())
    })
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.Directory]::Move($stage, $destination)
    return $destination
}

function Install-NetCrateTools {
    param([Parameter(Mandatory)][ValidateSet('Source', 'Worker')][string]$Role, [Parameter(Mandatory)][string]$Root,
        [ValidateSet('Folder','Media')][string]$BackupMode = 'Media')
    $catalog = Get-NetCrateDependencyCatalog
    $tools = [ordered]@{}
    foreach ($package in $catalog.Packages) {
        if ($Role -cnotin $package.Roles) { continue }
        if ($BackupMode -ceq 'Folder' -and $package.Name -cin @('FFmpeg','Pillow')) { continue }
        $archive = Get-NetCratePackageArchive $package ([IO.Path]::Combine($Root, 'Downloads'))
        $directory = Expand-NetCrateDependency $archive $package ([IO.Path]::Combine($Root, 'Tools'))
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

Export-ModuleMember -Function Get-NetCrateDependencyCatalog, Get-NetCratePackageArchive, Expand-NetCrateDependency, Install-NetCrateTools

function Install-NetCrateRecoveryTools {
    param([Parameter(Mandatory)][string]$Root, [ValidateSet('PowerShell','Restic')][string[]]$Names=@('PowerShell','Restic'))
    $tools=[ordered]@{}
    foreach($package in (Get-NetCrateDependencyCatalog).Packages) {
        if($package.Name -cnotin $Names){continue}
        $archive=Get-NetCratePackageArchive $package ([IO.Path]::Combine($Root,'Downloads'))
        $directory=Expand-NetCrateDependency $archive $package ([IO.Path]::Combine($Root,'Tools'))
        $tools[$package.Name]=[IO.Path]::Combine($directory,$package.Executable.Replace('/','\'))
    }
    return [pscustomobject]$tools
}
Export-ModuleMember -Function Install-NetCrateRecoveryTools
