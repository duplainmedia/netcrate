param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach ($name in @('Configuration', 'Credentials', 'Process', 'Workflow')) { Import-Module "$repo/src/shared/NetCrate.$name.psm1" }
Import-Module "$repo/install/NetCrate.Engine.psm1"
$failures = [Collections.Generic.List[string]]::new()
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Output "PASS: $Name" } catch { $failures.Add($Name + ': ' + $_.Exception.Message); Write-Output "FAIL: $Name" }
}
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
$root = Join-Path $TestRoot 'Engine'
$null = New-NetCrateIdentity $root ('6' * 32) Source
$windowsPowerShell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$tools = @{ PowerShell = $windowsPowerShell; Restic = $windowsPowerShell }
Write-NetCrateJson "$root/tools.json" $tools
Write-NetCrateJson "$root/prepared.json" @{ Version = 1; Role = 'Source'; InstallationId = ('6' * 32); Folder = (Join-Path $TestRoot 'Folder A') }
$state = [pscustomobject]@{ InstallationId = ('6' * 32); Role = 'EditingComputer'; Folder = (Join-Path $TestRoot 'Folder B'); NetworkAddress = '' }
Check 'inspection rejects changed folder' {
    $rejected = $false; try { $r = Invoke-NetCrateSetupAction Inspect $state $root $repo; $rejected = -not $r.Succeeded } catch { $rejected = $true }
    Assert $rejected 'Inspection silently accepted a different folder.'
}
Check 'inspection rejects changed role' {
    $state.Folder = Join-Path $TestRoot 'Folder A'; $state.Role = 'BackupServer'
    $rejected = $false; try { $r = Invoke-NetCrateSetupAction Inspect $state $root $repo; $rejected = -not $r.Succeeded } catch { $rejected = $true }
    Assert $rejected 'Inspection silently accepted a different role.'
}
$app = Join-Path $root 'App'; $null = New-Item -ItemType Directory -Path "$app/src/shared", "$app/install" -Force
Check 'inspection rejects a mode change from a legacy prepared installation' {
    $state.Role='EditingComputer'; $state | Add-Member BackupMode Folder -Force
    $rejected=$false;try{$r=Invoke-NetCrateSetupAction Inspect $state $root $repo;$rejected=-not $r.Succeeded}catch{$rejected=$true}
    Assert $rejected 'Repair silently converted a legacy Media installation into Folder.'
    $state.BackupMode='Media'
}
Check 'owned task launches under a restricted parent policy' {
    $marker = Join-Path $TestRoot 'task-ran.txt'
    [IO.File]::WriteAllText("$app/src/shared/Invoke-NetCrateRuntime.ps1", ('param([string]$Root) [IO.File]::WriteAllText(''' + $marker + ''',''ran'')'))
    $launch = Get-NetCrateTaskLaunch $root $tools
    $result = Invoke-NetCrateProcess $launch.FilePath $launch.Arguments @{ PSExecutionPolicyPreference = 'Restricted' } 15
    Assert ($result.ExitCode -eq 0 -and [IO.File]::Exists($marker)) 'The owned task did not start under a restricted parent policy.'
}
Check 'elevation uses a public interpreter and self-contained non-secret helper' {
    $marker = Join-Path $TestRoot 'firewall-helper-ran.txt'
    [IO.File]::WriteAllText("$app/install/Set-NetCrateFirewall.ps1", ('param($InstallationId,$LocalAddress,$SourceAddress,$Program) [IO.File]::WriteAllText(''' + $marker + ''',$InstallationId)'))
    Write-NetCrateJson "$root/endpoint.json" @{ Address = '10.44.0.1'; SourceAddress = '10.44.0.2'; Port = 8200 }
    $tools.RestServer = Join-Path $root 'Tools/RestServer/rest-server.exe'; Write-NetCrateJson "$root/tools.json" $tools
    $launch = Get-NetCrateFirewallLaunch $root
    Assert (-not $launch.FilePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) 'The elevated interpreter requires access to the private engine.'
    $result = Invoke-NetCrateProcess $launch.FilePath $launch.Arguments @{} 15
    Assert ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText($marker) -ceq ('6' * 32)) 'The self-contained helper did not receive its non-secret binding.'
}
Check 'installed application repair avoids copying onto itself' {
    [IO.File]::WriteAllText("$app/NetCrate.exe", 'synthetic application')
    Copy-NetCrateApplication $app $app
    Assert ([IO.File]::ReadAllText("$app/NetCrate.exe") -ceq 'synthetic application') 'In-place preparation changed the running application.'
}
Check 'separate administrator can read only the public installer staging area' {
    $cache = Get-NetCrateInstallerCache $root
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($cache))
    $admin = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -ceq 'S-1-5-32-544' -and $_.AccessControlType -eq 'Allow' })
    Assert ($admin.Count -eq 1 -and ($admin[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute -and
        ($admin[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0) 'The administrator cannot read the non-secret installer, or can write it.'
}
Check 'sample resumes after interrupted creation' {
    $settings = [pscustomobject]@{ InstallationId = ('6' * 32); ActiveRoot = (Join-Path $TestRoot 'Projects'); SnapshotRoot = (Get-NetCrateSnapshotRoot (Join-Path $TestRoot 'Projects')) }
    $module = Get-Module NetCrate.Workflow
    $definition = & $module { (Get-Command New-NetCrateSample).ScriptBlock }
    try {
        & $module { function script:New-NetCrateSample { param($LiteralPath) throw 'Synthetic interrupted copy.' } }
        try { Add-NetCrateBackupQueue $root $settings -Sample | Out-Null } catch { }
    } finally { & $module { param($Body) Set-Item Function:script:New-NetCrateSample -Value $Body } $definition }
    $path = Add-NetCrateBackupQueue $root $settings -Sample
    Assert ([IO.File]::Exists($path)) 'The sample did not resume from its owned partial folder.'
}
Check 'accepted media failure updates only media state' {
    $id='9'*64;$snapshot='8'*64;$completed='2026-11-02T20:00:00Z'
    $path="$root/Queue/media-progress.json"
    Write-NetCrateJson $path @{Version=1;Id='media-progress';Project=(Join-Path $TestRoot 'Projects/A');BackupMode='Media';SnapshotId=$snapshot;BackupCompletedUtc=$completed;MediaState='Pending';State='WaitingForProxies';RequestId=$id;UpdatedUtc=$completed}
    Write-NetCrateJson "$root/JobProgress/$id.json" @{SnapshotId=$snapshot;State='NeedsAttention'}
    Update-NetCrateQueue $root ([pscustomobject]@{})
    $status=Read-NetCrateJson $path
    Assert ($status.MediaState -ceq 'NeedsAttention' -and $status.SnapshotId -ceq $snapshot -and ([DateTimeOffset]$status.BackupCompletedUtc).UtcDateTime -eq ([DateTimeOffset]$completed).UtcDateTime) 'Media failure did not retain the successful original and update media state.'
}
Check 'repaired verified media clears stale attention without rewriting stable queue' {
    $id='7'*64;$snapshot='6'*64;$completed='2026-11-02T20:00:00Z';$path="$root/Queue/media-repaired.json"
    Write-NetCrateJson $path @{Version=1;Id='media-repaired';Project=(Join-Path $TestRoot 'Projects/A');BackupMode='Media';SnapshotId=$snapshot;BackupCompletedUtc=$completed;MediaState='Ready';State='Ready';RequestId=$id;UpdatedUtc=$completed}
    Write-NetCrateJson "$root/Receipts/$id.json" @{State='NeedsAttention'}
    Write-NetCrateJson "$root/JobProgress/$id.json" @{SnapshotId=$snapshot;State='NeedsAttention'}
    Update-NetCrateQueue $root ([pscustomobject]@{})
    Assert ((Read-NetCrateJson $path).MediaState -ceq 'NeedsAttention') 'Missing delivered media was not marked unavailable.'
    Write-NetCrateJson "$root/Receipts/$id.json" @{State='Ready'}
    Update-NetCrateQueue $root ([pscustomobject]@{})
    $repaired=Read-NetCrateJson $path
    Assert ($repaired.State -ceq 'Ready' -and $repaired.MediaState -ceq 'Ready' -and $repaired.SnapshotId -ceq $snapshot) 'Verified repaired files stayed in attention or stale progress overrode them.'
    $sentinel=[DateTime]::new(2026,1,1,0,0,0,[DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($path,$sentinel);$before=[IO.File]::ReadAllText($path)
    Update-NetCrateQueue $root ([pscustomobject]@{})
    Assert ([IO.File]::GetLastWriteTimeUtc($path) -eq $sentinel -and [IO.File]::ReadAllText($path) -ceq $before) 'Unchanged media state rewrote the queue.'
}
if ($failures.Count) { $failures | Write-Output; exit 1 }
