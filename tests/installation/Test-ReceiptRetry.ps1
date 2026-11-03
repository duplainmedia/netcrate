param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$ResticExe, [Parameter(Mandatory)][string]$PythonExe, [Parameter(Mandatory)][string]$RestServerExe)
$ErrorActionPreference = 'Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must not exist.'}
$fixturePath=[IO.Path]::GetFullPath($TestRoot)
if($fixturePath -notmatch '(?i)[\\/](temp|_temp)[\\/]' -or $fixturePath -match '(?i)OneDrive'){throw 'Use a new ordinary Temp fixture root.'}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach ($name in @('Workflow','Configuration','Credentials','Protocol','Pairing')) { Import-Module "$repo/src/shared/NetCrate.$name.psm1" }
Import-Module "$repo/install/NetCrate.Repositories.psm1"
$script:assertions = 0
function Assert($value,$message) { if (-not $value) { throw $message }; $script:assertions++ }
function Reject([scriptblock]$action) { $bad=$false; try { & $action | Out-Null } catch { $bad=$true }; Assert $bad 'Unsafe or incomplete input was accepted.' }
$null = New-Item -ItemType Directory -Path $TestRoot
$source=Join-Path $TestRoot 'Engine'; $worker=Join-Path $TestRoot 'Worker'; $active=Join-Path $TestRoot 'Files'
$null=New-Item -ItemType Directory -Path "$active/Notes/Proxies/NetCrate", "$TestRoot/Storage"
$null=New-NetCrateIdentity $source ('1'*32) Source
$null=New-NetCrateIdentity $worker ('2'*32) Worker
$binding=Initialize-NetCrateRepositories $worker "$TestRoot/Storage" $ResticExe
Protect-NetCrateRecord $source paired-secrets (Get-NetCrateRepositorySecrets $worker)
$settings=[pscustomobject]@{Version=1; Role='Source'; InstallationId=('1'*32); BackupMode='Folder'; SourceComputer='SOURCE'; WorkerComputer='SERVER'; ActiveRoot=$active; StateRoot=$source
 SnapshotRoot=(Get-NetCrateSnapshotRoot $active); Recipe='half-prores-v2'; PollSeconds=2; Tools=@{Restic=$ResticExe;PowerShell=(Get-Process -Id $PID).Path}; Repositories=@{Primary=@{Uri=$binding.PrimaryPath;Id=$binding.PrimaryId};Results=@{Uri="$TestRoot/offline";Id=$binding.ResultsId}}}
$file="$active/Notes/Proxies/NetCrate/ordinary.txt"; [IO.File]::WriteAllText($file,'ordinary proxy-named folder bytes æ—¥æœ¬èªž')
# Exercise the actual file-only desktop action bridge. Queueing does not contact
# transport; use syntactically valid private endpoints and then run the queued job
# against this fixture's local repositories below.
$bridge=$settings.PSObject.Copy();$bridge.Repositories=@{Primary=@{Uri='rest:https://backup.example:8200/editing/originals/';Id=$binding.PrimaryId};Results=@{Uri='rest:https://backup.example:8200/editing/results/';Id=$binding.ResultsId}}
Write-NetCrateJson "$source/settings.json" $bridge
Write-NetCrateJson "$source/prepared.json" @{Version=1;Role='Source';InstallationId=('1'*32);Folder=$active;BackupMode='Folder'}
$inputFile="$TestRoot/Setup/action.json"
$inputState=@{Version=1;Role='EditingComputer';InstallationId=('3'*32);Folder=$active;BackupMode='Folder';Path="$active/Notes"}
Write-NetCrateJson $inputFile $inputState
$result=& $settings.Tools.PowerShell -NoLogo -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action QueueBackup -InputFile $inputFile | ConvertFrom-Json
Assert (-not $result.Succeeded -and -not [IO.Directory]::Exists("$source/Queue")) 'The action bridge accepted another installation identity.'
$inputState.InstallationId='1'*32;Write-NetCrateJson $inputFile $inputState
$result=& $settings.Tools.PowerShell -NoLogo -NoProfile -File "$repo/install/Invoke-SetupAction.ps1" -Action QueueBackup -InputFile $inputFile | ConvertFrom-Json
Assert $result.Succeeded 'The ordinary manual folder could not be queued through the desktop action bridge.'
$queue=@([IO.Directory]::EnumerateFiles("$source/Queue",'*.json'))[0]

