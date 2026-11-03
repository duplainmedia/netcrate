#requires -Version 7.4
param([Parameter(Mandatory)][string]$ToolsRoot,[switch]$Renewal,[switch]$LateAck,[switch]$Resume,[switch]$ManualResume,[string]$TestRoot=(Join-Path $env:TEMP ('NC-exchange-'+[guid]::NewGuid().ToString('N').Substring(0,8))))
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Choose a new disposable TestRoot.'}
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach($module in @('Configuration','Credentials','Pairing','Protocol')){Import-Module (Join-Path $repo "src/shared/NetCrate.$module.psm1")}
foreach($module in @('Engine','Repositories','NetworkSetup')){Import-Module (Join-Path $repo "install/NetCrate.$module.psm1") -DisableNameChecking}
function Assert($c,$reason){if(-not $c){throw $reason}}
function Reject([scriptblock]$f){try{& $f|Out-Null}catch{return};throw ('Invalid operation succeeded at fixture line '+$f.StartPosition.StartLine+'.')}
# Replace OS-wide effects only. The real Schannel listener, REST server,
# repositories, signatures and acknowledgment checks run on loopback.
$engine=Get-Module NetCrate.Engine
& $engine {
    function script:Assert-NetCratePrivateAddress([string]$Address){if($Address -cnotin @('127.0.0.1','127.0.0.2')){throw 'Test only accepts loopback.'}}
    function script:Resolve-NetCrateNetworkAddress($State){Assert-NetCratePrivateAddress $State.NetworkAddress;return $State.NetworkAddress}
    function script:Set-NetCrateOwnedTasks($Root,$Tools){}
    function script:Start-Process { param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$PassThru,[switch]$Wait)
        if($Verb -ne 'RunAs' -or -not $Wait){throw 'Unexpected process launch.'};return @{ExitCode=0} }
}
$network=Get-Module NetCrate.NetworkSetup
& $network {
    function script:Test-NetCrateLeaseAddress($Address){return $Address -cin @('127.0.0.1','127.0.0.2')}
    function script:Resolve-NetCrateNetworkAddress($State){if(-not (Test-NetCrateLeaseAddress $State.NetworkAddress)){throw 'Fixture requires loopback.'};return $State.NetworkAddress}
    function script:Start-NetCrateSetupLease($Context){if($Context.Local -cne '127.0.0.1' -or $Context.Peer -cne '127.0.0.2'){throw 'Fixture requires exact loopback scope.'}}
}
$server=Join-Path $TestRoot Worker
$source=Join-Path $TestRoot Source
$project=Join-Path $TestRoot Project
$storage=Join-Path $TestRoot Storage
$ss=[pscustomobject]@{Role='BackupServer';Folder=$storage;BackupMode='Folder';InstallationId='2'*32;NetworkAddress='127.0.0.1'}
$cs=[pscustomobject]@{Role='EditingComputer';Folder=$project;BackupMode='Folder';InstallationId='1'*32;NetworkAddress='127.0.0.2'}
$tools=@{}
foreach($key in @('Restic','Python','PowerShell','RestServer')){
    $pattern=@{Restic='restic*.exe';Python='python.exe';PowerShell='pwsh.exe';RestServer='rest-server.exe'}[$key]
    $tools[$key]=(Get-ChildItem -LiteralPath (Join-Path $ToolsRoot $key) -Recurse -Filter $pattern -File | Select-Object -First 1).FullName
}
foreach($item in @(@($source,$cs,'Source'),@($server,$ss,'Worker'))){
    $null=New-NetCrateIdentity $item[0] $item[1].InstallationId $item[2]
    $null=[IO.Directory]::CreateDirectory($item[1].Folder)
    Write-NetCrateJson (Join-Path $item[0] prepared.json) @{Role=$item[2];Folder=$item[1].Folder;BackupMode='Folder';InstallationId=$item[1].InstallationId}
    Write-NetCrateJson (Join-Path $item[0] tools.json) $tools
}
$fixtureInstall=Join-Path $server App/install
$null=[IO.Directory]::CreateDirectory($fixtureInstall)
Copy-Item -LiteralPath (Join-Path $repo install/Set-NetCrateFirewall.ps1) -Destination $fixtureInstall
$null=Initialize-NetCrateRepositories $server $storage $tools.Restic
$serverCtx=New-NetCrateNetworkContext $server $ss
$clientCtx=New-NetCrateNetworkContext $source $cs
$serverReq=[pscustomobject]@{LocalAddress=$ss.NetworkAddress;PeerAddress=$cs.NetworkAddress;ApproveFirewall=$true;StartAgain=$false}
$clientReq=[pscustomobject]@{LocalAddress=$cs.NetworkAddress;PeerAddress=$ss.NetworkAddress;ApproveFirewall=$false;StartAgain=$false}
function Exchange([switch]$DropDeliveryOk) {
    # Pump one request in a separate runspace so both socket ends run concurrently.
    $pump=[PowerShell]::Create()
    try {
        $null=$pump.AddScript({param($repo,$context)
            $ErrorActionPreference='Stop'
            Import-Module (Join-Path $repo 'install/NetCrate.NetworkSetup.psm1') -DisableNameChecking
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while(-not $context.Listener.Pending() -and $watch.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 25}
            Invoke-NetCrateNetworkExchange $context -ReceiveOnly
        }).AddArgument($repo).AddArgument($serverCtx)
        $async=$pump.BeginInvoke()
        if($DropDeliveryOk){
            # Close the real source TLS stream after its signed receipt, before
            # consuming delivery-ok. Worker publication still runs normally.
            $channel=[NetCrate.SetupWire]::Connect($clientCtx.Local,$clientCtx.Peer,8201)
            try {
                $wire=Get-NetCrateStableRequest $source $cs.Folder $cs.NetworkAddress Folder
                [NetCrate.SetupWire]::Write($channel.Stream,($wire|ConvertTo-Json -Depth 24 -Compress),15000)
                $wireReply=[NetCrate.SetupWire]::Read($channel.Stream,15000)|ConvertFrom-Json
                $null=Receive-NetCrateStableReply $source $wireReply
                $delivery=[ordered]@{Kind='reply-received';RequestId=$wireReply.RequestId;ReplyHash=(Get-NetCrateHash $wireReply.Signature)}
                $receipt=[ordered]@{Kind=$delivery.Kind;RequestId=$delivery.RequestId;ReplyHash=$delivery.ReplyHash;Signature=(Get-PairingSignature $source $delivery)}
                [NetCrate.SetupWire]::Write($channel.Stream,($receipt|ConvertTo-Json -Compress),15000)
            } finally {$channel.Dispose()}
            $result=$null
        } else {$result=Invoke-NetCrateNetworkExchange $clientCtx}
        if(-not $async.AsyncWaitHandle.WaitOne(18000)){throw 'Server exchange timed out.'}
        $null=$pump.EndInvoke($async)
        if($pump.HadErrors){throw $pump.Streams.Error[0]}
        return $result
    } finally {$pump.Dispose()}
}
$endpoint=$null
try {
    Start-NetCrateNetworkSession $serverCtx $serverReq
    $null=New-NetCratePairingRequest $source 'FIXTURE-EDIT' $project $cs.NetworkAddress -BackupMode Folder
    Start-NetCrateNetworkSession $clientCtx $clientReq
    $firstDeadline=$serverCtx.Until;$originalListener=$serverCtx.Listener
    Start-NetCrateNetworkSession $serverCtx $serverReq
    Assert ($serverCtx.Until -eq $firstDeadline -and [object]::ReferenceEquals($serverCtx.Listener,$originalListener)) 'A duplicate start replaced the active lease.'
    $conflict=$serverReq.PSObject.Copy();$conflict.PeerAddress='127.0.0.1'
    Reject {Start-NetCrateNetworkSession $serverCtx $conflict}
    Assert ($serverCtx.Active -and $serverCtx.Listener -eq $originalListener) 'A conflicting start stopped the active lease.'
    $device=Exchange
    $accepted=Get-NetCrateNetworkStatus $serverCtx
    Assert ($device.Phase -ceq 'CompareDevice' -and $accepted.ComparisonCode -ceq $device.ComparisonCode) 'Device code did not cross the TLS connection.'
    $competitor=New-NetCrateNetworkContext $server $ss
    $replacement=$serverReq.PSObject.Copy();$replacement.StartAgain=$true
    Reject {Start-NetCrateNetworkSession $competitor $replacement}
    Assert ((Get-NetCrateNetworkStatus $serverCtx).ComparisonCode -ceq $device.ComparisonCode) 'Competing desktop replaced the pending identity.'
    Reject {Confirm-NetCrateNetworkSession $serverCtx '0000 0000 0000 0000'}
    Assert (-not (Get-NetCratePairingRecord $server outbound-reply)) 'Sealed a reply before device confirmation.'
    $null=Exchange
    $cs | Add-Member Path (Join-Path $TestRoot fallback-request.netcrate) -Force
    $manual=Invoke-NetCrateSetupAction ExportConnection $cs $source ''
    $ss | Add-Member Path $cs.Path -Force
    $imported=Invoke-NetCrateSetupAction ImportConnection $ss $server ''
    Assert ($manual.PairingCode -ceq $device.ComparisonCode -and $imported.PairingCode -ceq $device.ComparisonCode) 'File fallback replaced a pending network identity.'
    $confirmed=Confirm-NetCrateNetworkSession $serverCtx $device.ComparisonCode
    Assert ($confirmed.Phase -ceq 'WaitingForPeer' -and -not $confirmed.ComparisonCode) 'Server displayed the reply code before delivery.'
    if($ManualResume){
        Stop-NetCrateNetworkSession $serverCtx
        $repeat=Invoke-NetCrateSetupAction ImportConnection $ss $server ''
        Assert ($repeat.PairingStage -ceq 'RequestConfirmed') 'Exact repeat import asked to reconfirm the accepted device.'
        $status=Invoke-NetCrateSetupAction ManualPairingStatus $ss $server ''
        Assert ($status.PairingStage -ceq 'RequestConfirmed' -and $status.PairingCode -ceq $device.ComparisonCode) 'Manual reopen lost the confirmed request projection.'
        $ss | Add-Member PairingCode $device.ComparisonCode -Force
        & $engine {function script:Start-Process {throw 'Repeated confirmation reactivated firewall.'};function script:Set-NetCrateOwnedTasks {throw 'Repeated confirmation reactivated tasks.'}}
        $null=Invoke-NetCrateSetupAction ConfirmConnection $ss $server ''
        [IO.File]::WriteAllText((Join-Path $TestRoot invalid.netcrate),'{}');$ss.Path=Join-Path $TestRoot invalid.netcrate
        Reject {Invoke-NetCrateSetupAction ImportConnection $ss $server ''}
        Assert ((Invoke-NetCrateSetupAction ManualPairingStatus $ss $server '').PairingStage -ceq 'RequestConfirmed') 'Malformed import evicted validated manual status.'
        $foreign=Join-Path $TestRoot Foreign
        $null=New-NetCrateIdentity $foreign ('4'*32) Source
        $wrong=New-NetCratePairingRequest $foreign 'FIXTURE-EDIT' $project $cs.NetworkAddress -BackupMode Folder
        $ss.Path=Join-Path $TestRoot competing.netcrate;Write-NetCrateJson $ss.Path $wrong
        Reject {Invoke-NetCrateSetupAction ImportConnection $ss $server ''}
        Assert ((Invoke-NetCrateSetupAction ManualPairingStatus $ss $server '').PairingStage -ceq 'RequestConfirmed') 'Competing import evicted validated manual status.'
        $originalAddress=$ss.NetworkAddress;$ss.NetworkAddress='127.0.0.2'
        Reject {Invoke-NetCrateSetupAction ManualPairingStatus $ss $server ''}
        $ss.NetworkAddress=$originalAddress
        Write-Output 'PASS manual installation/address-bound confirmed status, exact repeat import and confirmation without reactivation, malformed preservation.'
        return
    }
    if($Resume){
        $identity=(Unprotect-NetCrateRecord $server inbound-request).Request.RequestId
        Stop-NetCrateNetworkSession $serverCtx
        $serverCtx=New-NetCrateNetworkContext $server $ss
        $closed=Get-NetCrateNetworkStatus $serverCtx
        Assert ($closed.Phase -ceq 'ReceptionRequired' -and -not $serverCtx.Listener) 'Closed confirmed server reports acknowledgment wait before reply delivery.'
        $denied=$serverReq.PSObject.Copy();$denied.ApproveFirewall=$false
        Reject {Start-NetCrateNetworkSession $serverCtx $denied}
        Start-NetCrateNetworkSession $serverCtx $serverReq
        Assert ((Unprotect-NetCrateRecord $server inbound-request).Request.RequestId -ceq $identity) 'Reception reapproval replaced the accepted identity.'
    }
    if($Renewal){
        Stop-NetCrateNetworkSession $serverCtx
        $expired=Unprotect-NetCrateRecord $server inbound-request
        $previous=$expired.Request
        $peerKey=$previous.PublicKey
        $tls=Get-NetCratePairingRecord $server tls-identity
        $repoBinding=Read-NetCrateJson (Join-Path $server repositories.json)
        Reject {Invoke-NetCratePairingLock $server {Reset-NetCratePendingPairing $server}}
        $expired.Request.ExpiresUtc=[datetime]::UtcNow.AddSeconds(-1)
        Protect-NetCrateRecord $server inbound-request $expired
        Invoke-NetCratePairingLock $server {Reset-NetCratePendingPairing $server}
        Assert ((Get-NetCratePairingRecord $server tls-identity).Certificate -ceq $tls.Certificate) 'Renewal replaced the active endpoint identity.'
        Assert ((Read-NetCrateJson (Join-Path $server repositories.json)).PrimaryId -ceq $repoBinding.PrimaryId) 'Renewal replaced the repository.'
        $foreign=Join-Path $TestRoot Foreign
        $null=New-NetCrateIdentity $foreign ('4'*32) Source
        $wrong=New-NetCratePairingRequest $foreign 'FIXTURE-EDIT' $project $cs.NetworkAddress -BackupMode Folder
        Reject {Receive-NetCrateStableRequest $server $wrong Folder $cs.NetworkAddress}
        $new=New-NetCratePairingRequest $source 'FIXTURE-EDIT' $project $cs.NetworkAddress -BackupMode Folder
        $null=Receive-NetCrateStableRequest $server $new Folder $cs.NetworkAddress
        Assert ((Unprotect-NetCrateRecord $server inbound-request).Request.PublicKey -ceq $peerKey) 'Renewal accepted another source key.'
        Write-Output 'PASS expired unfinished worker can renew only the original source, with its original endpoint and storage.'
        return
    }
    $cached=(Get-NetCrateStableReply $server).Signature
    Assert ((Get-NetCrateStableReply $server).Signature -ceq $cached) 'Retried reply changed.'
    $ss.Path=Join-Path $TestRoot fallback-reply.netcrate
    $null=Invoke-NetCrateSetupAction ExportConnection $ss $server ''
    Assert ((Read-NetCrateJson $ss.Path).Signature -ceq $cached) 'File fallback did not use the cached sealed reply.'
    $savedProof=Unprotect-NetCrateRecord $source network-proof
    [IO.File]::Delete((Join-Path $source Secrets/network-proof.json))
    Protect-NetCrateRecord $source network-selection @{LocalAddress=$cs.NetworkAddress;PeerAddress='100.64.0.99'}
    $cs.Path=$ss.Path
    Reject {Invoke-NetCrateSetupAction ImportConnection $cs $source ''}
    Assert (-not (Get-NetCratePairingRecord $source pending-reply)) 'A rejected reply poisoned the source pending record.'
    Protect-NetCrateRecord $source network-selection @{LocalAddress=$cs.NetworkAddress;PeerAddress=$ss.NetworkAddress}
    Protect-NetCrateRecord $source network-proof $savedProof
    if($Resume){
        $null=Exchange -DropDeliveryOk
        Assert ((Get-NetCratePairingRecord $server reply-delivered) -and -not (Get-NetCratePairingRecord $source reply-delivered)) 'Lost delivery-ok fixture did not create worker-only delivery evidence.'
        Stop-NetCrateNetworkSession $serverCtx;Stop-NetCrateNetworkSession $clientCtx
        $serverCtx=New-NetCrateNetworkContext $server $ss;$clientCtx=New-NetCrateNetworkContext $source $cs
        $closed=Get-NetCrateNetworkStatus $serverCtx
        Assert ($closed.Phase -ceq 'CompareConnection' -and $closed.ComparisonCode -and -not $serverCtx.Listener) 'Worker-only receipt lost its comparison code or implicitly reopened reception.'
        Assert ($closed.ContainsKey('CanRetryReception') -and $closed.CanRetryReception) 'Worker-only delivery receipt leaves no same-reply reception retry after reopen.'
        Assert (-not (Get-NetCrateNetworkStatus $clientCtx).ComparisonCode) 'The source displayed a connection comparison before consuming delivery confirmation.'
        $denied=$serverReq.PSObject.Copy();$denied.ApproveFirewall=$false
        Reject {Start-NetCrateNetworkSession $serverCtx $denied}
        $wrongScope=$serverReq.PSObject.Copy();$wrongScope.LocalAddress=$cs.NetworkAddress;$wrongScope.PeerAddress=$ss.NetworkAddress
        Reject {Start-NetCrateNetworkSession $serverCtx $wrongScope}
        Start-NetCrateNetworkSession $serverCtx $serverReq;Start-NetCrateNetworkSession $clientCtx $clientReq
        Assert ((Get-NetCrateStableReply $server).Signature -ceq $cached -and (Unprotect-NetCrateRecord $server inbound-request).Request.RequestId -ceq $identity) 'Receipt retry replaced the existing identity or encrypted reply.'
    }
    $reply=Exchange
    $confirmed=Get-NetCrateNetworkStatus $serverCtx
    Assert ($confirmed.Phase -ceq 'CompareConnection' -and $reply.Phase -ceq 'CompareConnection' -and $reply.ComparisonCode -ceq $confirmed.ComparisonCode) 'Connection codes differ.'
    if($Resume){
        Stop-NetCrateNetworkSession $serverCtx
        $serverCtx=New-NetCrateNetworkContext $server $ss
        $closed=Get-NetCrateNetworkStatus $serverCtx
        Assert ($closed.Phase -ceq 'CompareConnection' -and $closed.ComparisonCode -ceq $reply.ComparisonCode -and -not $serverCtx.Listener) 'Delivered reply comparison was hidden after reopen.'
    }
    Reject {Confirm-NetCrateNetworkSession $clientCtx '0000 0000 0000 0000'}
    Assert (-not (Get-NetCratePairingRecord $source paired-secrets)) 'Source imported active credentials before the second comparison.'
    $evidence=Unprotect-NetCrateRecord $source network-proof
    $forged=$evidence.PSObject.Copy();$forged.PresentedDER=[Convert]::ToBase64String([byte[]]::new(64))
    Protect-NetCrateRecord $source network-proof $forged
    Reject {Confirm-NetCrateNetworkSession $clientCtx $reply.ComparisonCode}
    Protect-NetCrateRecord $source network-proof $evidence
    $currentRequest=Unprotect-NetCrateRecord $source outbound-request
    $expires=$currentRequest.Request.ExpiresUtc
    $currentRequest.Request.ExpiresUtc=[datetime]::UtcNow.AddSeconds(-1)
    Protect-NetCrateRecord $source outbound-request $currentRequest
    $cs | Add-Member PairingCode $reply.ComparisonCode -Force
    Reject {Invoke-NetCrateSetupAction ConfirmConnection $cs $source ''}
    Assert (-not (Get-NetCratePairingRecord $source paired-peer)) 'An expired request activated a source peer.'
    $currentRequest.Request.ExpiresUtc=$expires;Protect-NetCrateRecord $source outbound-request $currentRequest
    $null=Confirm-NetCrateNetworkSession $clientCtx $reply.ComparisonCode
    Assert (-not (Test-Path (Join-Path $source Secrets/network-secrets.json))) 'Unexpected transport credential store.'
    if($LateAck){
        Stop-NetCrateNetworkSession $clientCtx
        Stop-NetCrateNetworkSession $serverCtx
        $expired=Unprotect-NetCrateRecord $server inbound-request
        $expired.Request.ExpiresUtc=[datetime]::UtcNow.AddSeconds(-1)
        Protect-NetCrateRecord $server inbound-request $expired
        Invoke-NetCratePairingLock $server {Reset-NetCratePendingPairing $server}
        $serverCtx=New-NetCrateNetworkContext $server $ss
        $clientCtx=New-NetCrateNetworkContext $source $cs
        Assert ((Get-NetCrateNetworkStatus $serverCtx).Phase -ceq 'WaitingForAcknowledgment' -and -not $serverCtx.Listener) 'Reset discarded the worker session before the offline source could deliver its acknowledgment.'
    }
    $pi=[Diagnostics.ProcessStartInfo]::new($tools.RestServer);$pi.UseShellExecute=$false;$pi.CreateNoWindow=$true
    foreach($arg in (Get-NetCrateServerArguments $server)){$pi.ArgumentList.Add($arg)}
    $endpoint=[Diagnostics.Process]::Start($pi)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {$verified=Invoke-NetCrateNetworkExchange $clientCtx;if($verified.Phase -cne 'Connected'){Start-Sleep -Milliseconds 150}}while($verified.Phase -cne 'Connected' -and $watch.Elapsed.TotalSeconds -lt 60)
    Assert ($verified.Phase -ceq 'Connected') 'Source repository verification or signed acknowledgment failed.'
    if($LateAck){
        Assert ((Invoke-NetCrateNetworkExchange $serverCtx).Phase -ceq 'Connected' -and -not $serverCtx.Listener) 'The late signed acknowledgment was not accepted with the setup port closed.'
        Reject {Invoke-NetCratePairingLock $server {Reset-NetCratePendingPairing $server}}
        Write-Output 'PASS offline confirmed source resumed after worker reset, late signed acknowledgment verified on a closed setup port.'
        return
    }
    $expiredWorker=Unprotect-NetCrateRecord $server inbound-request
    $expiredWorker.Request.ExpiresUtc=[datetime]::UtcNow.AddSeconds(-1)
    Protect-NetCrateRecord $server inbound-request $expiredWorker
    Assert ((Invoke-NetCrateNetworkExchange $serverCtx).Phase -ceq 'Connected') 'Server could not verify the signed acknowledgment.'
    foreach($result in @($device,$accepted,$confirmed,$reply,$verified)){
        Assert (($result|ConvertTo-Json -Depth 12) -notmatch 'PrimaryPassword|PrivateKey|TransportPassword|Ciphertext|ProtectedData|BEGIN CERTIFICATE') 'Sensitive material appeared in a UI result.'
    }
    Stop-NetCrateNetworkSession $serverCtx
    $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,8201)
    try{$probe.Start()}finally{$probe.Stop()}
    [IO.File]::Delete((Join-Path $server Secrets/network-verified.json));[IO.File]::Delete((Join-Path $server Secrets/pairing-activated.json))
    Reject {Invoke-NetCratePairingLock $server {Reset-NetCratePendingPairing $server}}
    $resumed=New-NetCrateNetworkContext $server $ss
    Assert ((Get-NetCrateNetworkStatus $resumed).Phase -ceq 'WaitingForAcknowledgment') 'Resume lost the existing verified connection.'
    Assert ((Invoke-NetCrateNetworkExchange $resumed).Phase -ceq 'Connected' -and -not $resumed.Listener) 'Resume opened a listener or skipped signed acknowledgment verification.'
    $clientCtx.Until=[datetime]::UtcNow.AddSeconds(-1)
    Reject {Invoke-NetCrateNetworkExchange $clientCtx}
    Assert (-not $clientCtx.Active) 'Expired session is still active.'
    Write-Output 'PASS two real TLS comparisons, stable sealed reply, mismatched DER, repository checks, signed acknowledgment, expiry and listener cleanup.'
} finally {
    Stop-NetCrateNetworkSession $serverCtx
    Stop-NetCrateNetworkSession $clientCtx
    if($endpoint){if(-not $endpoint.HasExited){$endpoint.Kill($true);$endpoint.WaitForExit()};$endpoint.Dispose()}
}
