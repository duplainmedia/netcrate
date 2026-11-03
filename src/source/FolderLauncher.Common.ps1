#requires -Version 5.1
function Get-OfficeBackupArguments {
    param([string[]]$Arguments)
    # Restic skips this whole generated tree, so proxies never become source clips.
    return @('--exclude-if-present','.office-generated-media')+$Arguments
}
function Get-FolderMediaPlan {
    param([string]$FolderPath,[string]$ActiveRoot='D:\Video Projects',[string[]]$ExcludedProjects=@())
    if([string]::IsNullOrWhiteSpace($FolderPath)){throw 'Place the launcher inside a project folder before running it.'}
    $folder=Get-Item -LiteralPath $FolderPath -Force -ErrorAction Stop
    if(-not $folder.PSIsContainer -or $folder.PSProvider.Name -ne 'FileSystem'){throw 'The launcher needs a regular project folder.'}
    $project=$folder.FullName.TrimEnd('\')
    $root=[IO.Path]::GetFullPath($ActiveRoot).TrimEnd('\')
    if(-not [string]::Equals([IO.Path]::GetDirectoryName($project),$root,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Place the BAT in a top-level project folder under D:\Video Projects. Its subfolders are included automatically.'
    }
    if($folder.Name -in $ExcludedProjects){throw 'This project is excluded from backup. Its exclusion must be changed before processing.'}
    if($folder.Name -match '[\\:*?\[\]"<>|\r\n]|^\.\.?$|[. ]$'){throw 'This project name is not supported by the office processing workflow.'}
    $cursor=$project
    while($cursor){
        if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked project folders are not supported.'}
        $cursor=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
    }
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($project)
    $sourceFiles=New-Object 'Collections.Generic.List[object]'
    while($pending.Count){
        $directory=$pending.Pop()
        if(Test-Path -LiteralPath (Join-Path $directory '.office-generated-media') -PathType Leaf){continue}
        foreach($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The project contains a linked file or folder. No backup was started.'}
            if($item.PSIsContainer){$pending.Push($item.FullName)}else{$sourceFiles.Add($item)}
        }
    }
    $files=$sourceFiles.ToArray()
    $videos=@($files|Where-Object{$_.Extension.ToLowerInvariant() -in @('.mp4','.mov','.mxf','.mts','.m2ts','.avi','.mkv','.mpg','.mpeg','.webm')})
    if(-not $videos.Count){throw 'No supported video clips were found in this folder or its subfolders.'}
    [pscustomobject]@{ProjectPath=$project;ProjectName=$folder.Name;VideoFiles=$videos.Count;TotalFiles=$files.Count;TotalBytes=[long](($files|Measure-Object Length -Sum).Sum)}
}
