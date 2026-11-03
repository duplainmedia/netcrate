Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NetCrateJsonMembers {
    param($Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw 'A NetCrate record contains duplicate or case-colliding fields.' }
            Assert-NetCrateJsonMembers $property.Value
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-NetCrateJsonMembers $item }
    }
}

function Assert-NetCrateLocalPath {
    param([Parameter(Mandatory)][string]$LiteralPath, [switch]$AllowDriveRoot)
    if ($LiteralPath -cnotmatch '^[A-Za-z]:[\\/]' -or $LiteralPath -match '(^|[\\/])\.{1,2}([\\/]|$)' -or
        $LiteralPath.Substring(3) -match '[:*?"<>|\x00-\x1f]' -or $LiteralPath -match '[. ]([\\/]|$)') {
        throw 'Choose an ordinary local folder.'
    }
    $full = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
    if (-not $AllowDriveRoot -and $full.Length -lt 4) { throw 'Choose a folder inside the drive.' }
    $part = $full
    while ($part) {
        if (([IO.File]::Exists($part) -or [IO.Directory]::Exists($part)) -and
            ([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked paths are not supported.' }
        $part = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
    }
    return $full
}

function Read-NetCrateJson {
    param([Parameter(Mandatory)][string]$LiteralPath, [long]$MaximumBytes = 1048576)
    $null = Assert-NetCrateLocalPath $LiteralPath
    $file = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt $MaximumBytes) { throw 'The NetCrate record is invalid or too large.' }
    $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    if ('System.Text.Json.JsonDocument' -as [type]) {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 32
        $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
        try { Assert-NetCrateJsonMembers $document.RootElement }
        finally { $document.Dispose() }
    }
    return $text | ConvertFrom-Json
}

function Write-NetCrateJson {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)]$Value)
    $path = Assert-NetCrateLocalPath $LiteralPath
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.writing'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 32), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-NetCrateSnapshotRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root = Assert-NetCrateLocalPath $ProjectRoot
    return '/' + $root.Substring(0, 1).ToUpperInvariant() + $root.Substring(2).Replace('\', '/')
}

function Assert-NetCrateRelativePath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('/') -or $Path -match '[\\:*?"<>|\x00-\x1f]|(^|/)\.{1,2}(/|$)|[. ](/|$)|//') {
        throw 'The media path is unsafe.'
    }
    foreach ($part in $Path.Split('/')) {
        if ($part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)' -or $part.Length -gt 255) { throw 'The media filename is not supported.' }
    }
    return $Path
}

function Get-NetCrateProjectPath {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$SnapshotPath)
    $prefix = $Settings.SnapshotRoot.TrimEnd('/') + '/'
    if (-not $SnapshotPath.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'The project is outside the configured project folder.' }
    $name = $SnapshotPath.Substring($prefix.Length)
    $null = Assert-NetCrateRelativePath $name
    if ($name.Contains('/')) { throw 'Choose a project directly inside your project folder.' }
    return [IO.Path]::Combine($Settings.ActiveRoot, $name)
}

function Get-NetCrateBackupMode($Record) {
    $mode = if ($Record.PSObject.Properties.Name -contains 'BackupMode') { $Record.BackupMode } elseif ($Record -is [Collections.IDictionary] -and $Record.Contains('BackupMode')) { $Record.BackupMode } else { 'Media' }
    if ($mode -cnotin @('Folder', 'Media')) { throw 'The backup mode is invalid.' }
    return $mode
}

