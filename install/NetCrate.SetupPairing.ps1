# Imported into NetCrate.Engine. Callers hold the same installation lock for
# network and file exchange, including confirmation and runtime activation.
function Invoke-NetCratePairingLock([string]$Root,[scriptblock]$Operation) {
    $owner=Get-NetCrateOwner $Root
    $mutex=[Threading.Mutex]::new($false,('Global\NetCrate-Pairing-'+$owner.UserSid+'-'+$owner.InstallationId))
    $held=$false
    try {
        try {$held=$mutex.WaitOne(5000)} catch [Threading.AbandonedMutexException] {$held=$true}
        if(-not $held){throw 'Another setup action is using this pairing session.'}
        & $Operation
    } finally {if($held){$mutex.ReleaseMutex()}; $mutex.Dispose()}
}
function Get-NetCratePairingRecord([string]$Root,[string]$Name) {
    if([IO.File]::Exists([IO.Path]::Combine($Root,'Secrets',$Name+'.json'))){return Unprotect-NetCrateRecord $Root $Name}
}
function Assert-NetCrateLiveWire($Wire) {
    if([datetimeoffset]$Wire.ExpiresUtc -le [datetimeoffset]::UtcNow){throw 'The connection expired. Choose Start again on both computers.'}
}
function Get-NetCrateManualPairingStatus($Root,$State,$Prepared,$Role) {
    $local=Resolve-NetCrateNetworkAddress $State
    $code='';$stage=''
    if($Role -ceq 'Worker'){
        $inbound=Get-NetCratePairingRecord $Root inbound-request
        if($inbound){
            Assert-NetCrateLiveWire $inbound.Request
            $activation=Get-NetCratePairingRecord $Root pairing-activated
            $settings=Get-NetCrateWorkerPairingSettings $Root $inbound
            if($settings -and $activation -and $activation.RequestId -ceq $inbound.Request.RequestId){
                $endpoint=Read-NetCrateJson ([IO.Path]::Combine($Root,'endpoint.json'))
                if($endpoint.Address -cne $local -or $endpoint.SourceAddress -cne $inbound.Request.NetworkAddress){throw 'The manual connection uses another private address.'}
                $stage='RequestConfirmed';$code=$inbound.Request.DeviceCode
                $saved=Get-NetCratePairingRecord $Root manual-reply-saved
                $reply=Get-NetCratePairingRecord $Root outbound-reply
                if($saved -and $reply -and $saved.RequestId -ceq $inbound.Request.RequestId -and $reply.Reply.RequestId -ceq $saved.RequestId){
                    Assert-NetCrateLiveWire $reply.Reply
                    $stage='ReplySaved';$code=$reply.Reply.ConnectionCode
                }
            } else {
                $selection=Get-NetCratePairingRecord $Root manual-selection
                if($selection -and $selection.RequestId -ceq $inbound.Request.RequestId -and $selection.LocalAddress -ceq $local){$stage='RequestImported';$code=$inbound.Request.DeviceCode}
            }
        }
    } else {
        $outbound=Get-NetCratePairingRecord $Root outbound-request
        if($outbound){
            Assert-NetCrateLiveWire $outbound.Request
            if($outbound.Request.NetworkAddress -cne $local -or $outbound.Request.ProjectRoot -ine $Prepared.Folder -or (Get-NetCrateBackupMode $outbound.Request) -cne (Get-NetCrateBackupMode $Prepared)){throw 'The manual request differs from this installation.'}
            $stage='RequestSaved';$code=$outbound.Request.DeviceCode
            $pending=Get-NetCratePairingRecord $Root pending-reply
            if($pending -and $pending.Reply.RequestId -ceq $outbound.Request.RequestId){
                Assert-NetCrateLiveWire $pending.Reply
                Test-NetCrateConnectionPayload $pending.Payload $outbound.Request $pending.Reply
                Assert-NetCrateNetworkProof $Root $pending.Payload $outbound.Request
                $stage=if($outbound.Consumed){'Paired'}else{'ReplyImported'};$code=$pending.Reply.ConnectionCode
            }
        }
    }
    return @{Succeeded=$true;Code='ok';Message='Manual connection status refreshed.';PairingCode=$code;PairingStage=$stage}
}
function Get-NetCrateStableRequest($Root,$Folder,$LocalAddress,$Mode) {
    $old=Get-NetCratePairingRecord $Root outbound-request
    if($old) {
        Assert-NetCrateLiveWire $old.Request
        if($old.Consumed -or $old.Request.NetworkAddress -cne $LocalAddress -or $old.Request.ProjectRoot -cne $Folder -or (Get-NetCrateBackupMode $old.Request) -cne $Mode){throw 'This request belongs to another connection. Check the original settings.'}
        return $old.Request
    }
    return New-NetCratePairingRequest $Root $env:COMPUTERNAME $Folder $LocalAddress -BackupMode $Mode
}
function Receive-NetCrateStableRequest($Root,$Wire,$Mode,[string]$PeerAddress) {
    Assert-NetCrateLiveWire $Wire
    $selection=Get-NetCratePairingRecord $Root network-selection
    if(($PeerAddress -and $Wire.NetworkAddress -cne $PeerAddress) -or ($selection -and $Wire.NetworkAddress -cne $selection.PeerAddress)){throw 'The signed request uses a different peer address.'}
    $renewal=Get-NetCratePairingRecord $Root renewal-peer
    if($renewal){Assert-NetCrateRenewalPeer $renewal $Wire}
    $retired=Get-NetCratePairingRecord $Root retired-requests
    if($retired -and $Wire.RequestId -cin $retired.Ids){throw 'This request has been replaced.'}
    $old=Get-NetCratePairingRecord $Root inbound-request
    if($old) {
        if((ConvertTo-NetCrateCanonicalJson $old.Request) -ceq (ConvertTo-NetCrateCanonicalJson $Wire)){return $old.Request}
        if(-not $renewal -or $renewal.RequestId -cne $old.Request.RequestId -or $Wire.RequestId -ceq $old.Request.RequestId){
            throw 'A different request is already pending. Compare the existing identity or choose Start again.'
        }
        # The recipient may have confirmed before its old request expired and
        # uploaded its signed acknowledgment after the worker offered renewal.
        Assert-NetCrateWorkerCanRenew $Root $old
        # Import verifies the new signed request before atomically replacing
        # inbound-request. Invalid requests leave the old acknowledgment usable.
    }
    return Import-NetCratePairingRequest $Root $Wire -BackupMode $Mode
}
function Assert-NetCratePresentedCertificate([string]$Pem,[string]$PresentedDER) {
    $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($Pem)
    try {if([Convert]::ToBase64String($cert.RawData) -cne $PresentedDER){throw 'The encrypted reply identifies a different TLS certificate. Stop and verify both computers.'}}
    finally {$cert.Dispose()}
}
function Assert-NetCrateNetworkProof($Root,$Payload,$Request) {
    $selection=Get-NetCratePairingRecord $Root network-selection
    if($selection -and ($selection.PeerAddress -cne $Payload.Address -or $selection.LocalAddress -cne $Request.NetworkAddress)){throw 'The reply differs from the selected private peer.'}
    $proof=Get-NetCratePairingRecord $Root network-proof
    if($proof) {
        if($proof.RequestId -cne $Request.RequestId){throw 'The TLS evidence belongs to another request.'}
        if($proof.PeerAddress -cne $Payload.Address){throw 'The reply identifies another backup address.'}
        Assert-NetCratePresentedCertificate $Payload.Certificate $proof.PresentedDER
    }
}
function Receive-NetCrateStableReply($Root,$Wire) {
    $outbound=Unprotect-NetCrateRecord $Root outbound-request
    Assert-NetCrateLiveWire $outbound.Request
    Assert-NetCrateLiveWire $Wire
    $old=Get-NetCratePairingRecord $Root pending-reply
    if($old -and $old.Reply.RequestId -ceq $outbound.Request.RequestId){
        if((ConvertTo-NetCrateCanonicalJson $old.Reply) -cne (ConvertTo-NetCrateCanonicalJson $Wire)){throw 'This reply differs from the pending connection.'}
        if($outbound.Consumed){throw 'This reply was already used.'}
    } else {
        $null=Import-NetCratePairingReply $Root $Wire -ValidatePayload {param($payload,$request,$reply)
            Test-NetCrateConnectionPayload $payload $request $reply
            Assert-NetCrateNetworkProof $Root $payload $request
        }
        $old=Unprotect-NetCrateRecord $Root pending-reply
    }
    Test-NetCrateConnectionPayload $old.Payload $outbound.Request $old.Reply
    Assert-NetCrateNetworkProof $Root $old.Payload $outbound.Request
    return $old.Reply
}
function Assert-NetCrateRenewalPeer($Original,$Request) {
    foreach($field in @('RecipientId','PublicKey','SourceComputer','ProjectRoot','NetworkAddress')){
        if($Original.$field -cne $Request.$field){throw 'Renewal must use the original computer, signing key, project and address.'}
    }
    if((Get-NetCrateBackupMode $Original) -cne (Get-NetCrateBackupMode $Request)){throw 'Renewal must use the original backup mode.'}
}
function Get-NetCrateWorkerPairingSettings($Root,$Inbound) {
    $path=[IO.Path]::Combine($Root,'settings.json')
    if(-not $Inbound -or -not $Inbound.Confirmed -or -not [IO.File]::Exists($path)){return}
    $settings=Import-NetCrateSettings $path Worker
    $owner=Get-NetCrateOwner $Root
    $peer=Get-NetCratePairingRecord $Root runtime-peer
    if($owner.InstallationId -cne $settings.InstallationId -or -not $peer -or $peer.PublicKey -cne $Inbound.Request.PublicKey -or
        $settings.SourceComputer -cne $Inbound.Request.SourceComputer -or $settings.ActiveRoot -ine $Inbound.Request.ProjectRoot -or
        $settings.StateRoot -ine $Root){throw 'The saved runtime peer differs from this request.'}
    return $settings
}
function Test-NetCrateWorkerAcknowledgment($Root,$Settings,$Inbound) {
    $acks=@(Read-WorkflowRecords $Root $Settings pairing-ack $Settings.SourceComputer | Where-Object {
        $_.Version -eq 1 -and $_.Kind -ceq 'pairing-ack' -and $_.RequestId -ceq $Inbound.Request.RequestId -and
        $_.SourceId -ceq $Inbound.Request.RecipientId -and $_.ServerId -ceq $Settings.InstallationId
    })
    return $acks.Count -gt 0
}
function Assert-NetCrateWorkerCanRenew($Root,$Inbound) {
    $settings=Get-NetCrateWorkerPairingSettings $Root $Inbound
    $verified=Get-NetCratePairingRecord $Root network-verified
    if(-not $settings -or [IO.File]::Exists([IO.Path]::Combine([IO.Path]::GetDirectoryName($Root),'settings.json')) -or
        [datetimeoffset]$Inbound.Request.ExpiresUtc -gt [datetimeoffset]::UtcNow -or
        ($verified -and $verified.RequestId -ceq $Inbound.Request.RequestId) -or
        (Test-NetCrateWorkerAcknowledgment $Root $settings $Inbound)){
        throw 'This accepted connection is current or has already been acknowledged.'
    }
}
function Reset-NetCratePendingPairing($Root) {
    $keepConfirmed=$false
    $owner=Get-NetCrateOwner $Root
    if((Get-NetCratePairingRecord $Root paired-peer) -or (Get-NetCratePairingRecord $Root paired-secrets) -or [IO.File]::Exists([IO.Path]::Combine([IO.Path]::GetDirectoryName($Root),'settings.json'))){
        throw 'An established installation cannot be replaced during setup.'
    }
    $old=Get-NetCratePairingRecord $Root inbound-request
    if([IO.File]::Exists([IO.Path]::Combine($Root,'settings.json'))){
        $renewal=Get-NetCratePairingRecord $Root renewal-peer
        if($owner.Role -cne 'Worker' -or (-not $old -and -not $renewal)){throw 'There is no unfinished worker session to renew.'}
        if($old){
            if($renewal){Assert-NetCrateRenewalPeer $renewal $old.Request}
            $settings=Get-NetCrateWorkerPairingSettings $Root $old
            if($settings){
                Assert-NetCrateWorkerCanRenew $Root $old
                # Keep the old confirmed session available for a late ack. Only
                # a newly signed request from the same bound source can retire it.
                $keepConfirmed=$true
            } elseif(-not $renewal){throw 'The existing worker settings cannot be safely renewed.'}
        }
    }
    if($old){
        $retired=Get-NetCratePairingRecord $Root retired-requests
        $ids=@($old.Request.RequestId)
        if($retired){$ids+=@($retired.Ids | Where-Object {$_ -cne $old.Request.RequestId})}
        if($ids.Count -gt 512){throw 'Too many replaced pairing requests.'}
        Protect-NetCrateRecord $Root retired-requests @{Ids=$ids}
    }
    if($keepConfirmed){
        Protect-NetCrateRecord $Root renewal-peer $old.Request
        return
    }
    if(-not [IO.File]::Exists([IO.Path]::Combine($Root,'endpoint.json')) -and -not [IO.File]::Exists([IO.Path]::Combine($Root,'settings.json'))){[IO.File]::Delete([IO.Path]::Combine($Root,'Secrets','tls-identity.json'))}
    foreach($name in @('outbound-request','inbound-request','pending-reply','outbound-reply','network-proof','network-selection','manual-selection','manual-reply-saved','reply-delivered','network-verified','pairing-activated')){
        [IO.File]::Delete([IO.Path]::Combine($Root,'Secrets',$name+'.json'))
    }
}
