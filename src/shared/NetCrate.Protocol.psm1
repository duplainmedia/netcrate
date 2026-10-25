Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Configuration.psm1')

function Get-NetCrateHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function ConvertTo-NetCrateCanonicalJson {
    param([AllowNull()][AllowEmptyCollection()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) {
        $result = [Text.StringBuilder]::new()
        $null = $result.Append('"')
        foreach ($character in $Value.ToCharArray()) {
            switch ([int]$character) {
                34 { $null = $result.Append('\"'); break }
                92 { $null = $result.Append('\\'); break }
                default {
                    if ([int]$character -lt 32) { $null = $result.Append(('\u{0:x4}' -f [int]$character)) }
                    else { $null = $result.Append($character) }
                }
            }
        }
        $null = $result.Append('"')
        return $result.ToString()
    }
    if ($Value -is [bool]) { if ($Value) { return 'true' }; return 'false' }
    if ($Value -is [DateTime]) { return ConvertTo-NetCrateCanonicalJson $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [DateTimeOffset]) { return ConvertTo-NetCrateCanonicalJson $Value.UtcDateTime.ToString('o') }
    if ($Value -is [int] -or $Value -is [long]) { return $Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [Collections.IDictionary]) {
        $pairs = foreach ($key in $Value.Keys) { (ConvertTo-NetCrateCanonicalJson ([string]$key)) + ':' + (ConvertTo-NetCrateCanonicalJson $Value[$key]) }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = foreach ($item in $Value) { ConvertTo-NetCrateCanonicalJson $item }
        return '[' + ($items -join ',') + ']'
    }
    $properties = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) { $properties[$property.Name] = $property.Value }
    return ConvertTo-NetCrateCanonicalJson $properties
}

function Get-NetCrateRecipe {
    param([ValidateSet('half-prores-v2', 'quarter-prores-v1')][string]$Name = 'half-prores-v2')
    $divisor = if ($Name -eq 'half-prores-v2') { 2 } else { 4 }
    return [pscustomobject]@{ Name = $Name; Divisor = $divisor; BitDepth = 10; PixelFormat = 'yuv422p10le'
        FingerprintRecipe = ($Name + '|ffmpeg9.0.1|scale=iw/' + $divisor + ':ih/' + $divisor + '|prores_ks:profile0:422p10|fps-passthrough|pcm24|source-metadata|12-stills:1232x1176:no-lut') }
}

function Get-NetCrateRequestId {
    param([Parameter(Mandatory)][string]$SnapshotId, [Parameter(Mandatory)][string]$ProjectPath, [Parameter(Mandatory)][string]$Recipe)
    if ($SnapshotId -cnotmatch '^[a-f0-9]{64}$') { throw 'A full successful backup snapshot is required.' }
    return Get-NetCrateHash ('request-v2|' + $SnapshotId + '|' + $ProjectPath + '|' + $Recipe)
}

function Get-NetCrateFootageIdentity {
    param([Parameter(Mandatory)][string]$ProjectPath, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Nodes, [Parameter(Mandatory)][string]$Recipe)
    $files = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $bytes = [long]0
    foreach ($node in $Nodes) {
        if ($node.type -in @('symlink', 'junction')) { throw 'Linked footage is not supported.' }
        if ($node.type -ne 'file') { continue }
        if ([IO.Path]::GetExtension($node.path).ToLowerInvariant() -notin @('.mov', '.mp4', '.mxf', '.avi', '.mts', '.m2ts', '.mkv', '.mpg', '.mpeg', '.webm')) { continue }
        if (-not $node.path.StartsWith($ProjectPath + '/', [StringComparison]::Ordinal)) { throw 'Footage is outside the selected project.' }
        $relative = $node.path.Substring($ProjectPath.Length + 1)
        $null = Assert-NetCrateRelativePath $relative
        if (-not $seen.Add($relative)) { throw 'Footage paths differ only by letter case.' }
        $content = @($node.content)
        if (($node.size -isnot [int] -and $node.size -isnot [long]) -or $node.size -lt 0 -or
            ($node.size -gt 0 -and -not $content.Count) -or @($content | Where-Object { $_ -cnotmatch '^[a-f0-9]{64}$' }).Count) {
            throw 'Footage content identities are missing or invalid.'
        }
        $entry = [ordered]@{ RelativePath = $relative; SnapshotPath = $node.path; Bytes = [long]$node.size; Content = $content }
        $files.Add($relative, $entry)
        $bytes += [long]$node.size
    }
    $values = @($files.Values | ForEach-Object { [pscustomobject]$_ })
    $canonical = ConvertTo-NetCrateCanonicalJson ([ordered]@{ Recipe = $Recipe; ProjectPath = $ProjectPath; Files = $values })
    return [pscustomobject]@{ Fingerprint = (Get-NetCrateHash $canonical); Clips = $files.Count; Bytes = $bytes; Files = $values; Recipe = $Recipe }
}

