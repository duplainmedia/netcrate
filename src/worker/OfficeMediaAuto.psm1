# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
$script:Recipe='half-prores-v2|ffmpeg9.0.1|scale=iw/2:ih/2|prores_ks:profile0:422p10|fps-passthrough|pcm24|source-metadata|12-stills:1232x1176:no-lut'
function Get-AutoProxySettings{return [pscustomobject]@{RecipeId='half-prores-v2';ScaleDivisor=2;BitDepth=10;PixelFormat='yuv422p10le';FingerprintRecipe=$script:Recipe}}
function Get-AutoHash([string]$Text){
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Assert-AutoProjectPath([string]$Path){
    if($Path -notmatch '^/D/Projects/[^/]+$' -or $Path -match '[\\:*?\[\]"<>|\r\n]' -or $Path -match '(^|/)\.\.?(/|$)|[. ]$'){throw 'Automatic projects must be exact direct project folders under /D/Projects.'}
    return $Path
}
function Assert-AutoRequest($Request){
    if($Request.Version -ne 1 -or $Request.Kind -ne 'request' -or $Request.SourceComputer -ine 'SOURCE-PC' -or $Request.Repository -cne 'rest:https://backup.example:8000/sample-user/source-pc/' -or $Request.BackupExitCode -ne 0 -or $Request.SnapshotId -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid automatic backup completion request.'}
    $null=Assert-AutoProjectPath $Request.ProjectPath
    $when=Get-AutoUtc $Request.CompletedUtc
    if($when -gt [DateTime]::UtcNow.AddMinutes(10)){throw 'Request completion time is in the future.'}
    return $Request
}
function Get-AutoUtc([object]$Value){if($Value -is [DateTime]){return $Value.ToUniversalTime()};return ([DateTimeOffset]::Parse([string]$Value)).UtcDateTime}
function New-AutoBackupRequest {
    param([int]$BackupExitCode,[string]$BackupJsonLines,[string]$ProjectPath)
    if($BackupExitCode -ne 0){throw 'Unsuccessful backups never queue automatic proxies.'}
    $null=Assert-AutoProjectPath $ProjectPath
    $summaries=@($BackupJsonLines -split "`n"|Where-Object{$_.Trim()}|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{$_.message_type -eq 'summary'})
    if($summaries.Count -ne 1 -or $summaries[0].snapshot_id -cnotmatch '^[a-f0-9]{64}$'){throw 'A full snapshot ID from this successful backup JSON summary is required.'}
    return [pscustomobject][ordered]@{Version=1;Kind='request';SourceComputer='SOURCE-PC';Repository='rest:https://backup.example:8000/sample-user/source-pc/';BackupExitCode=0;SnapshotId=$summaries[0].snapshot_id;ProjectPath=$ProjectPath;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Get-AutoVideoIdentity {
    param([string]$ProjectPath,[object[]]$Nodes)
    $null=Assert-AutoProjectPath $ProjectPath
    $files=New-Object 'Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $bytes=[long]0
    foreach($node in $Nodes){
        if($node.type -ne 'file'){continue}
        if([IO.Path]::GetExtension($node.path).ToLowerInvariant() -notin @('.mp4','.mov','.mxf','.mts','.m2ts','.avi','.mkv','.mpg','.mpeg','.webm')){continue}
        if(-not $node.path.StartsWith($ProjectPath+'/',[StringComparison]::Ordinal)){throw 'Footage node is outside the selected project.'}
        $relative=$node.path.Substring($ProjectPath.Length+1)
        if($relative -match '[\\:*?\[\]"<>|\r\n]|(^|/)\.\.?(/|$)|[. ]($|/)' -or -not $seen.Add($relative)){throw 'Unsafe or colliding footage paths.'}
        $content=@($node.content)
        if([long]$node.size -lt 0 -or ([long]$node.size -gt 0 -and -not $content.Count) -or @($content|Where-Object{$_ -cnotmatch '^[a-f0-9]{64}$'}).Count){throw 'Footage content identifiers are missing or invalid.'}
        $entry=[ordered]@{RelativePath=$relative;SnapshotPath=$node.path;Bytes=[long]$node.size;Content=$content}
        $files.Add($relative,[pscustomobject]$entry);$bytes += [long]$node.size
    }
    $canonical=[ordered]@{Recipe=$script:Recipe;ProjectPath=$ProjectPath;Files=@($files.Values)}|ConvertTo-Json -Depth 8 -Compress
    return [pscustomobject]@{Fingerprint=(Get-AutoHash $canonical);Clips=$files.Count;Bytes=$bytes;Files=@($files.Values);Recipe=$script:Recipe}
}
function Write-AutoJson([string]$Path,$Value){
    $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.writing'
    $Value|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $temp -Encoding UTF8
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
}
Export-ModuleMember -Function Get-AutoProxySettings,Get-AutoHash,Get-AutoUtc,Assert-AutoProjectPath,Assert-AutoRequest,New-AutoBackupRequest,Get-AutoVideoIdentity,Write-AutoJson

