#requires -Version 5.1
function Write-OfficeDeliveryJson([string]$Path,$Value){
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.writing'
    $Value|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $temporary -Encoding UTF8
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
}
function Resolve-OfficeResticExecutable {
    param([string]$PreferredPath)
    if($PreferredPath){
        if(-not(Test-Path -LiteralPath $PreferredPath -PathType Leaf)){throw 'The specified Restic executable does not exist.'}
        return (Get-Item -LiteralPath $PreferredPath).FullName
    }
    $installed=Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\restic.restic_Microsoft.Winget.Source_8wekyb3d8bbwe\restic_0.19.1_windows_amd64.exe'
    if(Test-Path -LiteralPath $installed -PathType Leaf){return (Get-Item -LiteralPath $installed).FullName}
    $command=Get-Command restic -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)){return $command.Source}
    throw 'Restic executable not found; specify its installed executable path.'
}
function Assert-SafePath([string]$Path,[string]$Parent){
    $full=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetFullPath($Parent).TrimEnd('\')+'\'
    if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe destination path.'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse destination rejected.'}}
        $cursor=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
    }
    return $full
}
function Resolve-OfficeDeliveryDestination {
    param([string]$OutputRoot,[string]$JobId,[string]$SnapshotId)
    if($JobId -notmatch '^[a-z0-9][a-z0-9._-]{0,100}$' -or $SnapshotId -notmatch '^[a-f0-9]{64}$'){throw 'Invalid result job or snapshot identity.'}
    $base=Assert-SafePath (Join-Path $OutputRoot $JobId) $OutputRoot
    if(-not(Test-Path -LiteralPath $base)){return $base}
    if(-not(Test-Path -LiteralPath $base -PathType Container)){throw 'Existing delivery is not a directory.'}
    $previous=Get-Content -LiteralPath (Join-Path $base 'DELIVERY.json') -Raw | ConvertFrom-Json
    if($previous.ResultSnapshot -notmatch '^[a-f0-9]{64}$'){throw 'Existing delivery identity is invalid; preserving it.'}
    if($previous.ResultSnapshot -eq $SnapshotId){return $base}
    $version=Assert-SafePath (Join-Path $OutputRoot ($JobId+'--'+$SnapshotId)) $OutputRoot
    if(Test-Path -LiteralPath $version){
        if(-not(Test-Path -LiteralPath $version -PathType Container)){throw 'Existing version is not a directory.'}
        $delivery=Get-Content -LiteralPath (Join-Path $version 'DELIVERY.json') -Raw | ConvertFrom-Json
        if($delivery.ResultSnapshot -ne $SnapshotId){throw 'Existing delivery belongs to a different snapshot; preserving it.'}
    }
    return $version
}
function Resolve-OfficeProjectOutputRoot {
    param($Complete,$Settings)
    if(-not $Complete.verified -or $Complete.snapshot_id -cnotmatch '^[a-f0-9]{64}$'){throw 'Project placement requires a verified source snapshot.'}
    $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($directory in Get-ChildItem -LiteralPath $Settings.RequestRoot -Directory){
        if($directory.Name -cnotmatch '^[a-f0-9]{64}$' -or $directory.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
        $path=Join-Path $directory.FullName 'request.json'
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $item=Get-Item -LiteralPath $path -Force
        if($item.Length -gt 32768 -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
        $request=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        if($request.SnapshotId -cne $Complete.snapshot_id -or $request.Kind -ne 'request' -or $request.Version -ne 1 -or $request.BackupExitCode -ne 0 -or $request.SourceComputer -ine 'SOURCE-PC' -or $request.Repository -cne 'rest:http://backup.example:8000/sample-user/source-pc/'){continue}
        if($request.ProjectPath -cmatch '^/D/Video Projects/([^/]+)$' -and $Matches[1] -ceq $Complete.project){[void]$names.Add($Matches[1])}
    }
    foreach($legacy in @($Settings.LegacyProjects)){
        if($legacy.SnapshotId -ceq $Complete.snapshot_id -and $legacy.DisplayName -ceq $Complete.project){[void]$names.Add([string]$legacy.ProjectName)}
    }
    if($names.Count -ne 1){throw 'No unambiguous successful-backup project mapping exists for this result; delivery retained for retry.'}
    $name=@($names)[0]
    if($name -match '[\\/:*?\[\]"<>|\r\n]|^\.\.?$|[. ]$'){throw 'Unsafe project name in delivery mapping.'}
    $project=Assert-SafePath (Join-Path $Settings.ActiveRoot $name) $Settings.ActiveRoot
    if(-not(Test-Path -LiteralPath $project -PathType Container)){throw 'Original project folder is unavailable; delivery retained for retry.'}
    $root=Assert-SafePath (Join-Path $project 'Proxies') $project
    $marker=Join-Path $root '.office-generated-media'
    if(Test-Path -LiteralPath $root){
        if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'Existing Proxies path is not a directory; preserving it.'}
        if(Test-Path -LiteralPath $marker -PathType Leaf){
            $null=Assert-SafePath $marker $root
            $identity=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
            if($identity.Kind -ne 'OfficeGeneratedMedia' -or $identity.Version -ne 1 -or $identity.ProjectPath -cne ('/D/Video Projects/'+$name)){throw 'Existing Proxies folder has an unrelated identity; preserving it.'}
            return $root
        }
        if(@(Get-ChildItem -LiteralPath $root -Force).Count){throw 'Existing nonempty Proxies folder is not managed by this workflow; preserving it.'}
    }else{[void][IO.Directory]::CreateDirectory($root)}
    @{Version=1;Kind='OfficeGeneratedMedia';ProjectPath=('/D/Video Projects/'+$name)}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding UTF8
    return $root
}
