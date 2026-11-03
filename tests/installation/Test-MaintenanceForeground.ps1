#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe,[Parameter(Mandatory)][string]$PythonExe,[Parameter(Mandatory)][string]$RestServerExe,[string]$RepoRoot,[string]$HelperSource)
$ErrorActionPreference='Stop'
if([IO.File]::Exists($TestRoot) -or [IO.Directory]::Exists($TestRoot)){throw 'TestRoot must be a new directory.'}
$full=[IO.Path]::GetFullPath($TestRoot)
if($full -notmatch '(?i)[\\/]NC5-[a-f0-9]{8}$'){throw 'Choose a fresh NC5 fixture root.'}
if(-not $RepoRoot){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))}
if(-not $HelperSource){$HelperSource=Join-Path $RepoRoot 'tests/desktop/MaintenanceForegroundFixture.cs'}
$repo=[IO.Path]::GetFullPath($RepoRoot)
foreach($tool in @($ResticExe,$PythonExe,$RestServerExe,$HelperSource)){if(-not [IO.File]::Exists($tool)){throw 'A pinned fixture tool or helper source is missing.'}}
foreach($name in @('Configuration','Credentials','Workflow','Protocol','Maintenance')){Import-Module "$repo/src/shared/NetCrate.$name.psm1"}
Import-Module "$repo/install/NetCrate.Repositories.psm1"
Import-Module "$repo/install/NetCrate.Engine.psm1" -DisableNameChecking
$null=Assert-NetCrateLocalPath $full
$root=[IO.Path]::Combine($full,'Engine');$sourceRoot=[IO.Path]::Combine($full,'SourceEngine');$storage=[IO.Path]::Combine($full,'Storage');$files=[IO.Path]::Combine($full,'Files');$setup=[IO.Path]::Combine($full,'Setup');$bridge=[IO.Path]::Combine($full,'Bridge')
$null=New-Item -ItemType Directory -Path $storage,$files,$bridge
$id='8'*32;$sourceId='9'*32
$null=New-NetCrateIdentity $root $id Worker;$identity=New-NetCrateIdentity $sourceRoot $sourceId Source
$binding=Initialize-NetCrateRepositories $root $storage $ResticExe
Write-NetCrateJson "$full/fixture.json" @{Version=1;Root=$full;InstallationId=$id;PrimaryId=$binding.PrimaryId;ResultsId=$binding.ResultsId}
Protect-NetCrateRecord $sourceRoot paired-secrets (Get-NetCrateRepositorySecrets $root)
Protect-NetCrateRecord $root runtime-peer @{PublicKey=$identity.PublicKey}
Protect-NetCrateRecord $root inbound-request @{Request=@{RequestId=('a'*32);RecipientId=$sourceId}}
$pwsh=(Get-Process -Id $PID).Path
$tools=@{Restic=$ResticExe;PowerShell=$pwsh;RestServer=$RestServerExe;Python=$PythonExe}
$worker=[pscustomobject]@{Version=1;Role='Worker';InstallationId=$id;BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='SERVER';ActiveRoot=$files;StateRoot=$root;Recipe='half-prores-v2';PollSeconds=2;Tools=$tools;Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri=$binding.ResultsPath;Id=$binding.ResultsId}}}
$source=[pscustomobject]@{Role='Source';InstallationId=$sourceId;BackupMode='Folder';SourceComputer='SOURCE';WorkerComputer='SERVER';ActiveRoot=$files;StateRoot=$sourceRoot;SnapshotRoot=(Get-NetCrateSnapshotRoot $files);Recipe='half-prores-v2';PollSeconds=2;Tools=@{Restic=$ResticExe};Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri=$binding.ResultsPath;Id=$binding.ResultsId}}}
Write-NetCrateJson "$root/settings.json" $worker
Write-NetCrateJson "$root/prepared.json" @{Version=1;Role='Worker';InstallationId=$id;Folder=$storage;BackupMode='Folder'}
$ack=[ordered]@{Version=1;Kind='pairing-ack';RequestId=('a'*32);SourceId=$sourceId;ServerId=$id}
Write-WorkflowRecord $sourceRoot $source pairing-ack (Get-NetCrateHash ('a'*32)) $ack
$versions=@();$hashes=@()
foreach($value in @('foreground-old','foreground-new')){
 [IO.File]::WriteAllText("$files/version.txt",$value);$hashes+=(Get-FileHash "$files/version.txt" -Algorithm SHA256).Hash
 $versions+=Invoke-NetCrateOriginals $sourceRoot $source $files '' Folder
}
function Assert-ForegroundFixture {
 $marker=Read-NetCrateJson "$full/fixture.json"
 if($marker.Version -ne 1 -or $marker.Root -cne $full -or $marker.InstallationId -cne $id -or $marker.PrimaryId -cne $binding.PrimaryId -or $marker.ResultsId -cne $binding.ResultsId){throw 'The fixture marker changed.'}
 $context=Get-NetCrateMaintenanceContext $root $id
 if($context.Binding.PrimaryId -cne $marker.PrimaryId -or $context.Binding.ResultsId -cne $marker.ResultsId -or -not $context.Binding.RepositoryRoot.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The fixture repository guard failed.'}
 return $context
}
$null=Assert-ForegroundFixture
$beforePrimary=@(Invoke-WorkflowRestic $root $worker Primary @('snapshots','--json')|ConvertFrom-Json)
$beforeResults=@(Invoke-WorkflowRestic $root $worker Results @('snapshots','--json')|ConvertFrom-Json)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$null=Initialize-NetCrateEndpoint $root '127.0.0.1' '127.0.0.1' $tools -Fixture -Port $port
$inputFile="$setup/action.json"
Write-NetCrateJson $inputFile @{Version=1;Role='BackupServer';InstallationId=$id;Policy='KeepLatestPerFolder';Count=1}
$reply=& $pwsh -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action PreviewRetention -InputFile $inputFile|ConvertFrom-Json
if(-not $reply.Succeeded -or $reply.OperationId -cnotmatch '^[a-f0-9]{32}$'){throw 'The fixture preview was not queued.'}
& $pwsh -NoProfile -File "$repo/src/shared/Invoke-NetCrateRuntime.ps1" -Root $root -Once
if($LASTEXITCODE -ne 0){throw 'The fixture preview worker exited unsuccessfully.'}
$previewOperation=Read-NetCrateJson "$root/Maintenance/Requests/$($reply.OperationId).json"
if($previewOperation.State -cne 'Succeeded'){throw 'The fixture preview did not complete.'}
$preview=Read-NetCrateJson "$root/Maintenance/Previews/$($previewOperation.PreviewId).json"
if(@($preview.Candidates).Count -ne 1 -or $preview.Candidates[0] -cne $versions[0].SnapshotId){throw 'The preview did not select the generated older version.'}
# WindowsSetupService uses Windows PowerShell; this fixture-only relay starts the
# pinned PowerShell 7 for the real action script and preserves its input path.
$relay=@"
param(`$Action,`$InputFile)
if(`$Action -cnotin @('StorageStatus','ApplyRetention')){throw 'Unexpected fixture action.'}
& '$pwsh' -NoProfile -File '$repo/install/Invoke-SetupAction.ps1' -Action `$Action -InputFile `$InputFile
exit `$LASTEXITCODE
"@
[IO.File]::WriteAllText("$bridge/Invoke-SetupAction.ps1",$relay,[Text.UTF8Encoding]::new($false))
$framework=[IO.Path]::Combine($env:WINDIR,'Microsoft.NET','Framework64','v4.0.30319');$wpf=[IO.Path]::Combine($framework,'WPF');$compiler=[IO.Path]::Combine($framework,'csc.exe');$helper=[IO.Path]::Combine($full,'MaintenanceForegroundFixture.exe')
$sourceFiles=@('src/desktop/setup/SetupState.cs','src/desktop/setup/ISetupService.cs','src/desktop/setup/JsonSetupStore.cs','src/desktop/setup/InspectionProcess.cs','src/desktop/setup/WindowsSetupService.cs','src/desktop/MaintenanceView.cs'|ForEach-Object {[IO.Path]::GetFullPath((Join-Path $repo $_))})+@([IO.Path]::GetFullPath($HelperSource))
$references=@('/r:System.Web.Extensions.dll',('/r:'+[IO.Path]::Combine($wpf,'PresentationFramework.dll')),('/r:'+[IO.Path]::Combine($wpf,'PresentationCore.dll')),('/r:'+[IO.Path]::Combine($wpf,'WindowsBase.dll')),('/r:'+[IO.Path]::Combine($wpf,'UIAutomationProvider.dll')),('/r:'+[IO.Path]::Combine($wpf,'UIAutomationTypes.dll')),('/r:'+[IO.Path]::Combine($framework,'System.Xaml.dll')))
& $compiler /nologo /codepage:65001 /target:exe "/out:$helper" @references @sourceFiles
if($LASTEXITCODE -ne 0){throw 'The foreground helper did not compile.'}
$markerPath=[IO.Path]::Combine($full,'window-closed.json');$start=[Diagnostics.ProcessStartInfo]::new($helper);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($argument in @($bridge,$setup,$id,"$root/Maintenance/Requests",$markerPath)){$start.ArgumentList.Add($argument)}
$foreground=[Diagnostics.Process]::Start($start);$stdout=$foreground.StandardOutput.ReadToEndAsync();$stderr=$foreground.StandardError.ReadToEndAsync()
try {
 if(-not $foreground.WaitForExit(120000)){throw 'The foreground helper did not close in time.'}
 $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
 if($foreground.ExitCode -ne 0){throw ('The foreground helper failed: '+$errorText)}
 Write-Output $text.Trim()
} finally {if(-not $foreground.HasExited){$foreground.Kill($true);$foreground.WaitForExit()};$foreground.Dispose()}
$closed=Read-NetCrateJson $markerPath
if($closed.WindowClosed -ne $true -or $closed.State -cne 'Queued' -or $closed.OperationId -cnotmatch '^[a-f0-9]{32}$'){throw 'The real window did not close after queuing retention.'}
$operationPath="$root/Maintenance/Requests/$($closed.OperationId).json";$queued=Read-NetCrateJson $operationPath
if($queued.Action -cne 'ApplyRetention' -or $queued.State -cne 'Queued' -or $queued.PreviewId -cne $preview.PreviewId -or $queued.Confirm -ne $true){throw 'The queued operation was not the confirmed preview.'}
Write-Output 'PASS: confirmed ApplyRetention remained queued after the foreground window and process exited.'
# Recheck fixture owner, paths and actual IDs immediately before the worker may
# execute the exact reviewed deletion; no production repository is accepted.
$null=Assert-ForegroundFixture
& $pwsh -NoProfile -File "$repo/src/shared/Invoke-NetCrateRuntime.ps1" -Root $root -Once
if($LASTEXITCODE -ne 0){throw 'The background fixture worker exited unsuccessfully.'}
$operation=Read-NetCrateJson $operationPath
if($operation.State -cne 'Succeeded' -or $operation.Step -cne 'Completed'){throw 'Retention did not reach a successful terminal state after the UI closed.'}
$afterPrimary=@(Invoke-WorkflowRestic $root $worker Primary @('snapshots','--json')|ConvertFrom-Json)
$expected=@($beforePrimary|Where-Object {$_.id -cne $versions[0].SnapshotId}|ForEach-Object {$_.id}|Sort-Object)
$actual=@($afterPrimary|ForEach-Object {$_.id}|Sort-Object)
if(($expected -join ',') -cne ($actual -join ',') -or @($afterPrimary|Where-Object id -CEQ $versions[1].SnapshotId).Count -ne 1){throw 'Retention changed snapshots outside the reviewed fixture candidate.'}
$afterResults=@(Invoke-WorkflowRestic $root $worker Results @('snapshots','--json')|ConvertFrom-Json)
if(($beforeResults|ConvertTo-Json -Depth 20 -Compress) -cne ($afterResults|ConvertTo-Json -Depth 20 -Compress)){throw 'The Results fixture changed.'}
$restore=[IO.Path]::Combine($full,'Restore');$null=Invoke-WorkflowRestic $root $worker Primary @('restore',($versions[1].SnapshotId+':'+(Get-NetCrateSnapshotRoot $files)),'--target',$restore,'--verify')
if((Get-FileHash "$restore/version.txt" -Algorithm SHA256).Hash -cne $hashes[1]){throw 'The retained fixture did not restore its original bytes.'}
Write-Output 'PASS: after window/process exit, worker completed retention, exact inventory and Results remained correct, and retained bytes hash-matched.'
