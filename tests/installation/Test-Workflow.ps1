param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$ResticExe,
    [Parameter(Mandatory)][string]$PythonExe, [Parameter(Mandatory)][string]$FFmpegExe, [string]$RestServerExe)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$repo/src/shared/NetCrate.Workflow.psm1" -Force
Import-Module "$repo/src/shared/NetCrate.Pairing.psm1"
Import-Module "$repo/src/shared/NetCrate.Configuration.psm1"
Import-Module "$repo/src/shared/NetCrate.Protocol.psm1"
Import-Module "$repo/src/shared/NetCrate.Credentials.psm1"
Import-Module "$repo/src/shared/NetCrate.Process.psm1"
Import-Module "$repo/install/NetCrate.Repositories.psm1"
Import-Module "$repo/install/NetCrate.Engine.psm1"
$serverProcess = $null
try {
$null = New-Item -ItemType Directory -Path $TestRoot
$source = Join-Path $TestRoot 'Editing'
$worker = Join-Path $TestRoot 'Server'
$projects = Join-Path $TestRoot 'Projects'
$storage = Join-Path $TestRoot 'Storage'
$null = New-Item -ItemType Directory -Path "$projects/First project", $storage
$null = New-NetCrateIdentity $source ('1' * 32) Source
$null = New-NetCrateIdentity $worker ('2' * 32) Worker
$binding = Initialize-NetCrateRepositories $worker $storage $ResticExe
$secrets = Get-NetCrateRepositorySecrets $worker
$tools = @{ PowerShell = (Get-Process -Id $PID).Path; Restic = $ResticExe; Python = $PythonExe; FFmpeg = $FFmpegExe; FFprobe = (Join-Path (Split-Path $FFmpegExe) 'ffprobe.exe') }
$base = @{ Version = 1; SourceComputer = 'EDITING'; WorkerComputer = 'BACKUP'; ActiveRoot = $projects; SnapshotRoot = (Get-NetCrateSnapshotRoot $projects); Recipe = 'half-prores-v2'; PollSeconds = 2; Tools = $tools
    Repositories = @{ Primary = @{ Uri = $binding.PrimaryPath; Id = $binding.PrimaryId }; Results = @{ Uri = $binding.ResultsPath; Id = $binding.ResultsId } } }
$editing = [pscustomobject]($base.Clone()); $editing | Add-Member Role Source; $editing | Add-Member InstallationId ('1' * 32); $editing | Add-Member StateRoot $source
$server = [pscustomobject]($base.Clone()); $server | Add-Member Role Worker; $server | Add-Member InstallationId ('2' * 32); $server | Add-Member StateRoot $worker
Protect-NetCrateRecord $source 'paired-secrets' $secrets
$editingKey = New-NetCrateIdentity $source ('1' * 32) Source
$serverKey = New-NetCrateIdentity $worker ('2' * 32) Worker
Protect-NetCrateRecord $source 'runtime-peer' @{ PublicKey = $serverKey.PublicKey }
Protect-NetCrateRecord $worker 'runtime-peer' @{ PublicKey = $editingKey.PublicKey }
if ($RestServerExe) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $endpoint = Initialize-NetCrateEndpoint $worker '127.0.0.1' '127.0.0.1' $tools -Fixture -Port $port
    [IO.File]::WriteAllText("$source/server.pem", $endpoint.Certificate)
    $remote = @{}
    foreach ($name in @('Primary', 'Results')) {
        $leaf = if ($name -ceq 'Primary') { 'originals' } else { 'results' }
        $uri = "rest:https://127.0.0.1:$port/editing/$leaf/"
        $remote[$name] = @{ Uri = $uri; Id = $binding.($name + 'Id') }
        $server.Repositories.$name.RemoteUri = $uri
    }
    $editing.Repositories = $remote
    $start = [Diagnostics.ProcessStartInfo]::new($RestServerExe); $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardError = $true; $start.RedirectStandardOutput = $true
    foreach ($arg in (Get-NetCrateServerArguments $worker)) { $start.ArgumentList.Add($arg) }
    $serverProcess = [Diagnostics.Process]::Start($start)
    $serverErrors = $serverProcess.StandardError.ReadToEndAsync(); $serverOutput = $serverProcess.StandardOutput.ReadToEndAsync()
    Start-Sleep -Milliseconds 500
    if ($serverProcess.HasExited) { throw $serverErrors.GetAwaiter().GetResult() }
}
New-NetCrateSample (Join-Path $projects 'First project/sample.avi')
$audio = Invoke-NetCrateProcess $FFmpegExe @('-nostdin', '-v', 'error', '-n', '-f', 'lavfi', '-i', 'testsrc2=size=64x64:rate=24:duration=2', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2', '-c:v', 'prores_ks', '-profile:v', '3', '-pix_fmt', 'yuv422p10le', '-c:a', 'pcm_s24le', '-timecode', '01:02:03:04', '-threads', '2', (Join-Path $projects 'First project/audio.mov'))
if ($audio.ExitCode -ne 0) { throw 'The generated audio fixture failed.' }
$request = Invoke-NetCrateBackup $source $editing (Join-Path $projects 'First project')
if ($request.SnapshotId -cnotmatch '^[a-f0-9]{64}$') { throw 'No complete source snapshot.' }
Invoke-NetCrateWorker $worker $server
Invoke-NetCrateReceiver $source $editing
$receipt = Get-NetCrateReceipt $source (Get-NetCrateRequestId $request.SnapshotId $request.ProjectPath $request.Recipe)
if ($receipt.State -ne 'Ready' -or -not (Test-Path -LiteralPath $receipt.LocalPath)) { throw 'The first proxy did not return.' }
Invoke-NetCrateWorker $worker $server
$acknowledged = Read-NetCrateJson (Join-Path $worker ('WorkerJobs/' + $receipt.RequestId + '.json'))
if ($acknowledged.State -cne 'Delivered') { throw 'The server did not verify the signed delivery acknowledgement.' }
$ackFile = Join-Path $source ('Acknowledged/' + $receipt.RequestId + '.json')
[IO.File]::Delete($ackFile)
$workflowModule = Get-Module NetCrate.Workflow
$savedWriter = & $workflowModule { (Get-Command Write-WorkflowRecord).ScriptBlock }
try {
    & $workflowModule { function script:Write-WorkflowRecord { param($Root, $Settings, $Kind, $Id, $Data) throw 'Synthetic acknowledgement transport interruption.' } }
    try { Invoke-NetCrateReceiver $source $editing } catch { }
} finally { & $workflowModule { param($Body) Set-Item Function:script:Write-WorkflowRecord -Value $Body } $savedWriter }
if ((Get-NetCrateReceipt $source $receipt.RequestId).State -cne 'Ready') { throw 'An offline acknowledgement hid verified local media.' }
Invoke-NetCrateReceiver $source $editing
$deliveredProxy = Get-ChildItem -LiteralPath "$($receipt.LocalPath)/Proxies" -File -Recurse | Select-Object -First 1
$deliveredBytes = [IO.File]::ReadAllBytes($deliveredProxy.FullName); [IO.File]::Delete($deliveredProxy.FullName)
Invoke-NetCrateReceiver $source $editing
if ((Get-NetCrateReceipt $source $receipt.RequestId).State -ceq 'Ready') { throw 'The receiver kept a missing delivered file ready.' }
[IO.File]::WriteAllBytes($deliveredProxy.FullName, $deliveredBytes)
Invoke-NetCrateReceiver $source $editing
if ((Get-NetCrateReceipt $source $receipt.RequestId).State -cne 'Ready') { throw 'Restored delivery did not pass fresh verification.' }
$first = $receipt.ResultSnapshotId
$again = Invoke-NetCrateBackup $source $editing (Join-Path $projects 'First project')
Invoke-NetCrateWorker $worker $server
Invoke-NetCrateReceiver $source $editing
$reused = Get-NetCrateReceipt $source (Get-NetCrateRequestId $again.SnapshotId $again.ProjectPath $again.Recipe)
if ($reused.GenerationSnapshotId -ne $request.SnapshotId -or $reused.RequestedSnapshotId -ne $again.SnapshotId -or $reused.ResultSnapshotId -ne $first) { throw 'Unchanged footage did not reuse a verified generation.' }
if (-not (Test-Path -LiteralPath $receipt.LocalPath)) { throw 'A previous proxy version was removed.' }
$editing.Recipe = 'quarter-prores-v1'
$queueFile = Add-NetCrateBackupQueue $source $editing (Join-Path $projects 'First project')
$legacyQueue=Read-NetCrateJson $queueFile
$legacyQueue.PSObject.Properties.Remove('BackupMode');$legacyQueue.PSObject.Properties.Remove('BackupCompletedUtc');$legacyQueue.PSObject.Properties.Remove('MediaState')
Write-NetCrateJson $queueFile $legacyQueue
$resultUri = $editing.Repositories.Results.Uri
$editing.Repositories.Results.Uri = Join-Path $TestRoot 'offline-results'
Invoke-NetCrateQueue $source $editing
$interrupted = Read-NetCrateJson $queueFile
if ($interrupted.State -ne 'NeedsAttention' -or $interrupted.SnapshotId -cnotmatch '^[a-f0-9]{64}$') { throw 'A failed request delivery lost its successful backup checkpoint.' }
if (-not $interrupted.BackupCompletedUtc -or $interrupted.BackupMode -cne 'Media' -or $interrupted.MediaState -cne 'NeedsAttention') { throw 'A media publication failure discarded the original completion time or failed to report media separately.' }
$editing.Repositories.Results.Uri = $resultUri
$interrupted.RetryAfterUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o'); Write-NetCrateJson $queueFile $interrupted
Invoke-NetCrateQueue $source $editing
$queued = Read-NetCrateJson $queueFile
if ($queued.State -ne 'WaitingForProxies' -or $queued.SnapshotId -cne $interrupted.SnapshotId) { throw 'Retry made another backup instead of resuming its saved snapshot.' }
if ($queued.BackupCompletedUtc -cne $interrupted.BackupCompletedUtc -or $queued.MediaState -cne 'Pending') { throw 'Retry changed the original completion time or failed to resume media.' }
Invoke-NetCrateWorker $worker $server
Invoke-NetCrateReceiver $source $editing
Update-NetCrateQueue $source $editing
$finished = Read-NetCrateJson $queueFile
if ($finished.State -ne 'Ready') { throw 'The queued backup did not finish.' }
$quarter = Get-NetCrateReceipt $source $finished.RequestId
if ($quarter.ResultSnapshotId -ceq $first -or $quarter.Recipe -cnotlike 'quarter-prores-v1|*' -or -not (Test-Path -LiteralPath $receipt.LocalPath)) { throw 'A recipe change reused or removed a previous generation.' }
$extra = Join-Path $quarter.LocalPath 'undeclared.txt'; [IO.File]::WriteAllText($extra, 'test')
$rejected = $false; try { Test-WorkflowResult $quarter.LocalPath $quarter.Association | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Undeclared result files were accepted.' }; [IO.File]::Delete($extra)
$proxy = Get-ChildItem -LiteralPath "$($quarter.LocalPath)/Proxies" -File -Recurse | Select-Object -First 1
$before = [IO.File]::ReadAllBytes($proxy.FullName); [IO.File]::WriteAllText($proxy.FullName, 'tampered')
$rejected = $false; try { Test-WorkflowResult $quarter.LocalPath $quarter.Association | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'A corrupt proxy was accepted.' }; [IO.File]::WriteAllBytes($proxy.FullName, $before)
Write-Output 'PASS: native media round trip, reuse, changed recipe, offline request retry, durable queue, version preservation and tamper rejection.'
} finally {
    if ($serverProcess) {
        if (-not $serverProcess.HasExited) { $serverProcess.Kill($true) }; $serverProcess.WaitForExit(); $serverProcess.Dispose()
        [IO.File]::WriteAllText("$worker/transport-test.log", $serverErrors.GetAwaiter().GetResult())
    }
}