function Test-NetCrateRequest {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)]$Settings)
    $required = @('Version', 'Kind', 'SourceComputer', 'Repository', 'BackupExitCode', 'SnapshotId', 'ProjectPath', 'CompletedUtc', 'Recipe', 'FootageFingerprint')
    if (@($Request.PSObject.Properties).Count -ne $required.Count) { throw 'The backup request has unsupported fields.' }
    foreach ($name in $required) { if ($Request.PSObject.Properties.Name -cnotcontains $name) { throw 'A backup request field is missing.' } }
    $recipes = @((Get-NetCrateRecipe 'half-prores-v2').FingerprintRecipe, (Get-NetCrateRecipe 'quarter-prores-v1').FingerprintRecipe)
    $expectedUri = $Settings.Repositories.Primary.Uri
    if (($Settings.Repositories.Primary -is [Collections.IDictionary] -and $Settings.Repositories.Primary.Contains('RemoteUri')) -or
        $Settings.Repositories.Primary.PSObject.Properties.Name -contains 'RemoteUri') { $expectedUri = $Settings.Repositories.Primary.RemoteUri }
    if (($Request.Version -isnot [int] -and $Request.Version -isnot [long]) -or $Request.Version -ne 2 -or $Request.Kind -cne 'request' -or
        $Request.SourceComputer -cne $Settings.SourceComputer -or $Request.Repository -cne $expectedUri -or
        ($Request.BackupExitCode -isnot [int] -and $Request.BackupExitCode -isnot [long]) -or $Request.BackupExitCode -ne 0 -or
        $Request.SnapshotId -cnotmatch '^[a-f0-9]{64}$' -or $Request.FootageFingerprint -cnotmatch '^[a-f0-9]{64}$' -or $Request.Recipe -cnotin $recipes) {
        throw 'The request does not match a successful backup from the Editing Computer.'
    }
    $null = Get-NetCrateProjectPath -Settings $Settings -SnapshotPath $Request.ProjectPath
    $when = if ($Request.CompletedUtc -is [DateTime] -or $Request.CompletedUtc -is [DateTimeOffset]) { $Request.CompletedUtc.ToUniversalTime() }
        else { ([DateTimeOffset]::Parse([string]$Request.CompletedUtc, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
    if ($when -gt [DateTime]::UtcNow.AddMinutes(10)) { throw 'The backup completion time is in the future.' }
    if ((Get-NetCrateRequestId $Request.SnapshotId $Request.ProjectPath $Request.Recipe) -cne $RequestId) { throw 'The request identity does not match its backup and recipe.' }
    return $Request
}

function New-NetCrateAssociation {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$GenerationSnapshotId,
        [Parameter(Mandatory)][string]$ResultSnapshotId, [Parameter(Mandatory)][string]$CompletionSHA256, [Parameter(Mandatory)][string]$ResultManifestSHA256)
    $association = [pscustomobject][ordered]@{
        Version = 1; Kind = 'office-media-association'; SourceComputer = $Settings.SourceComputer; WorkerComputer = $Settings.WorkerComputer
        RequestId = (Get-NetCrateRequestId $Request.SnapshotId $Request.ProjectPath $Request.Recipe)
        RequestedSnapshotId = $Request.SnapshotId; ProjectPath = $Request.ProjectPath; GenerationSnapshotId = $GenerationSnapshotId
        JobId = ('auto-' + $Request.FootageFingerprint); FootageFingerprint = $Request.FootageFingerprint; Recipe = $Request.Recipe
        ResultSnapshotId = $ResultSnapshotId; CompletionSHA256 = $CompletionSHA256.ToLowerInvariant(); ResultManifestSHA256 = $ResultManifestSHA256.ToLowerInvariant()
        PublishedUtc = [DateTime]::UtcNow.ToString('o')
    }
    return Test-NetCrateAssociation $association $Request $Settings
}

function Test-NetCrateAssociation {
    param([Parameter(Mandatory)]$Association, [Parameter(Mandatory)]$Request, [Parameter(Mandatory)]$Settings)
    $requestId = Get-NetCrateRequestId $Request.SnapshotId $Request.ProjectPath $Request.Recipe
    $null = Test-NetCrateRequest $Request $requestId $Settings
    if (@($Association.PSObject.Properties).Count -ne 15 -or $Association.Version -ne 1 -or $Association.Kind -cne 'office-media-association' -or
        $Association.SourceComputer -cne $Settings.SourceComputer -or $Association.WorkerComputer -cne $Settings.WorkerComputer -or
        $Association.RequestId -cne $requestId -or $Association.RequestedSnapshotId -cne $Request.SnapshotId -or $Association.ProjectPath -cne $Request.ProjectPath -or
        $Association.JobId -cne ('auto-' + $Request.FootageFingerprint) -or $Association.FootageFingerprint -cne $Request.FootageFingerprint -or $Association.Recipe -cne $Request.Recipe) {
        throw 'The generation association does not match this backup request.'
    }
    foreach ($name in @('GenerationSnapshotId', 'ResultSnapshotId', 'CompletionSHA256', 'ResultManifestSHA256')) {
        if ($Association.$name -cnotmatch '^[a-f0-9]{64}$') { throw 'A generation identity or checksum is invalid.' }
    }
    $when = if ($Association.PublishedUtc -is [DateTime] -or $Association.PublishedUtc -is [DateTimeOffset]) { $Association.PublishedUtc.ToUniversalTime() }
        else { ([DateTimeOffset]::Parse([string]$Association.PublishedUtc, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
    if ($when -gt [DateTime]::UtcNow.AddMinutes(10)) { throw 'The publication time is invalid.' }
    return $Association
}

Export-ModuleMember -Function Get-NetCrateHash, ConvertTo-NetCrateCanonicalJson, Get-NetCrateRecipe, Get-NetCrateRequestId, Get-NetCrateFootageIdentity, Test-NetCrateRequest, New-NetCrateAssociation, Test-NetCrateAssociation
