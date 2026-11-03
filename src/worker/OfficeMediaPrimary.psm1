# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
$script:Root='C:\ProgramData\NetCrate\Office'
$script:Repository='E:\NetCrate\Repositories\sample-user\source-pc'
Import-Module "$PSScriptRoot\OfficeMediaAuto.psm1" -ErrorAction Stop
function Invoke-PrimaryRead {
    param([string[]]$Arguments)
    $valid=$Arguments.Count -ge 1 -and $Arguments[0] -in @('snapshots','cat','restore')
    if($Arguments[0] -eq 'cat'){
        $valid=$Arguments.Count -eq 3 -and (($Arguments[1] -eq 'snapshot' -and $Arguments[2] -cmatch '^[a-f0-9]{64}$') -or ($Arguments[1] -eq 'tree' -and $Arguments[2] -cmatch '^[a-f0-9]{64}:/D/Projects/[^:*?\[\]\\"<>|\r\n]+$' -and $Arguments[2] -notmatch '(^|/)\.\.?(/|$)'))
    }
    if($Arguments[0] -eq 'snapshots'){$valid=$Arguments.Count -eq 1}
    if($Arguments[0] -eq 'restore'){
        $valid=$Arguments.Count -eq 10 -and $Arguments[1] -cmatch '^[a-f0-9]{64}:/D/Projects/' -and $Arguments[2] -eq '--target' -and $Arguments[4] -eq '--verify' -and $Arguments[5] -eq '--overwrite' -and $Arguments[6] -eq 'if-changed' -and $Arguments[7] -eq '--include-file' -and $Arguments[9] -eq '--sparse'
        try{$null=Assert-AutoProjectPath ($Arguments[1].Substring(65))}catch{$valid=$false}
        foreach($path in @($Arguments[3],$Arguments[8])){if(-not [IO.Path]::GetFullPath($path).StartsWith($script:Root+'\Jobs\',[StringComparison]::OrdinalIgnoreCase)){$valid=$false}}
    }
    if(-not $valid){throw 'Read-only primary operation or arguments rejected.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if($identity.Name -ine 'WORKER-PC\worker-user'){throw 'Primary worker identity mismatch.'}
    $credentialPath=$script:Root+'\primary-restore.dpapi.json'
    foreach($path in @($script:Root,$credentialPath)){
        $cursor=$path
        while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse primary credential path rejected.'};$cursor=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))}
        foreach($rule in (Get-Acl -LiteralPath $path).Access){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @($identity.User.Value,([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null).Value))){throw 'Primary worker credential ACL is too broad.'}}
    }
    $record=Get-Content -LiteralPath $credentialPath -Raw|ConvertFrom-Json
    if($record.Version -ne 1 -or $record.Repository -cne $script:Repository -or $record.ProtectedForUserSid -ne $identity.User.Value -or $record.RepositoryConfigSHA256 -ne (Get-FileHash -LiteralPath ($script:Repository+'\config')).Hash){throw 'Primary repository credential identity mismatch.'}
    $plain=$null;$child=$null;$psi=$null
    try{
        $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($record.PasswordMachineDpapi),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $psi=[Diagnostics.ProcessStartInfo]::new('C:\Program Files\NetCrate\Backup\restic.exe')
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        foreach($name in @($psi.Environment.Keys)){if($name -like 'RESTIC_*'){$null=$psi.Environment.Remove($name)}}
        foreach($arg in @('--repo',$script:Repository,'--no-lock','--no-cache','--json')+$Arguments){$psi.ArgumentList.Add($arg)}
        $psi.Environment['RESTIC_PASSWORD']=[Text.Encoding]::UTF8.GetString($plain)
        $child=[Diagnostics.Process]::new();$child.StartInfo=$psi;$null=$child.Start();$psi.Environment.Clear()
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();$child.WaitForExit()
        $text=$stdout.GetAwaiter().GetResult();$diagnostic=$stderr.GetAwaiter().GetResult()
        if($child.ExitCode -ne 0){
            $category='Other'
            if($diagnostic -match 'wrong password|no key found'){$category='KeyRejected'}
            elseif($diagnostic -match 'not found|does not exist|no such file'){$category='MissingObject'}
            elseif($diagnostic -match 'Access is denied|permission denied'){$category='PermissionDenied'}
            elseif($diagnostic -match 'invalid|unknown|unsupported'){$category='InvalidCommandOrObject'}
            throw "Primary read failed (exit $($child.ExitCode), category $category); credentials suppressed."
        }
        return $text
    }finally{if($psi){$psi.Environment.Clear()};if($child){$child.Dispose()};if($plain){[Array]::Clear($plain,0,$plain.Length)};$record=$null;$diagnostic=$null}
}
function Get-PrimaryFootage {
    param([string]$SnapshotId,[string]$ProjectPath)
    if($SnapshotId -cnotmatch '^[a-f0-9]{64}$'){throw 'Full source snapshot ID required.'}
    $null=Assert-AutoProjectPath $ProjectPath
    $snapshot=Invoke-PrimaryRead @('cat','snapshot',$SnapshotId)|ConvertFrom-Json
    if($snapshot.hostname -ine 'SOURCE-PC'){throw 'Source snapshot belongs to another computer.'}
    $covered=@($snapshot.paths|ForEach-Object{$p=$_.Replace('\','/');if($p -match '^([A-Za-z]):/(.*)$'){$p='/'+$Matches[1].ToUpperInvariant()+'/'+$Matches[2]};$p=$p.TrimEnd('/');if($ProjectPath -ceq $p -or $ProjectPath.StartsWith($p+'/',[StringComparison]::Ordinal)){$p}})
    if(-not $covered.Count){throw 'Requested project is outside snapshot backup roots.'}
    $cache=@{}
    function Read-Tree([string]$Path){
        if(-not $cache.ContainsKey($Path)){$cache[$Path]=Invoke-PrimaryRead @('cat','tree',($SnapshotId+':'+$Path))|ConvertFrom-Json}
        return $cache[$Path]
    }
    $nodes=[Collections.Generic.List[object]]::new()
    function Visit-Tree([string]$Path,[int]$Depth){
        if($Depth -gt 64){throw 'Project directory nesting limit exceeded.'}
        foreach($node in (Read-Tree $Path).nodes){
            if($node.name -match '[/\\:*?\[\]"<>|\r\n]' -or $node.name -match '^\.\.?$|[. ]$'){throw 'Unsafe snapshot file name.'}
            $nodePath=$Path+'/'+$node.name
            if($node.type -eq 'dir'){Visit-Tree $nodePath ($Depth+1)}
            elseif($node.type -eq 'file'){$node|Add-Member -NotePropertyName path -NotePropertyValue $nodePath -Force;$nodes.Add($node)}
            else{throw 'Links or special files in automatic projects are unsupported.'}
        }
    }
    Visit-Tree $ProjectPath 0
    return Get-AutoVideoIdentity -ProjectPath $ProjectPath -Nodes @($nodes)
}
Export-ModuleMember -Function Invoke-PrimaryRead,Get-PrimaryFootage
