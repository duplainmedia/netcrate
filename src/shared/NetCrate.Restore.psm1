#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($name in @('Configuration','Credentials','Process')) { Import-Module (Join-Path $PSScriptRoot "NetCrate.$name.psm1") }

function Get-RestoreField($Record,[string]$Name,$Default='') {
    if($Record -is [Collections.IDictionary]) { if($Record.Contains($Name)){return $Record[$Name]} }
    elseif($Record.PSObject.Properties.Name -contains $Name){return $Record.$Name}
    return $Default
}

function Convert-RestoreProject([string]$Path) {
    # Metadata is portable: do not inspect the original drive or its ancestors.
    if($Path -match '^/[A-Z]/'){ $Path=$Path.Substring(1,1)+':'+$Path.Substring(2).Replace('/','\') }
    if($Path -cnotmatch '^[A-Za-z]:[\\/].+' -or $Path.Substring(3) -match '[\\/]{2}') { throw 'The backup has an unsupported source folder.' }
    $relative=$Path.Substring(3).Replace('\','/'); $null=Assert-NetCrateRelativePath $relative
    return $Path.Substring(0,1).ToUpperInvariant()+':\'+$relative.Replace('/','\')
}
function Get-RestoreSelector([string]$Project) { return '/'+$Project.Substring(0,1)+$Project.Substring(2).Replace('\','/') }
function Test-RestoreOverlap([string]$Left,[string]$Right) {
    $a=$Left.TrimEnd('\');$b=$Right.TrimEnd('\')
    return $a.Equals($b,[StringComparison]::OrdinalIgnoreCase) -or $a.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Get-RestoreNativeTimeout($Context,[string[]]$Arguments) {
    $seconds=if($Arguments[0] -ceq 'restore' -or ($Arguments[0] -ceq 'dump' -and $Arguments -ccontains '--target')){86400}else{120}
    $deadline=Get-RestoreField $Context BrowseDeadlineUtc
    if($deadline) {
        $remaining=([DateTimeOffset]$deadline-[DateTimeOffset]::UtcNow).TotalSeconds
        if($remaining -lt 1){throw 'Reading the backup took too long. Reconnect the drive or private connection, then choose Refresh. You can cancel browsing and try again later.'}
        $seconds=[int][Math]::Min($seconds,[Math]::Floor($remaining))
    }
    return $seconds
}
function Invoke-RestoreNative($Context,[string[]]$Arguments) {
    $timeout=Get-RestoreNativeTimeout $Context $Arguments
    try { $r=Invoke-NetCrateProcess $Context.Restic (@('--repo',$Context.Repository,'--no-cache','--no-lock')+$Context.Options+$Arguments) $Context.Environment -TimeoutSeconds $timeout }
    catch {
        if($Arguments -cnotcontains '--target' -and $_.Exception.Message -match 'timed out') {
            throw 'Reading the backup took too long. Reconnect the drive or private connection, then choose Refresh. You can cancel browsing and try again later.'
        }
        throw
    }
    if($r.ExitCode -ne 0){throw 'The originals repository could not be read or verified. Check the recovery file, repository and available space, then try again.'}
    return $r.Output
}
function New-RestoreContext($Request,[string]$Root,[string]$ResticExe,[string]$Action='ListBackups') {
    $pasted=Get-RestoreField $Request RecoveryDocument
    $independent=[bool]((Get-RestoreField $Request RecoveryFile) -or $pasted)
    $options=@();$forbidden=@($Root,[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')));$hostName='';$active=''
    if($independent) {
        $recovery=if($pasted){$pasted}else{Read-NetCrateJson (Get-RestoreField $Request RecoveryFile) -MaximumBytes 32768}
        if($recovery.Version -ne 1 -or $recovery.Kind -cne 'netcrate-recovery' -or $recovery.Primary.Id -cnotmatch '^[a-f0-9]{64}$' -or
            $recovery.Primary.Password -isnot [string] -or $recovery.Primary.Password.Length -lt 1 -or $recovery.Primary.Password.Length -gt 1024){throw 'Choose a valid NetCrate recovery file.'}
        $repository=Assert-NetCrateLocalPath (Get-RestoreField $Request RepositoryPath)
        if(-not [IO.File]::Exists([IO.Path]::Combine($repository,'config'))){throw 'Choose the existing originals repository folder containing config.'}
        $environment=@{RESTIC_PASSWORD=$recovery.Primary.Password};$id=$recovery.Primary.Id
        $forbidden+=@($repository,[IO.Path]::GetDirectoryName($repository))
    } else {
        if(Get-RestoreField $Request RepositoryPath){throw 'Choose both recovery paths.'}
        $owner=Get-NetCrateOwner $Root
        $settings=Import-NetCrateSettings ([IO.Path]::Combine($Root,'settings.json')) Source
        if($owner.Role -cne 'Source' -or $owner.InstallationId -cne $settings.InstallationId -or $owner.InstallationId -cne $Request.InstallationId -or
            -not $settings.StateRoot.Equals($Root,[StringComparison]::OrdinalIgnoreCase)){throw 'Open restore using this source installation.'}
        $secret=Unprotect-NetCrateRecord $Root paired-secrets
        if($secret.SourceComputer -cne $settings.SourceComputer -or
            -not (Convert-RestoreProject $secret.ProjectRoot).Equals($settings.ActiveRoot,[StringComparison]::OrdinalIgnoreCase) -or
            $secret.Repositories.Primary.Id -cne $settings.Repositories.Primary.Id -or $secret.Repositories.Primary.Uri -cne $settings.Repositories.Primary.Uri) {
            throw 'The source settings differ from the protected pairing. Reopen the original source installation.'
        }
        $certificatePath=Assert-NetCrateLocalPath ([IO.Path]::Combine($Root,'server.pem'))
        $certificate=[IO.File]::ReadAllText($certificatePath,[Text.Encoding]::UTF8)
        $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($certificate))).ToLowerInvariant()
        if($fingerprint -cne $secret.CertificateSHA256){throw 'The backup certificate differs from the pinned pairing. Restore the original connection before retrying.'}
        $ResticExe=$settings.Tools.Restic;$repository=$settings.Repositories.Primary.Uri;$id=$settings.Repositories.Primary.Id
        $environment=@{RESTIC_PASSWORD=$secret.PrimaryPassword;RESTIC_REST_USERNAME='editing';RESTIC_REST_PASSWORD=$secret.TransportPassword}
        $options=@('--cacert',[IO.Path]::Combine($Root,'server.pem'))
        $hostName=$settings.SourceComputer;$active=$settings.ActiveRoot;$forbidden+=@($active)
    }
    if(-not [IO.File]::Exists($ResticExe)){throw 'The recovery tool is unavailable. Reopen a complete NetCrate build and try again.'}
    $deadline=$null
    if($Action -cne 'RestoreSelection') {
        $deadline=[DateTimeOffset]::UtcNow.AddMinutes(30)
        $requested=Get-RestoreField $Request BrowseDeadlineUtc
        if($requested){$requested=[DateTimeOffset]$requested;if($requested -lt $deadline){$deadline=$requested}}
    }
    $c=[pscustomobject]@{BrowseDeadlineUtc=$deadline;Restic=$ResticExe;Repository=$repository;Id=$id;Environment=$environment;Options=$options;Forbidden=$forbidden;HostName=$hostName;ActiveRoot=$active}
    $config=Invoke-RestoreNative $c @('cat','config')|ConvertFrom-Json
    if($config.id -cne $id){throw 'This repository does not match the recovery file or source installation. Choose the matching originals repository.'}
    return $c
}
function Assert-NetCrateRestoreNodes($Nodes) {
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($node in @($Nodes)) {
        if($null -eq $node){continue}
        $name=$node.name
        if($name -isnot [string] -or -not $name -or $name.Contains('/') -or $name.Contains('\')){throw 'The backup contains an unsafe filename.'}
        $null=Assert-NetCrateRelativePath $name
        if(-not $seen.Add($name) -or $node.type -cnotin @('file','dir')){throw 'The backup contains colliding names, links or unsupported entries.'}
    }
}
function Get-RestoreTree($Context,[string]$Tree) {
    $kind=if($Tree -cmatch '^[a-f0-9]{64}$'){'blob'}else{'tree'}
    $value=Invoke-RestoreNative $Context @('cat',$kind,$Tree)|ConvertFrom-Json
    $nodes=@($value.nodes|Where-Object {$null -ne $_})
    Assert-NetCrateRestoreNodes $nodes
    return $nodes
}
function Get-RestoreBackups($Context,[string]$SnapshotId='', [int]$Offset=0) {
    $query=@('snapshots','--json');if($SnapshotId){$query+=@($SnapshotId)}
    $snapshots=@(Invoke-RestoreNative $Context $query|ConvertFrom-Json)
    if($snapshots.Count -gt 20000){throw 'The backup list is too large. Use repository maintenance before browsing.'}
    $candidates=@($snapshots|Where-Object {
        $tags=@(Get-RestoreField $_ tags @())
        ($tags -ccontains 'netcrate-originals' -or $tags -ccontains 'netcrate-folder-originals') -and $tags -cnotcontains 'netcrate-backup-receipt'
    }|Sort-Object time,id -Descending)
    if($Offset -gt $candidates.Count){throw 'Refresh this list to continue browsing.'}
    $end=[Math]::Min($Offset+50,$candidates.Count)
    $selected=@();if($end -gt $Offset){$selected=@($candidates[$Offset..($end-1)])}
    $items=@(foreach($s in $selected) {
        $tags=@(Get-RestoreField $s tags @())
        if($s.id -cnotmatch '^[a-f0-9]{64}$' -or @($s.paths).Count -ne 1 -or
            ($tags -cnotcontains 'netcrate-originals' -and $tags -cnotcontains 'netcrate-folder-originals') -or
            $tags -ccontains 'netcrate-backup-receipt' -or $tags -ccontains 'netcrate-proxies'){continue}
        try {$project=Convert-RestoreProject $s.paths[0]}catch{continue}
        if(-not $s.hostname -or $s.hostname.Length -gt 255){continue}
        if($Context.HostName -and ($s.hostname -cne $Context.HostName -or -not ($project.Equals($Context.ActiveRoot,[StringComparison]::OrdinalIgnoreCase) -or $project.StartsWith($Context.ActiveRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)))){continue}
        $mode=if($tags -ccontains 'netcrate-folder-originals'){'Folder'}else{'Media'}
        $completion='Unknown (legacy)';$date=([DateTimeOffset]$s.time).UtcDateTime.ToString('o')
        $receiptTag='netcrate-receipt-'+$s.id
        $receipts=if($SnapshotId){@(Invoke-RestoreNative $Context @('snapshots','--json','--host',$s.hostname,'--tag',$receiptTag)|ConvertFrom-Json)}
            else{@($snapshots|Where-Object { @((Get-RestoreField $_ tags @())) -ccontains $receiptTag })}
        if(@($receipts).Count -gt 1000){throw 'This backup has too many completion records. Choose another backup and check storage maintenance.'}
        $valid=$false
        foreach($rs in $receipts) {
            try {
                if($rs.id -cnotmatch '^[a-f0-9]{64}$' -or $rs.hostname -cne $s.hostname -or @($rs.paths).Count -ne 1 -or
                    $rs.tags -cnotcontains 'netcrate-backup-receipt' -or $rs.tags -ccontains 'netcrate-v2-originals' -or $rs.tags -ccontains 'netcrate-originals' -or $rs.tags -ccontains 'netcrate-folder-originals'){continue}
                $rp=Get-RestoreSelector (Convert-RestoreProject $rs.paths[0])
                if(-not $rp.EndsWith('/BackupReceipts/'+$s.id+'.json',[StringComparison]::Ordinal)){continue}
            } catch { $null=Get-RestoreNativeTimeout $Context @('cat','config'); continue }
            # A read failure is operational, not evidence that this receipt is invalid.
            # Keep native access outside both metadata/payload validation catches.
            $wire=Invoke-RestoreNative $Context @('dump',$rs.id,$rp)
            try {
                if([Text.Encoding]::UTF8.GetByteCount($wire) -gt 16384){continue}
                $doc=[System.Text.Json.JsonDocument]::Parse($wire);try { $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); foreach($property in $doc.RootElement.EnumerateObject()){if(-not $names.Add($property.Name)){throw 'The completion receipt contains duplicate fields.'}} }finally{$doc.Dispose()}
                $r=$wire|ConvertFrom-Json
                $expectedFields=@('Version','Kind','RepositoryId','SourceComputer','Project','SnapshotId','BackupMode','JobId','BackupCompletedUtc')
                if(@($r.PSObject.Properties.Name|Where-Object {$_ -cnotin $expectedFields}).Count){continue}
                if(@($r.PSObject.Properties).Count -ne 9 -or $r.Version -ne 1 -or $r.Kind -cne 'backup-receipt' -or $r.RepositoryId -cne $Context.Id -or
                    $r.SourceComputer -cne $s.hostname -or (Convert-RestoreProject $r.Project) -cne $project -or $r.SnapshotId -cne $s.id -or
                    $r.BackupMode -cne $mode -or $r.JobId -isnot [string] -or $r.JobId -cnotmatch '^[a-zA-Z0-9_-]{1,128}$'){continue}
                $date=([DateTimeOffset]$r.BackupCompletedUtc).UtcDateTime.ToString('o');$valid=$true
            } catch { $null=Get-RestoreNativeTimeout $Context @('cat','config'); continue }
        }
        if($tags -ccontains 'netcrate-v2-originals' -and -not $valid){continue}
        if($valid){$completion='Complete'}
        [pscustomobject]@{SnapshotId=$s.id;Project=$project;SourceComputer=$s.hostname;BackupCompletedUtc=$date;BackupMode=$mode;Completion=$completion;Name=($project+' · '+([DateTimeOffset]$date).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')+' · '+$completion);RelativePath='';Type='dir'}
    })
    return [pscustomobject]@{Items=$items;NextCursor=if($end -lt $candidates.Count){[string]$end}else{''}}
}
function Get-RestoreSelection($Context,$Backup,[string]$RelativePath) {
    if($RelativePath){$null=Assert-NetCrateRelativePath $RelativePath;if($RelativePath.EndsWith('/')){throw 'Choose an exact backup path.'}}
    $base=Get-RestoreSelector $Backup.Project
    $parent=$base;$node=$null
    $tree=$Backup.SnapshotId+':'+$base
    if($RelativePath) {
        $parts=$RelativePath.Split('/')
        for($i=0;$i -lt $parts.Count;$i++) {
            $nodes=@(Get-RestoreTree $Context $tree)
            $matches=@($nodes|Where-Object name -CEQ $parts[$i])
            if($matches.Count -ne 1){throw 'The selected file or folder is no longer available. Refresh the backup list.'}
            $node=$matches[0]
            if($i -lt $parts.Count-1){if($node.type -cne 'dir'){throw 'Choose a folder from this backup.'};$tree=$node.subtree;$parent+='/'+$node.name}
        }
    }
    $type=if($node){$node.type}else{'dir'}
    $selector=if($RelativePath){$base+'/'+$RelativePath}else{$base}
    if($type -ceq 'dir'){$tree=if($node){$node.subtree}else{$Backup.SnapshotId+':'+$base}}
    return [pscustomobject]@{Type=$type;Tree=$tree;Selector=$selector;Parent=$parent;Size=if($node){Get-RestoreField $node size 0}else{0};Name=if($node){$node.name}else{[IO.Path]::GetFileName($Backup.Project)}}
}
function Get-RestoreManifest($Context,[string]$Tree) {
    $pending=[Collections.Generic.Stack[object]]::new();$pending.Push(@{Tree=$Tree;Path=''})
    $result=[Collections.Generic.List[object]]::new()
    while($pending.Count) {
        $current=$pending.Pop()
        foreach($node in @(Get-RestoreTree $Context $current.Tree)) {
            $path=if($current.Path){$current.Path+'/'+$node.name}else{$node.name}
            $size=if($node.type -ceq 'file'){[long](Get-RestoreField $node size 0)}else{0}
            if($size -lt 0){throw 'The backup contains an invalid file length.'}
            $result.Add([pscustomobject]@{RelativePath=$path;Type=$node.type;Size=$size})
            if($result.Count -gt 1000000){throw 'The selected backup contains too many entries. Choose a smaller folder.'}
            if($node.type -ceq 'dir'){$pending.Push(@{Tree=$node.subtree;Path=$path})}
        }
    }
    return $result.ToArray()
}
function Assert-RestoreOwnedPath([string]$Root,[string]$Path) {
    $full=Assert-NetCrateLocalPath $Path
    if(-not $full.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The staging entry is outside its owned operation.'}
    return $full
}
function Expand-RestoreArchive([string]$Archive,[string]$Payload,$Manifest) {
    Add-Type -AssemblyName System.Formats.Tar
    $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($item in @($Manifest)){$expected.Add($item.RelativePath,$item)}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $input=[IO.File]::OpenRead($Archive);$reader=[System.Formats.Tar.TarReader]::new($input)
    try {
        while($entry=$reader.GetNextEntry()) {
            $name=$entry.Name.TrimEnd('/')
            $null=Assert-NetCrateRelativePath $name
            if(-not $expected.ContainsKey($name) -or -not $seen.Add($name)){throw 'The backup archive differs from the validated folder tree.'}
            $item=$expected[$name]
            $target=Assert-RestoreOwnedPath $Payload ([IO.Path]::Combine($Payload,$name.Replace('/','\')))
            if($item.Type -ceq 'dir') {
                if($entry.EntryType -ne [System.Formats.Tar.TarEntryType]::Directory){throw 'An archive entry has an unsupported type.'}
                $null=Set-NetCratePrivateDirectory $target
            } else {
                if($entry.EntryType -ne [System.Formats.Tar.TarEntryType]::RegularFile -or $entry.Length -ne $item.Size){throw 'An archive file differs from its original metadata.'}
                $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                $output=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try {if($entry.DataStream){$entry.DataStream.CopyTo($output)};$output.Flush($true)}finally{$output.Dispose()}
                if([IO.FileInfo]::new($target).Length -ne $item.Size){throw 'An archive file is incomplete.'}
            }
        }
        if($seen.Count -ne $expected.Count){throw 'The archive omitted part of the validated folder tree.'}
    } finally {$reader.Dispose();$input.Dispose()}
}
function Confirm-RestoreFile($Context,[string]$Snapshot,[string]$Selector,[string]$Path,[long]$Size,[string]$Stage) {
    # A second authenticated native read verifies extraction and native byte-safe file output independently.
    $verify=Assert-RestoreOwnedPath $Stage ([IO.Path]::Combine($Stage,'verify.bin'))
    $null=Invoke-RestoreNative $Context @('dump',$Snapshot,$Selector,'--target',$verify)
    try {
        if([IO.FileInfo]::new($Path).Length -ne $Size -or [IO.FileInfo]::new($verify).Length -ne $Size -or
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $verify -Algorithm SHA256).Hash){throw 'Recovered file bytes did not pass verification. Retry with the backup drive connected.'}
    } finally {if([IO.File]::Exists($verify)){[IO.File]::Delete($verify)}}
}
function Assert-RestoreDestination($Context,[string]$Path,[string]$Project) {
    $full=Assert-NetCrateLocalPath $Path
    if(-not [IO.Directory]::Exists($full)){throw 'Choose an existing ordinary folder for the new recovery folder.'}
    foreach($forbidden in @($Context.Forbidden)+@($Project)) {if($forbidden -and (Test-RestoreOverlap $full $forbidden)){throw 'Choose a recovery location outside the source, NetCrate state and backup storage.'}}
    $part=$full
    while($part){if(([IO.File]::GetAttributes($part) -band (0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000)) -ne 0){throw 'Choose a fully available local recovery folder without links.'};$part=[IO.Path]::GetDirectoryName($part.TrimEnd('\'))}
    return $full
}
function Invoke-NetCrateRestoreAction {
    param([ValidateSet('ListBackups','ListBackupChildren','RestoreSelection')][string]$Action,$Request,[string]$Root,[string]$ResticExe)
    $context=New-RestoreContext $Request $Root $ResticExe $Action
    try {
        $items=@();$cursor=[string](Get-RestoreField $Request Cursor)
        if($cursor -and $cursor -cnotmatch '^(0|[1-9][0-9]{0,6})$'){throw 'Refresh this list to continue browsing.'}
        $offset=if($cursor){[int]$cursor}else{0}
        if($Action -ceq 'ListBackups'){
            $page=Get-RestoreBackups $context '' $offset
            return @{Succeeded=$true;Code='ok';Message=if(@($page.Items).Count){'Choose a dated backup.'}elseif($page.NextCursor){'No completed backups on this page. Choose More to continue.'}else{'No completed originals were found in this repository.'};Items=@($page.Items);NextCursor=$page.NextCursor}
        }
        else {
            $id=[string](Get-RestoreField $Request SnapshotId)
            if($id -cnotmatch '^[a-f0-9]{64}$'){throw 'Choose an exact dated backup.'}
            $found=@((Get-RestoreBackups $context $id).Items|Where-Object SnapshotId -CEQ $id)
            if($found.Count -ne 1){throw 'This backup has no valid completion evidence or does not belong to this source. Refresh and choose another date.'}
            $backup=$found[0];$relative=[string](Get-RestoreField $Request RelativePath)
            $selected=Get-RestoreSelection $context $backup $relative
            if($Action -ceq 'ListBackupChildren') {
                if($selected.Type -cne 'dir'){throw 'Choose a folder to browse.'}
                $items=@(Get-RestoreTree $context $selected.Tree|Sort-Object name|ForEach-Object {
                    [pscustomobject]@{Name=$_.name;Type=$_.type;RelativePath=if($relative){$relative+'/'+$_.name}else{$_.name};SnapshotId=$id;Size=(Get-RestoreField $_ size 0)}
                })
            } else {
                # Dump never applies historical Windows security descriptors. Materialize only validated entries.
                $manifest=@()
                if($selected.Type -ceq 'dir'){$manifest=@(Get-RestoreManifest $context $selected.Tree)}
                $parent=Assert-RestoreDestination $context ([string](Get-RestoreField $Request DestinationParent)) $backup.Project
                $stage=[IO.Path]::Combine($parent,'.netcrate-restore-'+[guid]::NewGuid().ToString('N'))
                $null=Set-NetCratePrivateDirectory $stage
                try {
                    $payload=[IO.Path]::Combine($stage,'payload');$null=Set-NetCratePrivateDirectory $payload
                    if($selected.Type -ceq 'file') {
                        $file=Assert-RestoreOwnedPath $payload ([IO.Path]::Combine($payload,$selected.Name))
                        $null=Invoke-RestoreNative $context @('dump',$id,$selected.Selector,'--target',$file)
                        Confirm-RestoreFile $context $id $selected.Selector $file $selected.Size $stage
                    } else {
                        $archive=Assert-RestoreOwnedPath $stage ([IO.Path]::Combine($stage,'originals.tar'))
                        $null=Invoke-RestoreNative $context @('dump',($id+':'+$selected.Selector),'/','--archive','tar','--target',$archive)
                        Expand-RestoreArchive $archive $payload $manifest
                        foreach($file in @($manifest|Where-Object Type -CEQ 'file')) {
                            $path=Assert-RestoreOwnedPath $payload ([IO.Path]::Combine($payload,$file.RelativePath.Replace('/','\')))
                            Confirm-RestoreFile $context $id ($selected.Selector+'/'+$file.RelativePath) $path $file.Size $stage
                        }
                    }
                    $publish=$payload
                    # Recheck ancestors immediately before a same-volume no-overwrite rename.
                    $null=Assert-RestoreDestination $context $parent $backup.Project
                    $name='Recovered-'+([DateTimeOffset]$backup.BackupCompletedUtc).ToString('yyyyMMdd-HHmmss')+'-'+$id.Substring(0,8)
                    $destination=[IO.Path]::Combine($parent,$name)
                    if([IO.Directory]::Exists($destination) -or [IO.File]::Exists($destination)){$destination+='-'+[guid]::NewGuid().ToString('N').Substring(0,8)}
                    $null=Assert-NetCrateLocalPath $destination
                    [IO.Directory]::Move($publish,$destination)
                    return @{Succeeded=$true;Code='ok';Message='The selected files were verified and recovered.';RestoredPath=$destination}
                } finally {
                    # Only delete the unpredictable, private directory allocated by this operation.
                    if([IO.Directory]::Exists($stage)) {
                        $cleanup=Assert-NetCrateLocalPath $stage
                        if(-not [IO.Path]::GetDirectoryName($cleanup).Equals($parent,[StringComparison]::OrdinalIgnoreCase) -or
                            [IO.Path]::GetFileName($cleanup) -cnotmatch '^\.netcrate-restore-[a-f0-9]{32}$') {throw 'The owned staging path changed; its files were preserved.'}
                        [IO.Directory]::Delete($cleanup,$true)
                    }
                }
            }
        }
        if($offset -gt $items.Count){throw 'Refresh this list to continue browsing.'}
        $end=[Math]::Min($offset+200,$items.Count);$page=@();if($end -gt $offset){$page=@($items[$offset..($end-1)])}
        return @{Succeeded=$true;Code='ok';Message=if($items.Count){'Choose a dated backup or a file or folder.'}elseif($Action -ceq 'ListBackupChildren'){'This folder is empty. You can restore the empty folder.'}else{'No completed originals were found in this repository.'};Items=$page;NextCursor=if($end -lt $items.Count){[string]$end}else{''}}
    } finally {$context.Environment.Clear()}
}
Export-ModuleMember -Function Invoke-NetCrateRestoreAction, Assert-NetCrateRestoreNodes
