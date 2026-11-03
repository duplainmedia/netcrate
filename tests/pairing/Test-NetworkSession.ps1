#requires -Version 7.4
param([string]$TestRoot=(Join-Path $env:TEMP ('NC-session-'+[guid]::NewGuid().ToString('N').Substring(0,8))))
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Choose a new disposable TestRoot.'}
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$module=Join-Path $repo 'install/NetCrate.NetworkSetup.psm1'
if(-not (Test-Path $module)){throw 'The network setup session is missing.'}
Import-Module $module -Force -DisableNameChecking
Import-Module (Join-Path $repo 'src/shared/NetCrate.Credentials.psm1')
Import-Module (Join-Path $repo 'src/shared/NetCrate.Configuration.psm1')
function Assert($c,$m){if(-not $c){throw $m}}
function Reject([scriptblock]$f){try{& $f|Out-Null}catch{return};throw 'Invalid session unexpectedly accepted.'}
$root=Join-Path $TestRoot Engine
$state=[pscustomobject]@{Role='BackupServer';Folder=(Join-Path $TestRoot Storage);BackupMode='Folder';InstallationId='1'*32;NetworkAddress=''}
$null=New-NetCrateIdentity $root $state.InstallationId Worker
Write-NetCrateJson (Join-Path $root prepared.json) @{Role='Worker';Folder=$state.Folder;BackupMode='Folder';InstallationId=$state.InstallationId}
Write-NetCrateJson (Join-Path $root tools.json) @{PowerShell=(Get-Process -Id $PID).Path;Restic=(Get-Process -Id $PID).Path}
$ctx=New-NetCrateNetworkContext $root $state
$status=Get-NetCrateNetworkStatus $ctx
Assert ($status.Phase -ceq 'Idle' -and -not $status.ComparisonCode) 'Resume reopened a listener or restored an unverified code.'
Reject {Start-NetCrateNetworkSession $ctx ([pscustomobject]@{ApproveFirewall=$false;LocalAddress='100.64.0.1';PeerAddress='100.64.0.2';StartAgain=$false})}
Reject {Start-NetCrateNetworkSession $ctx ([pscustomobject]@{ApproveFirewall=$true;LocalAddress='0.0.0.0';PeerAddress='100.64.0.2';StartAgain=$false})}
$peers=ConvertFrom-NetCrateNetBirdStatus '{"cliVersion":"0.81.3","netbirdIp":"100.64.0.1/16","peers":{"details":[{"fqdn":"source.example","netbirdIp":"100.64.0.2","status":"Connected","publicKey":"never forward"},{"fqdn":"public","netbirdIp":"8.8.8.8","status":"Connected"}]}}'
Assert ($peers.Peers.Count -eq 1 -and $peers.LocalAddress -ceq '100.64.0.1' -and $peers.Peers[0].Address -ceq '100.64.0.2') 'Discovery failed to filter selected private peers.'
Assert (($peers|ConvertTo-Json -Depth 6) -notmatch 'never forward|publicKey') 'Discovery leaked CLI metadata.'
Stop-NetCrateNetworkSession $ctx
Assert ((Get-NetCrateNetworkStatus $ctx).Phase -ceq 'Idle') 'Stop retained an active lease.'
Write-Output 'PASS read-only resume, approval gate, public address rejection, pinned NetBird parsing, stop.'

# Exercise the real private owner/guardian pipes. The stand-in acknowledges
# the lease and closes its stream without starting an elevated process.
$pipeName='nc-fixture-'+[guid]::NewGuid().ToString('N')
$desktop=[IO.Pipes.NamedPipeServerStream]::new($pipeName,'InOut',1,'Byte','Asynchronous')
$owner=[IO.Pipes.NamedPipeClientStream]::new('.',$pipeName,'InOut','Asynchronous')
$simulation=[PowerShell]::Create()
$release=[Threading.ManualResetEventSlim]::new($false)
$ctx.LeaseId=[guid]::NewGuid().ToString('N')
try {
    $null=$simulation.AddScript({param($desktop,$lease,$release)
        $ErrorActionPreference='Stop'
        $desktop.WaitForConnection()
        $message=[NetCrate.SetupWire]::Read($desktop,5000) | ConvertFrom-Json
        if($message.Kind -cne 'OpenLease' -or $message.Lease -cne $lease -or @($message.PSObject.Properties).Count -ne 2){throw 'Unexpected lease request fields.'}
        [NetCrate.SetupWire]::Write($desktop,(@{Kind='Guardian';Lease=$lease;ProcessId=$PID}|ConvertTo-Json -Compress),5000)
        $guardian=[IO.Pipes.NamedPipeClientStream]::new('.','nc-lease-'+$lease,'InOut','Asynchronous')
        try {$guardian.Connect(5000);$guardian.WriteByte(1);$guardian.Flush();if(-not $release.Wait(8000)){throw 'Helper did not receive guardian readiness.'}}finally{$guardian.Dispose()}
    }).AddArgument($desktop).AddArgument($ctx.LeaseId).AddArgument($release)
    $task=$simulation.BeginInvoke()
    $owner.Connect(5000);$ctx.OwnerPipe=$owner
    & (Get-Module NetCrate.NetworkSetup) {param($c) Start-NetCrateSetupLease $c} $ctx
    $release.Set()
    if(-not $task.AsyncWaitHandle.WaitOne(8000)){throw 'Mock guardian did not finish.'}
    $null=$simulation.EndInvoke($task);if($simulation.HadErrors){throw $simulation.Streams.Error[0]}
    Assert (([IAsyncResult]$ctx.GuardianClosed).AsyncWaitHandle.WaitOne(3000)) 'The helper did not detect its independent guardian closing.'
    Write-Output 'PASS owner receives only the lease ID, helper verifies the expected pipe client PID and observes guardian exit.'
} finally {
    Stop-NetCrateNetworkSession $ctx
    $release.Set();$owner.Dispose();$desktop.Dispose();$simulation.Dispose();$release.Dispose()
}