Import-Module "$repo/install/NetCrate.Engine.psm1"
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$tools=@{PowerShell=$settings.Tools.PowerShell;Restic=$ResticExe;Python=$PythonExe;RestServer=$RestServerExe}
$endpoint=Initialize-NetCrateEndpoint $worker '127.0.0.1' '127.0.0.1' $tools -Fixture -Port $port
[IO.File]::WriteAllText("$source/server.pem",$endpoint.Certificate)
$settings.Repositories=@{Primary=@{Uri="rest:https://127.0.0.1:$port/editing/originals/";Id=$binding.PrimaryId};Results=@{Uri="rest:https://127.0.0.1:$port/editing/results/";Id=$binding.ResultsId}}
$start=[Diagnostics.ProcessStartInfo]::new($RestServerExe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($arg in (Get-NetCrateServerArguments $worker)){$start.ArgumentList.Add($arg)}
$server=[Diagnostics.Process]::Start($start);$out=$server.StandardOutput.ReadToEndAsync();$err=$server.StandardError.ReadToEndAsync()
try {
 Start-Sleep -Milliseconds 500;if($server.HasExited){throw 'Fixture endpoint did not start.'}
# Fault after native originals are checkpointed but before publishing the Primary receipt.
& (Get-Module NetCrate.Workflow) {
 param($root,$settings)
 $saved=(Get-Command Write-NetCrateBackupReceipt).ScriptBlock
 try {function script:Write-NetCrateBackupReceipt {throw 'fixture receipt fault'}; Invoke-NetCrateQueue $root $settings}
 finally {Set-Item Function:script:Write-NetCrateBackupReceipt $saved}
} $source $settings
$failed=Read-NetCrateJson $queue
Assert ($failed.State -ceq 'NeedsAttention' -and $failed.SnapshotId -cmatch '^[a-f0-9]{64}$' -and $failed.ReceiptConfirmed -eq $false) 'Receipt failure did not retain an unconfirmed original.'
$recovery="$TestRoot/recovery.json";$secrets=Get-NetCrateRepositorySecrets $worker
Write-NetCrateJson $recovery @{Version=1;Kind='netcrate-recovery';InstallationId=('2'*32);CreatedUtc=[DateTime]::UtcNow.ToString('o');Primary=@{Id=$binding.PrimaryId;Path=$binding.PrimaryPath;Password=$secrets.PrimaryPassword};Results=@{Id=$binding.ResultsId;Path=$binding.ResultsPath;Password=$secrets.ResultsPassword};Instructions='fixture'}
Import-Module "$repo/src/shared/NetCrate.Restore.psm1"
$request=[pscustomobject]@{RecoveryFile=$recovery;RepositoryPath=$binding.PrimaryPath}
$hidden=Invoke-NetCrateRestoreAction ListBackups $request "$TestRoot/Fresh" $ResticExe
Assert (@($hidden.Items).Count -eq 0) 'An unreceipted backup appeared in recovery.'
$failed.RetryAfterUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o');Write-NetCrateJson $queue $failed
Invoke-NetCrateQueue $source $settings
$done=Read-NetCrateJson $queue
Assert ($done.State -ceq 'Ready' -and $done.ReceiptConfirmed -eq $true -and $done.SnapshotId -ceq $failed.SnapshotId) 'Receipt retry changed the original or failed to confirm it.'
$shown=Invoke-NetCrateRestoreAction ListBackups $request "$TestRoot/Fresh" $ResticExe
Assert (@($shown.Items).Count -eq 1 -and $shown.Items[0].SnapshotId -ceq $failed.SnapshotId) 'Recovery did not expose the same receipted snapshot.'
Assert (@(Invoke-WorkflowRestic $source $settings Primary @('snapshots','--json','--tag','netcrate-folder-originals')|ConvertFrom-Json).Count -eq 1) 'Receipt retry created duplicate originals.'
Write-Output 'PASS: receipt fault, hidden recovery point and retry of same native snapshot.'

} finally {if(-not $server.HasExited){$server.Kill($true)};$server.WaitForExit();$server.Dispose()}
