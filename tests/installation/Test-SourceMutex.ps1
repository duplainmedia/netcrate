param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$repo/src/shared/NetCrate.Credentials.psm1"
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must not exist.'}
$fixturePath=[IO.Path]::GetFullPath($TestRoot)
if($fixturePath -notmatch '(?i)[\\/](temp|_temp)[\\/]' -or $fixturePath -match '(?i)OneDrive'){throw 'Use a new ordinary Temp fixture root.'}
$root=Join-Path $TestRoot 'Engine'
$null=New-NetCrateIdentity $root ('1'*32) Source
$owner=Get-NetCrateOwner $root
$runtime=Get-Content -Raw "$repo/src/shared/Invoke-NetCrateRuntime.ps1"
$schedule=Get-Content -Raw "$repo/src/shared/NetCrate.Schedule.ps1"
if($runtime -notmatch "Global\\NetCrate-Runtime-" -or $schedule -notmatch "Global\\NetCrate-Admission-" -or $schedule -notmatch 'Get-NetCrateOwner') {throw 'Source locks do not use the shared owner/installation namespace.'}
$active=Join-Path $TestRoot 'Files';$null=[IO.Directory]::CreateDirectory($active)
$module="$repo/src/shared/NetCrate.Workflow.psm1"
$hold=Join-Path $TestRoot 'hold.ps1'
[IO.File]::WriteAllText($hold,@'
param($module,$root)
Import-Module $module
& (Get-Module NetCrate.Workflow) {param($r) Invoke-NetCrateAdmissionLock $r { [IO.File]::WriteAllText("$r/held",'yes');while(-not [IO.File]::Exists("$r/release")){Start-Sleep -Milliseconds 30} }} $root
'@)
$admit=Join-Path $TestRoot 'admit.ps1'
[IO.File]::WriteAllText($admit,@'
param($module,$root,$project,$id)
Import-Module $module
$s=[pscustomobject]@{BackupMode='Folder';ActiveRoot=$project;StateRoot=$root;InstallationId=$id}
Add-NetCrateBackupQueue $root $s $project|Out-Null
'@)
function StartChild($arguments){$p=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$p.UseShellExecute=$false;$p.CreateNoWindow=$true;foreach($a in $arguments){$p.ArgumentList.Add($a)};return [Diagnostics.Process]::Start($p)}
$holder=StartChild @('-NoProfile','-File',$hold,$module,$root)
try {
 $end=[DateTime]::UtcNow.AddSeconds(20);while(-not [IO.File]::Exists("$root/held")){if([DateTime]::UtcNow -gt $end){throw 'Production admission lock did not start.'};Start-Sleep -Milliseconds 30}
 $child=StartChild @('-NoProfile','-File',$admit,$module,$root,$active,$owner.InstallationId)
 Start-Sleep -Milliseconds 800
 if($child.HasExited -or [IO.Directory]::Exists("$root/Queue")){throw 'Real admission bypassed the held production lock.'}
 [IO.File]::WriteAllText("$root/release",'yes')
 if(-not $child.WaitForExit(20000) -or $child.ExitCode -ne 0 -or @([IO.Directory]::GetFiles("$root/Queue",'*.json')).Count -ne 1){throw 'Admission did not resume after lock release.'}
} finally {[IO.File]::WriteAllText("$root/release",'yes');$holder.WaitForExit(20000)|Out-Null}
$name='Global\NetCrate-Runtime-'+$owner.UserSid+'-'+$owner.InstallationId
$mutex=[Threading.Mutex]::new($true,$name)
try {
 $runtime=StartChild @('-NoProfile','-File',"$repo/src/shared/Invoke-NetCrateRuntime.ps1",'-Root',$root,'-Once')
 if(-not $runtime.WaitForExit(20000) -or $runtime.ExitCode -ne 0 -or [IO.File]::Exists("$root/runtime-status.json")){throw 'Second source runtime bypassed the held shared mutex.'}
} finally {$mutex.ReleaseMutex();$mutex.Dispose()}
Write-Output 'PASS: production admission and runtime exclusion across independent processes in the same Windows session.'
