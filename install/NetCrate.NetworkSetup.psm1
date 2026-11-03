#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Engine.psm1') -DisableNameChecking
foreach($module in @('Configuration','Credentials','Process','Pairing','Protocol')){Import-Module (Join-Path $PSScriptRoot "../src/shared/NetCrate.$module.psm1")}
if(-not ('NetCrate.SetupWire' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'NetCrate.SetupWire.cs')}
function Test-NetCrateLeaseAddress([string]$Address) {
    try {
        Assert-NetCratePrivateAddress $Address
        return [Net.IPAddress]::Parse($Address).ToString() -ceq $Address
    } catch {return $false}
}

function ConvertFrom-NetCrateNetBirdStatus([string]$Text) {
    [NetCrate.SetupWire]::Validate($Text)
    $data=$Text | ConvertFrom-Json
    if($data.cliVersion -cne '0.81.3'){throw 'Use manual private addresses for this NetBird version.'}
    $local=($data.netbirdIp -split '/')[0]
    if(-not (Test-NetCrateLeaseAddress $local)){throw 'NetBird has no active private IPv4 address.'}
    $peers=@();$seen=[Collections.Generic.HashSet[string]]::new()
    foreach($peer in @($data.peers.details)){
        if($null -eq $peer -or $peer.status -cne 'Connected' -or -not (Test-NetCrateLeaseAddress $peer.netbirdIp) -or $peer.netbirdIp -ceq $local -or -not $seen.Add($peer.netbirdIp)){continue}
        $name=if($peer.fqdn -cmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$'){$peer.fqdn}else{$peer.netbirdIp}
        $peers+=@{Name=$name;Address=$peer.netbirdIp}
        if($peers.Count -ge 128){break}
    }
    return @{LocalAddress=$local;Peers=$peers}
}
function Get-NetCrateDiscovery {
    $manual=@{LocalAddress='';Peers=@()}
    $exe=[IO.Path]::Combine($env:ProgramFiles,'NetBird','netbird.exe')
    if(-not [IO.File]::Exists($exe)){return $manual}
    try {
        $cli=New-Object Diagnostics.ProcessStartInfo $exe
        $cli.UseShellExecute=$false;$cli.CreateNoWindow=$true;$cli.RedirectStandardOutput=$true;$cli.RedirectStandardError=$true
        $cli.ArgumentList.Add('status');$cli.ArgumentList.Add('--json')
        $process=[Diagnostics.Process]::Start($cli)
        try {
            $text=[NetCrate.SetupWire]::ReadCli($process)
            return ConvertFrom-NetCrateNetBirdStatus $text
        } finally {if(-not $process.HasExited){$process.Kill($true)};$process.Dispose()}
    } catch {return $manual}
}
function New-NetCrateNetworkContext([string]$Root,$State) {
    $owner=Get-NetCrateOwner $Root
    $prepared=Read-NetCrateJson ([IO.Path]::Combine($Root,'prepared.json'))
    $role=if($State.Role -ceq 'BackupServer'){'Worker'}elseif($State.Role -ceq 'EditingComputer'){'Source'}else{throw 'Unknown computer role.'}
    if($State.InstallationId -cne $owner.InstallationId -or $role -cne $owner.Role -or $prepared.InstallationId -cne $owner.InstallationId -or $prepared.Role -cne $role -or
        (Get-NetCrateBackupMode $prepared) -cne (Get-NetCrateBackupMode $State) -or -not $prepared.Folder.Equals($State.Folder,[StringComparison]::OrdinalIgnoreCase)){throw 'The setup choices differ from this installation.'}
    return @{Root=$Root;State=$State;Role=$role;Local='';Peer='';Active=$false;Listener=$null;Certificate=$null;GuardianClosed=$null;OwnerPipe=$null;LeaseId=$null;LeasePipe=$null;SessionOwner=$null;Until=[datetime]::MinValue;Connected=$false}
}
function Stop-NetCrateNetworkSession($Context) {
    if($Context.Listener){$Context.Listener.Stop();$Context.Listener=$null}
    if($Context.Certificate){$Context.Certificate.Dispose();$Context.Certificate=$null}
    if($Context.LeasePipe){$Context.LeasePipe.Dispose();$Context.LeasePipe=$null}
    $Context.GuardianClosed=$null
    if($Context.SessionOwner){$Context.SessionOwner.Dispose();$Context.SessionOwner=$null}
    $Context.Active=$false;$Context.Connected=$false
}
function Start-NetCrateSetupLease($Context) {
    $lease=$Context.LeaseId
    if($lease -cnotmatch '^[0-9a-f]{32}$' -or -not $Context.OwnerPipe){throw 'Desktop firewall approval is required.'}
    $security=[IO.Pipes.PipeSecurity]::new()
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
        $security.AddAccessRule([IO.Pipes.PipeAccessRule]::new($sid,'FullControl','Allow'))
    }
    $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create('nc-lease-'+$lease,'InOut',1,'Byte','Asynchronous',4096,4096,$security)
    $Context.LeasePipe=$pipe
    # Only the desktop can authorize and construct the elevated command.
    [NetCrate.SetupWire]::Write($Context.OwnerPipe,(@{Kind='OpenLease';Lease=$lease}|ConvertTo-Json -Compress),15000)
    $answer=[NetCrate.SetupWire]::ReadOwnerCommandAsync($Context.OwnerPipe).GetAwaiter().GetResult() | ConvertFrom-Json
    if($answer.Kind -cne 'Guardian' -or $answer.Lease -cne $lease -or $answer.ProcessId -le 0){throw 'The administrator approval did not finish.'}
    $cts=[Threading.CancellationTokenSource]::new(15000)
    try {
        $null=$pipe.WaitForConnectionAsync($cts.Token).GetAwaiter().GetResult()
        if([NetCrate.SetupWire]::PipeClientId($pipe) -ne [int]$answer.ProcessId){throw 'Unexpected lease guardian.'}
        $one=[byte[]]::new(1)
        if($pipe.ReadAsync($one,0,1,$cts.Token).GetAwaiter().GetResult() -ne 1 -or $one[0] -ne 1){throw 'The temporary firewall rule was not verified.'}
        $Context.GuardianClosed=$pipe.ReadAsync($one,0,1)
    } finally {$cts.Dispose()}
}
function Enter-NetCratePairingSession($Context) {
    $owner=Get-NetCrateOwner $Context.Root
    $created=$false
    $session=[Threading.Mutex]::new($false,('Global\NetCrate-SetupSession-'+$owner.UserSid+'-'+$owner.InstallationId),[ref]$created)
    if(-not $created){$session.Dispose();throw 'Close the other setup session before starting a new lease.'}
    return $session
}
function Reset-NetCrateNetworkPending($Context) {
    $session=Enter-NetCratePairingSession $Context
    try {Invoke-NetCratePairingLock $Context.Root {Reset-NetCratePendingPairing $Context.Root}} finally {$session.Dispose()}
    return Get-NetCrateNetworkStatus $Context
}
function Start-NetCrateNetworkSession($Context,$Request) {
    if($Context.Role -ceq 'Worker' -and $Request.ApproveFirewall -ne $true){throw 'Approve the temporary firewall permission before listening.'}
    if(-not (Test-NetCrateLeaseAddress $Request.LocalAddress) -or -not (Test-NetCrateLeaseAddress $Request.PeerAddress) -or $Request.PeerAddress -ceq $Request.LocalAddress){throw 'Choose two distinct private IPv4 addresses.'}
    if($Context.Active -and -not $Request.StartAgain){
        Test-NetCrateNetworkLease $Context
        if($Context.Local -ceq $Request.LocalAddress -and $Context.Peer -ceq $Request.PeerAddress){return}
        throw 'Another private address is already selected for the active lease.'
    }
    $local=Resolve-NetCrateNetworkAddress ([pscustomobject]@{NetworkAddress=$Request.LocalAddress})
    $resetCompleted=$false
    if($Context.Active){
        # Reject an unsafe replacement before surrendering the current lease.
        Invoke-NetCratePairingLock $Context.Root {Reset-NetCratePendingPairing $Context.Root}
        $resetCompleted=$true
        Stop-NetCrateNetworkSession $Context
    }
    $Context.State.NetworkAddress=$local
    $Context.Local=$local;$Context.Peer=$Request.PeerAddress
    $Context.SessionOwner=Enter-NetCratePairingSession $Context
    try {
        Invoke-NetCratePairingLock $Context.Root {
            if($Request.StartAgain -and -not $resetCompleted){Reset-NetCratePendingPairing $Context.Root}
            $renewal=Get-NetCratePairingRecord $Context.Root renewal-peer
            if($renewal -and ($renewal.NetworkAddress -cne $Context.Peer -or (Read-NetCrateJson ([IO.Path]::Combine($Context.Root,'endpoint.json'))).Address -cne $local)){throw 'Renewal must use the original runtime addresses.'}
            $old=Get-NetCratePairingRecord $Context.Root network-selection
            if($old -and ($old.LocalAddress -cne $local -or $old.PeerAddress -cne $Context.Peer)){throw 'The selected peer differs. Choose Start again to replace the pending session.'}
            $inbound=Get-NetCratePairingRecord $Context.Root inbound-request
            if($inbound -and $inbound.Request.NetworkAddress -cne $Context.Peer){throw 'Another editing computer has a pending request.'}
            Protect-NetCrateRecord $Context.Root network-selection @{LocalAddress=$local;PeerAddress=$Context.Peer}
            if($Context.Role -ceq 'Source'){
                $existing=Get-NetCratePairingRecord $Context.Root outbound-request
                if(-not $existing -or -not $existing.Consumed){$null=Get-NetCrateStableRequest $Context.Root $Context.State.Folder $local (Get-NetCrateBackupMode $Context.State)}
            } else {
                $tls=Get-NetCrateSetupTlsIdentity $Context.Root $local
                $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($tls.Certificate,$tls.PrivateKey)
                try {
                    $bytes=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
                    try {$Context.Certificate=[Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12($bytes,$null,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)}
                    finally {[Array]::Clear($bytes)}
                } finally {$cert.Dispose()}
            }
        }
        $Context.Until=[datetime]::UtcNow.AddMinutes(15)
        if($Context.Role -ceq 'Worker'){
            Start-NetCrateSetupLease $Context
            if([datetime]::UtcNow -ge $Context.Until){throw 'The setup lease expired during approval.'}
            $Context.Listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($local),8201)
            $Context.Listener.ExclusiveAddressUse=$true;$Context.Listener.Start(1)
        }
        $Context.Active=$true
    } catch {Stop-NetCrateNetworkSession $Context;throw}
}
function Test-NetCrateNetworkLease($Context) {
    if($Context.Active -and ([datetime]::UtcNow -ge $Context.Until -or ($Context.GuardianClosed -and $Context.GuardianClosed.IsCompleted))){Stop-NetCrateNetworkSession $Context;throw 'The temporary connection expired. Start a new lease.'}
}
function New-NetworkStatus($Context,$Phase,$Message,[string]$Code='') {
    return @{Phase=$Phase;Message=$Message;ComparisonCode=$Code;LocalAddress=$Context.Local;PeerAddress=$Context.Peer;Peers=@();CanRetryReception=$false}
}
function Get-NetCrateDeliveryData($Reply) {
    return [ordered]@{Kind='reply-received';RequestId=$Reply.RequestId;ReplyHash=(Get-NetCrateHash $Reply.Signature)}
}
function Test-NetCrateDeliveredReply($Root,$Reply) {
    $record=Get-NetCratePairingRecord $Root reply-delivered
    return ($record -and $record.RequestId -ceq $Reply.RequestId -and $record.ReplyHash -ceq (Get-NetCrateHash $Reply.Signature))
}
function Get-NetCrateNetworkStatus($Context) {
    Test-NetCrateNetworkLease $Context
    if($Context.Connected){return New-NetworkStatus $Context Connected 'Both repositories and the signed acknowledgment were verified.'}
    if(-not $Context.Active){
        $activated=Get-NetCratePairingRecord $Context.Root pairing-activated
        $peer=Get-NetCratePairingRecord $Context.Root paired-peer
        $proof=Get-NetCratePairingRecord $Context.Root network-proof
        $workerSettings=$null
        if($Context.Role -ceq 'Worker'){$workerSettings=Get-NetCrateWorkerPairingSettings $Context.Root (Get-NetCratePairingRecord $Context.Root inbound-request)}
        $result=New-NetworkStatus $Context Idle 'Select both private addresses and start a connection.'
        if(($Context.Role -ceq 'Source' -and $peer -and ((-not $activated -and -not $proof -and [IO.File]::Exists([IO.Path]::Combine($Context.Root,'settings.json'))) -or ($activated -and $activated.RequestId -ceq $peer.Request.RequestId))) -or
            ($null -ne $workerSettings)){
            $result=New-NetworkStatus $Context WaitingForAcknowledgment 'Rechecking the existing backup connection. The temporary listener is closed.'
        }
        $selection=Get-NetCratePairingRecord $Context.Root network-selection
        if($selection){$result.LocalAddress=$selection.LocalAddress;$result.PeerAddress=$selection.PeerAddress}
        elseif($workerSettings){
            $endpoint=Read-NetCrateJson ([IO.Path]::Combine($Context.Root,'endpoint.json'))
            $result.LocalAddress=$endpoint.Address;$result.PeerAddress=$endpoint.SourceAddress
        }
        if($workerSettings){
            $inbound=Get-NetCratePairingRecord $Context.Root inbound-request
            $sealed=Get-NetCratePairingRecord $Context.Root outbound-reply
            $verified=Get-NetCratePairingRecord $Context.Root network-verified
            if([datetimeoffset]$inbound.Request.ExpiresUtc -gt [datetimeoffset]::UtcNow -and (-not $verified -or $verified.RequestId -cne $inbound.Request.RequestId)){
                if($sealed -and $sealed.Reply.RequestId -ceq $inbound.Request.RequestId -and (Test-NetCrateDeliveredReply $Context.Root $sealed.Reply)){
                    $result.Phase='CompareConnection';$result.ComparisonCode=$sealed.Reply.ConnectionCode
                    $result.CanRetryReception=([datetimeoffset]$sealed.Reply.ExpiresUtc -gt [datetimeoffset]::UtcNow)
                    $result.Message='Compare this code on the Editing Computer. If it is still waiting for the reply, approve temporary reception to retry this same reply. Reception remains closed until approval.'
                } else {
                    $result.Phase='ReceptionRequired'
                    $result.Message='Approve temporary reception again for these same addresses so the Editing Computer can collect the existing encrypted reply.'
                }
            }
        }
        return $result
    }
    if($Context.Role -ceq 'Worker'){
        $inbound=Get-NetCratePairingRecord $Context.Root inbound-request
        if(-not $inbound){return New-NetworkStatus $Context WaitingForPeer 'Waiting for the Editing Computer to connect.'}
        if([datetimeoffset]$inbound.Request.ExpiresUtc -le [datetimeoffset]::UtcNow){
            if(Get-NetCrateWorkerPairingSettings $Context.Root $inbound){return New-NetworkStatus $Context WaitingForAcknowledgment 'Checking whether the Editing Computer acknowledged the accepted connection.'}
            throw 'The device request expired.'
        }
        $activated=Get-NetCratePairingRecord $Context.Root pairing-activated
        if(-not $activated -or $activated.RequestId -cne $inbound.Request.RequestId){return New-NetworkStatus $Context CompareDevice 'Compare this editing device code on both computers.' $inbound.Request.DeviceCode}
        $sealed=Get-NetCratePairingRecord $Context.Root outbound-reply
        if($sealed -and $sealed.Reply.RequestId -ceq $inbound.Request.RequestId -and (Test-NetCrateDeliveredReply $Context.Root $sealed.Reply)){return New-NetworkStatus $Context CompareConnection 'Compare this connection code on the Editing Computer, then confirm it there.' $sealed.Reply.ConnectionCode}
        return New-NetworkStatus $Context WaitingForPeer 'Waiting for the Editing Computer to collect the reply.'
    }
    $request=Unprotect-NetCrateRecord $Context.Root outbound-request
    $activated=Get-NetCratePairingRecord $Context.Root pairing-activated
    if($request.Consumed -and $activated -and $activated.RequestId -ceq $request.Request.RequestId){return New-NetworkStatus $Context WaitingForAcknowledgment 'Checking both backup repositories and sending the signed acknowledgment.'}
    if([datetimeoffset]$request.Request.ExpiresUtc -le [datetimeoffset]::UtcNow){throw 'The device request expired.'}
    $pending=Get-NetCratePairingRecord $Context.Root pending-reply
    if($pending -and $pending.Reply.RequestId -ceq $request.Request.RequestId){
        $proof=Get-NetCratePairingRecord $Context.Root network-proof
        if($proof -and $proof.RequestId -ceq $request.Request.RequestId -and $proof.PeerAddress -ceq $pending.Payload.Address){
            Assert-NetCratePresentedCertificate $pending.Payload.Certificate $proof.PresentedDER
            Test-NetCrateConnectionPayload $pending.Payload $request.Request $pending.Reply
            if([datetimeoffset]$pending.Reply.ExpiresUtc -le [datetimeoffset]::UtcNow){throw 'The connection reply expired.'}
            if(-not (Test-NetCrateDeliveredReply $Context.Root $pending.Reply)){return New-NetworkStatus $Context WaitingForPeer 'Confirming delivery of the encrypted reply.'}
            return New-NetworkStatus $Context CompareConnection 'Compare this connection code on both computers before accepting the reply.' $pending.Reply.ConnectionCode
        }
    }
    return New-NetworkStatus $Context CompareDevice 'Compare this device code on the Backup Server. Confirm it there.' $request.Request.DeviceCode
}
function Invoke-NetCrateNetworkExchange($Context,[switch]$ReceiveOnly) {
    Test-NetCrateNetworkLease $Context
    if(-not $Context.Active){
        $prior=Get-NetCrateNetworkStatus $Context
        if($prior.Phase -cnotin @('WaitingForAcknowledgment','CompareConnection','ReceptionRequired')){return $prior}
    } elseif($Context.Role -ceq 'Worker'){
        if($Context.Listener.Pending()){
            $channel=$null
            try {
                $channel=[NetCrate.SetupWire]::AcceptAsync($Context.Listener,$Context.Peer,$Context.Certificate).GetAwaiter().GetResult()
                $wire=[NetCrate.SetupWire]::Read($channel.Stream,15000) | ConvertFrom-Json
                Test-NetCrateNetworkLease $Context
                $response=Invoke-NetCratePairingLock $Context.Root {
                    $null=Receive-NetCrateStableRequest $Context.Root $wire (Get-NetCrateBackupMode $Context.State) $Context.Peer
                    $activation=Get-NetCratePairingRecord $Context.Root pairing-activated
                    if($activation -and $activation.RequestId -ceq $wire.RequestId){return Get-NetCrateStableReply $Context.Root}
                    return @{Kind='waiting';RequestId=$wire.RequestId}
                }
                Test-NetCrateNetworkLease $Context
                [NetCrate.SetupWire]::Write($channel.Stream,($response | ConvertTo-Json -Compress -Depth 24),15000)
                if($response.Kind -ceq 'netcrate-pair-reply'){
                    $receipt=[NetCrate.SetupWire]::Read($channel.Stream,15000) | ConvertFrom-Json
                    $delivery=Get-NetCrateDeliveryData $response
                    if(@($receipt.PSObject.Properties).Count -ne 4 -or $receipt.Kind -cne $delivery.Kind -or $receipt.RequestId -cne $delivery.RequestId -or $receipt.ReplyHash -cne $delivery.ReplyHash){throw 'The reply receipt differs.'}
                    Assert-PairingSignature $wire.PublicKey $delivery $receipt.Signature
                    Test-NetCrateNetworkLease $Context
                    Invoke-NetCratePairingLock $Context.Root {Protect-NetCrateRecord $Context.Root reply-delivered $delivery}
                    [NetCrate.SetupWire]::Write($channel.Stream,(@{Kind='delivery-ok';ReplyHash=$delivery.ReplyHash}|ConvertTo-Json -Compress),15000)
                }
            } catch {
                # A competing, truncated or invalid connection cannot evict the accepted request.
                if($channel){try{[NetCrate.SetupWire]::Write($channel.Stream,'{"Kind":"rejected"}',1000)}catch{}}
            } finally {if($channel){$channel.Dispose()}}
        }
    } else {
        $status=Get-NetCrateNetworkStatus $Context
        if($status.Phase -cin @('CompareDevice','WaitingForPeer')){
            $channel=$null
            try {
                try {$channel=[NetCrate.SetupWire]::Connect($Context.Local,$Context.Peer,8201)}
                catch [Net.Sockets.SocketException] {return $status}
                Test-NetCrateNetworkLease $Context
                Invoke-NetCratePairingLock $Context.Root {
                    $wire=Get-NetCrateStableRequest $Context.Root $Context.State.Folder $Context.Local (Get-NetCrateBackupMode $Context.State)
                    $proof=Get-NetCratePairingRecord $Context.Root network-proof
                    if($proof -and ($proof.RequestId -cne $wire.RequestId -or $proof.PresentedDER -cne $channel.PresentedDER -or $proof.PeerAddress -cne $Context.Peer)){throw 'The presented certificate or peer changed. Stop and verify both computers.'}
                    if(-not $proof){Protect-NetCrateRecord $Context.Root network-proof @{RequestId=$wire.RequestId;PeerAddress=$Context.Peer;PresentedDER=$channel.PresentedDER}}
                    [NetCrate.SetupWire]::Write($channel.Stream,($wire|ConvertTo-Json -Depth 24 -Compress),15000)
                    $reply=[NetCrate.SetupWire]::Read($channel.Stream,15000) | ConvertFrom-Json
                    Test-NetCrateNetworkLease $Context
                    if($reply.Kind -ceq 'waiting' -and $reply.RequestId -ceq $wire.RequestId){return}
                    $null=Receive-NetCrateStableReply $Context.Root $reply
                    $delivery=Get-NetCrateDeliveryData $reply
                    $receipt=[ordered]@{Kind=$delivery.Kind;RequestId=$delivery.RequestId;ReplyHash=$delivery.ReplyHash;Signature=(Get-PairingSignature $Context.Root $delivery)}
                    [NetCrate.SetupWire]::Write($channel.Stream,($receipt|ConvertTo-Json -Compress),15000)
                    $confirmed=[NetCrate.SetupWire]::Read($channel.Stream,15000) | ConvertFrom-Json
                    if($confirmed.Kind -cne 'delivery-ok' -or $confirmed.ReplyHash -cne $delivery.ReplyHash){throw 'The server did not confirm delivery.'}
                    Test-NetCrateNetworkLease $Context
                    Protect-NetCrateRecord $Context.Root reply-delivered $delivery
                }
            } finally {if($channel){$channel.Dispose()}}
        }
    }
    if($ReceiveOnly){return}
    $status=Get-NetCrateNetworkStatus $Context
    if(($Context.Role -ceq 'Worker' -and $status.Phase -ceq 'CompareConnection') -or $status.Phase -ceq 'WaitingForAcknowledgment'){
        try {
            $Context.Connected=Invoke-NetCratePairingLock $Context.Root {
                $checked=Invoke-NetCrateSetupAction CheckConnection $Context.State $Context.Root ''
                if($checked.Succeeded -and $Context.Role -ceq 'Worker'){
                    $inbound=Unprotect-NetCrateRecord $Context.Root inbound-request
                    Protect-NetCrateRecord $Context.Root network-verified @{RequestId=$inbound.Request.RequestId}
                }
                return $checked.Succeeded
            }
        } catch {
            if($Context.Role -ceq 'Source'){return New-NetworkStatus $Context WaitingForAcknowledgment 'Waiting to verify both repositories and send the signed acknowledgment. Check that both computers are on.'}
        }
    }
    return Get-NetCrateNetworkStatus $Context
}
function Confirm-NetCrateNetworkSession($Context,[string]$Code) {
    Invoke-NetCratePairingLock $Context.Root {
        $status=Get-NetCrateNetworkStatus $Context
        $phase=if($Context.Role -ceq 'Worker'){'CompareDevice'}else{'CompareConnection'}
        if($status.Phase -cne $phase -or $Code -cnotmatch '^[A-F0-9]{4}( [A-F0-9]{4}){3}$' -or $Code -cne $status.ComparisonCode){throw 'Compare the current codes on both computers.'}
        $Context.State | Add-Member -NotePropertyName PairingCode -NotePropertyValue $Code -Force
        $null=Invoke-NetCrateSetupAction ConfirmConnection $Context.State $Context.Root ''
        if($Context.Role -ceq 'Worker'){ $null=Get-NetCrateStableReply $Context.Root }
    }
    return Get-NetCrateNetworkStatus $Context
}
Export-ModuleMember -Function New-NetCrateNetworkContext,Get-NetCrateNetworkStatus,Start-NetCrateNetworkSession,Reset-NetCrateNetworkPending,Stop-NetCrateNetworkSession,Invoke-NetCrateNetworkExchange,Confirm-NetCrateNetworkSession,Get-NetCrateDiscovery,ConvertFrom-NetCrateNetBirdStatus