function Get-NetCrateBackupPath {
    param($Settings, [string]$Path, [ValidateSet('Folder', 'Media')][string]$BackupMode)
    $full = Assert-NetCrateLocalPath $Path
    $root = Assert-NetCrateLocalPath $Settings.ActiveRoot
    if ($BackupMode -ceq 'Media') {
        $expected = Get-NetCrateProjectPath $Settings (Get-NetCrateSnapshotRoot $full)
        if (-not $full.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Choose a project directly inside your project folder.' }
    } elseif (-not ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Choose the configured folder or a folder inside it.'
    }
    $protected = @([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')))
    if ($Settings.PSObject.Properties.Name -contains 'StateRoot') { $protected += $Settings.StateRoot }
    if ($Settings.PSObject.Properties.Name -contains 'WorkRoot' -and $Settings.WorkRoot) { $protected += $Settings.WorkRoot }
    if ($Settings.PSObject.Properties.Name -contains 'Repositories') { foreach ($name in @('Primary', 'Results')) {
        $uri = $Settings.Repositories.$name.Uri
        if ($uri -match '^[A-Za-z]:[\\/]') { $protected += $uri }
    } }
    foreach ($other in $protected) {
        $other = [IO.Path]::GetFullPath($other).TrimEnd('\')
        if ($full.Equals($other, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($other + '\', [StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The backup folder overlaps NetCrate application or storage files.'
        }
    }
    return $full
}

function Import-NetCrateSettings {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][ValidateSet('Source', 'Worker')][string]$Role)
    $settings = Read-NetCrateJson $LiteralPath -MaximumBytes 65536
    $settings | Add-Member -NotePropertyName BackupMode -NotePropertyValue (Get-NetCrateBackupMode $settings) -Force
    if (($settings.Version -isnot [int] -and $settings.Version -isnot [long]) -or $settings.Version -ne 1 -or $settings.Role -cne $Role -or
        $settings.InstallationId -cnotmatch '^[a-f0-9]{32}$') { throw 'The NetCrate configuration does not match this computer role.' }
    foreach ($name in @('SourceComputer', 'WorkerComputer')) {
        if ($settings.$name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$') { throw 'A configured computer identity is invalid.' }
    }
    if ($settings.SourceComputer -ieq $settings.WorkerComputer) { throw 'The two computer identities must differ.' }
    $settings.ActiveRoot = Assert-NetCrateLocalPath $settings.ActiveRoot
    $settings.StateRoot = Assert-NetCrateLocalPath $settings.StateRoot
    $snapshotRoot = Get-NetCrateSnapshotRoot $settings.ActiveRoot
    if ($settings.PSObject.Properties.Name -contains 'SnapshotRoot' -and $settings.SnapshotRoot -cne $snapshotRoot) { throw 'The project and snapshot roots differ.' }
    $settings | Add-Member -NotePropertyName SnapshotRoot -NotePropertyValue $snapshotRoot -Force
    if (($settings.PollSeconds -isnot [int] -and $settings.PollSeconds -isnot [long]) -or $settings.PollSeconds -lt 2 -or $settings.PollSeconds -gt 300 -or
        $settings.Recipe -notin @('half-prores-v2', 'quarter-prores-v1')) { throw 'The polling interval or proxy recipe is invalid.' }
    foreach ($repository in @('Primary', 'Results')) {
        $binding = $settings.Repositories.$repository
        if ($binding.Id -cnotmatch '^[a-f0-9]{64}$') { throw 'A backup repository identity is missing.' }
        if ($binding.Uri.StartsWith('rest:https://', [StringComparison]::Ordinal)) {
            $uri = [uri]$binding.Uri.Substring(5)
            if ($uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.AbsolutePath.EndsWith('/')) { throw 'A repository address contains credentials or unsupported components.' }
        } elseif ($Role -eq 'Worker') {
            $null = Assert-NetCrateLocalPath $binding.Uri
        } else { throw 'The editing computer requires a private HTTPS backup endpoint.' }
    }
    if ($settings.Repositories.Primary.Uri -ceq $settings.Repositories.Results.Uri -or $settings.Repositories.Primary.Id -ceq $settings.Repositories.Results.Id) {
        throw 'Originals and generated media require separate repositories.'
    }
    $requiredTools = @('PowerShell', 'Restic')
    if ($Role -eq 'Worker') { $requiredTools += @('RestServer', 'Python'); if ($settings.BackupMode -ceq 'Media') { $requiredTools += @('FFmpeg', 'FFprobe') } }
    foreach ($name in $requiredTools) {
        if ($settings.Tools.$name -notmatch '^[A-Za-z]:[\\/]' -or $settings.Tools.$name -match '["\x00-\x1f]|(^|[\\/])\.{1,2}([\\/]|$)') { throw 'A required tool path is missing or invalid.' }
    }
    return $settings
}

Export-ModuleMember -Function Assert-NetCrateLocalPath, Assert-NetCrateRelativePath, Read-NetCrateJson, Write-NetCrateJson, Get-NetCrateSnapshotRoot, Get-NetCrateProjectPath, Get-NetCrateBackupMode, Get-NetCrateBackupPath, Import-NetCrateSettings
