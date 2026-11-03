#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Dependencies.psm1')
Import-Module (Join-Path $PSScriptRoot '..\src\shared\NetCrate.Configuration.psm1')

function Get-NetCratePlannedPackageStatus {
    param($Package, [string]$Destination, [string]$CacheRoot)
    $cache = ConvertTo-NetCrateFileSystemPath ([IO.Path]::Combine($CacheRoot, $Package.SHA256 + '.package'))
    $cacheStatus = 'Missing'
    if ([IO.File]::Exists($cache)) {
        $cacheStatus = 'Repair'
        if ((Get-FileHash -LiteralPath $cache).Hash -ieq $Package.SHA256) { $cacheStatus = 'Cached' }
    }
    $status = $cacheStatus
    $native = ConvertTo-NetCrateFileSystemPath $Destination
    if ([IO.Directory]::Exists($native) -or [IO.File]::Exists($native)) {
        $status = 'Repair'
        if (Test-NetCrateInstalledPackage $Package $Destination) { $status = 'Reused' }
    }
    return [pscustomobject]@{Status=$status; CacheStatus=$cacheStatus}
}

function Get-NetCrateSoftwarePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][ValidateSet('Source','Worker')][string]$Role,
        [ValidateSet('Folder','Media')][string]$BackupMode='Media', [Parameter(Mandatory)][string]$Folder, [switch]$RecoveryOnly)
    $Root = Assert-NetCrateLocalPath $Root
    $BootstrapRoot = Assert-NetCrateLocalPath $BootstrapRoot
    $Folder = Assert-NetCrateLocalPath $Folder
    $Role = if ($Role -ieq 'Source') { 'Source' } else { 'Worker' }
    $BackupMode = if ($BackupMode -ieq 'Folder') { 'Folder' } else { 'Media' }
    $metadata = @{
        PowerShell=@('Runs the private NetCrate setup and background engine.','MIT')
        Restic=@('Creates, verifies and restores encrypted backups.','BSD-2-Clause')
        RestServer=@('Serves encrypted backup repositories over private HTTPS.','BSD-2-Clause')
        Python=@('Runs the private HTTPS transport and server helpers.','PSF-2.0')
        FFmpeg=@('Creates media proxies; includes FFprobe for media inspection.','GPL-3.0-or-later (full build; includes third-party components)')
        Pillow=@('Creates image previews in Media mode.','MIT-CMU')
        Bcrypt=@('Checks backup server password hashes.','Apache-2.0')
    }
    $catalog = Get-NetCrateDependencyCatalog
    $selected = @($catalog.Packages | Where-Object { $Role -cin $_.Roles -and -not ($BackupMode -ceq 'Folder' -and $_.Name -cin @('FFmpeg','Pillow')) })
    $powershell = @($selected | Where-Object Name -CEQ 'PowerShell')
    if ($powershell.Count -ne 1) { throw 'The software download list must include one private PowerShell package.' }
    $selections = @([pscustomobject]@{Package=$powershell[0];Base=$BootstrapRoot;Scope='Bootstrap'}) + @($selected | ForEach-Object { [pscustomobject]@{Package=$_;Base=$Root;Scope='Runtime'} })
    if ($RecoveryOnly) {
        $recovery = @($catalog.Packages | Where-Object { $_.Name -cin @('PowerShell','Restic') })
        if ($recovery.Count -ne 2 -or @($recovery | Where-Object Name -CEQ 'Restic').Count -ne 1) { throw 'The recovery software download list is invalid.' }
        $selections = @($recovery | ForEach-Object { [pscustomobject]@{Package=$_;Base=$BootstrapRoot;Scope='Bootstrap'} })
    }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($selection in $selections) {
        $package=$selection.Package
        if (-not $metadata.ContainsKey($package.Name) -or $package.Name -cnotmatch '^[A-Za-z][A-Za-z0-9]{0,30}$' -or
            $package.Version -cnotmatch '^[0-9]+(\.[0-9]+){1,3}$' -or $package.SHA256 -cnotmatch '^[a-f0-9]{64}$') { throw 'The software download entry is invalid.' }
        $url=[uri]$package.Url
        if (-not $url.IsAbsoluteUri -or $url.Scheme -cne 'https' -or $url.UserInfo -or $url.Host -cnotin @('github.com','www.python.org','files.pythonhosted.org')) { throw 'The software source is invalid.' }
        $null=Assert-NetCrateRelativePath $package.Executable
        $destination=[IO.Path]::Combine($selection.Base,'Tools',$package.Name,$package.Version)
        $state=Get-NetCratePlannedPackageStatus $package $destination ([IO.Path]::Combine($selection.Base,'Downloads'))
        $rows.Add([pscustomobject][ordered]@{
            Name=$package.Name;Version=$package.Version;Purpose=$metadata[$package.Name][0];Source=$package.Url;License=$metadata[$package.Name][1]
            Destination=$destination;Scope=$selection.Scope;Status=$state.Status;SHA256=$package.SHA256;Executable=$package.Executable;CacheStatus=$state.CacheStatus
        })
    }
    # Length-prefixed fields avoid ambiguous concatenation; no status/cache evidence is consent identity.
    $identity=[Text.StringBuilder]::new()
    $purpose = if ($RecoveryOnly) { 'Recovery' } else { 'Setup' }
    $fields=@('1',$purpose,$Role,$BackupMode,$Folder.ToUpperInvariant(),$Root.ToUpperInvariant(),$BootstrapRoot.ToUpperInvariant())
    foreach($row in $rows){$fields+=@($row.Name,$row.Version,$row.Source,$row.SHA256,$row.Executable,$row.Destination.ToUpperInvariant(),$row.Scope,$row.Purpose,$row.License)}
    foreach($field in $fields){$value=[string]$field;$null=$identity.Append($value.Length).Append(':').Append($value)}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity.ToString())))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return [pscustomobject][ordered]@{Version=1;PlanId=$id;Packages=@($rows.ToArray());Changes=@($rows.ToArray() | Where-Object Status -CNE 'Reused')}
}

function Assert-NetCrateSoftwarePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][ValidateSet('Source','Worker')][string]$Role,
        [ValidateSet('Folder','Media')][string]$BackupMode='Media', [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$PlanId, [switch]$RecoveryOnly)
    $plan=Get-NetCrateSoftwarePlan -Root $Root -BootstrapRoot $BootstrapRoot -Role $Role -BackupMode $BackupMode -Folder $Folder -RecoveryOnly:$RecoveryOnly
    if ($PlanId -cnotmatch '^[a-f0-9]{64}$' -or $PlanId -cne $plan.PlanId) { throw 'The software choices changed. Review and accept the current software plan before preparation.' }
    return $plan
}

Export-ModuleMember -Function Get-NetCrateSoftwarePlan, Assert-NetCrateSoftwarePlan
