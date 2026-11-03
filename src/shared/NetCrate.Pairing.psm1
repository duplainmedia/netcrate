#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Protocol.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Credentials.psm1')

function Get-PairingUtc($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    return ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}

function Test-PairingExpiry($Record, [DateTime]$Now) {
    $created = Get-PairingUtc $Record.CreatedUtc
    $expires = Get-PairingUtc $Record.ExpiresUtc
    if ($created -gt $Now.ToUniversalTime().AddMinutes(10) -or $expires -le $Now.ToUniversalTime() -or
        $expires -le $created -or ($expires - $created).TotalHours -gt 24.01) { throw 'This connection file expired. Save a new file on the Editing Computer.' }
}

function Get-PairingKeyHash([string]$PublicKey) {
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($PublicKey)
        if ($rsa.KeySize -ne 3072) { throw 'The connection key size is unsupported.' }
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    } finally { $rsa.Dispose() }
}

function Format-PairingCode([string]$Hash) { return ((0..3 | ForEach-Object { $Hash.Substring($_ * 4, 4).ToUpperInvariant() }) -join ' ') }

function Get-PairingSignature([string]$Root, $Data) {
    $key = Unprotect-NetCrateRecord $Root 'identity-key'
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($key.PrivateKey)
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-NetCrateCanonicalJson $Data))
        return [Convert]::ToBase64String($rsa.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss))
    } finally { $rsa.Dispose() }
}

function Assert-PairingSignature([string]$PublicKey, $Data, [string]$Signature) {
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($PublicKey)
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-NetCrateCanonicalJson $Data))
        if (-not $rsa.VerifyData($bytes, [Convert]::FromBase64String($Signature), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)) {
            throw 'The connection file signature is invalid.'
        }
    } finally { $rsa.Dispose() }
}

function Get-PairingRequestData($Request) {
    $data = [ordered]@{ Version = $Request.Version; Kind = $Request.Kind; RequestId = $Request.RequestId; RecipientId = $Request.RecipientId
        SourceComputer = $Request.SourceComputer; ProjectRoot = $Request.ProjectRoot; NetworkAddress = $Request.NetworkAddress
        CreatedUtc = (Get-PairingUtc $Request.CreatedUtc).ToString('o'); ExpiresUtc = (Get-PairingUtc $Request.ExpiresUtc).ToString('o')
        PublicKey = $Request.PublicKey; DeviceCode = $Request.DeviceCode }
    if ($Request.Version -eq 2) { $data.BackupMode = $Request.BackupMode }
    return $data
}

function New-NetCratePairingRequest {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$SourceComputer,
        [Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$NetworkAddress, [DateTime]$Now = [DateTime]::UtcNow,
        [ValidateSet('Folder','Media')][string]$BackupMode)
    $owner = Get-NetCrateOwner $Root
    if ($owner.Role -cne 'Source') { throw 'Create the first connection file on the Editing Computer.' }
    if ($SourceComputer -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$') { throw 'The Editing Computer identity is invalid.' }
    $null = Assert-NetCrateLocalPath $ProjectRoot
    $address = $null
    if (-not [Net.IPAddress]::TryParse($NetworkAddress, [ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'The private network address is invalid.' }
    $identity = New-NetCrateIdentity $Root $owner.InstallationId $owner.Role
    $requestId = [guid]::NewGuid().ToString('N')
    $deviceCode = Format-PairingCode (Get-NetCrateHash ('device-v1|' + (Get-PairingKeyHash $identity.PublicKey) + '|' + $requestId))
    $data = [ordered]@{ Version = 1; Kind = 'netcrate-pair-request'; RequestId = $requestId; RecipientId = $owner.InstallationId
        SourceComputer = $SourceComputer; ProjectRoot = $ProjectRoot; NetworkAddress = $NetworkAddress
        CreatedUtc = $Now.ToUniversalTime().ToString('o'); ExpiresUtc = $Now.ToUniversalTime().AddHours(24).ToString('o')
        PublicKey = $identity.PublicKey; DeviceCode = $deviceCode }
    if ($BackupMode) { $data.Version = 2; $data.BackupMode = $BackupMode }
    $request = [pscustomobject]$data
    $request | Add-Member -NotePropertyName Signature -NotePropertyValue (Get-PairingSignature $Root $data)
    Protect-NetCrateRecord $Root 'outbound-request' @{ Request = $request; Consumed = $false }
    return $request
}

function Import-NetCratePairingRequest {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Request, [DateTime]$Now = [DateTime]::UtcNow,
        [ValidateSet('Folder','Media')][string]$BackupMode = 'Media')
    $owner = Get-NetCrateOwner $Root
    $fieldCount = if ($Request.Version -eq 2) { 13 } else { 12 }
    if ($owner.Role -cne 'Worker' -or @($Request.PSObject.Properties).Count -ne $fieldCount -or $Request.Version -notin @(1,2) -or
        $Request.Kind -cne 'netcrate-pair-request' -or $Request.RequestId -cnotmatch '^[a-f0-9]{32}$' -or
        $Request.RecipientId -cnotmatch '^[a-f0-9]{32}$' -or $Request.RecipientId -ceq $owner.InstallationId -or
        $Request.SourceComputer -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$') { throw 'Choose a connection file from your Editing Computer.' }
    $null = Assert-NetCrateLocalPath $Request.ProjectRoot
    Test-PairingExpiry $Request $Now
    $code = Format-PairingCode (Get-NetCrateHash ('device-v1|' + (Get-PairingKeyHash $Request.PublicKey) + '|' + $Request.RequestId))
    if ($code -cne $Request.DeviceCode) { throw 'The editing device code is invalid.' }
    Assert-PairingSignature $Request.PublicKey (Get-PairingRequestData $Request) $Request.Signature
    $requested = Get-NetCrateBackupMode $Request
    if ($requested -ceq 'Media' -and $BackupMode -ceq 'Folder') { throw 'This source requests media processing. Prepare the Backup Server in Media mode first.' }
    Protect-NetCrateRecord $Root 'inbound-request' @{ Request = $Request; Confirmed = $false; ServerBackupMode = $BackupMode }
    return [pscustomobject]@{ RequestId = $Request.RequestId; DeviceCode = $code; SourceComputer = $Request.SourceComputer }
}

function Confirm-NetCratePairingRequest {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][string]$DeviceCode)
    $pending = Unprotect-NetCrateRecord $Root 'inbound-request'
    Test-PairingExpiry $pending.Request ([DateTime]::UtcNow)
    if ($pending.Request.RequestId -cne $RequestId -or $pending.Request.DeviceCode -cne $DeviceCode) { throw 'The connection file changed. Compare the codes again.' }
    $pending.Confirmed = $true
    Protect-NetCrateRecord $Root 'inbound-request' $pending
}

function Get-PairingHeader($Reply) {
    $data = [ordered]@{ Version = $Reply.Version; Kind = $Reply.Kind; RequestId = $Reply.RequestId; RecipientId = $Reply.RecipientId
        ServerId = $Reply.ServerId; ServerPublicKey = $Reply.ServerPublicKey; CertificateSHA256 = $Reply.CertificateSHA256
        CreatedUtc = (Get-PairingUtc $Reply.CreatedUtc).ToString('o'); ExpiresUtc = (Get-PairingUtc $Reply.ExpiresUtc).ToString('o')
        ConnectionCode = $Reply.ConnectionCode }
    if ($Reply.Version -eq 2) { $data.BackupMode = $Reply.BackupMode; $data.ServerBackupMode = $Reply.ServerBackupMode }
    return $data
}

function Get-PairingSignedReply($Reply) {
    $data = Get-PairingHeader $Reply
    foreach ($name in @('EncryptedKey', 'Nonce', 'Ciphertext', 'Tag')) { $data[$name] = $Reply.$name }
    return $data
}

function Get-PairingConnectionCode($Request, [string]$ServerKey, [string]$CertificateHash) {
    return Format-PairingCode (Get-NetCrateHash ('connection-v1|' + (Get-PairingKeyHash $Request.PublicKey) + '|' +
        (Get-PairingKeyHash $ServerKey) + '|' + $Request.RequestId + '|' + $CertificateHash))
}

function New-NetCratePairingReply {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Payload, [DateTime]$Now = [DateTime]::UtcNow)
    $owner = Get-NetCrateOwner $Root
    $pending = Unprotect-NetCrateRecord $Root 'inbound-request'
    if ($owner.Role -cne 'Worker' -or $pending.Confirmed -ne $true) { throw 'Compare the editing device codes before saving the reply.' }
    Test-PairingExpiry $pending.Request $Now
    if ($Payload.CertificateSHA256 -cnotmatch '^[a-f0-9]{64}$') { throw 'The backup server certificate fingerprint is invalid.' }
    $identity = New-NetCrateIdentity $Root $owner.InstallationId $owner.Role
    $code = Get-PairingConnectionCode $pending.Request $identity.PublicKey $Payload.CertificateSHA256
    $header = [ordered]@{ Version = 1; Kind = 'netcrate-pair-reply'; RequestId = $pending.Request.RequestId; RecipientId = $pending.Request.RecipientId
        ServerId = $owner.InstallationId; ServerPublicKey = $identity.PublicKey; CertificateSHA256 = $Payload.CertificateSHA256
        CreatedUtc = $Now.ToUniversalTime().ToString('o'); ExpiresUtc = $Now.ToUniversalTime().AddHours(24).ToString('o'); ConnectionCode = $code }
    if ($pending.Request.Version -eq 2) {
        $requested = Get-NetCrateBackupMode $pending.Request
        $capability = if ($pending.PSObject.Properties.Name -contains 'ServerBackupMode') { $pending.ServerBackupMode } else { 'Media' }
        $header.Version = 2; $header.BackupMode = $requested; $header.ServerBackupMode = $capability
        # Copy caller payload; mode binding is always derived from the verified request.
        $Payload = $Payload | ConvertTo-Json -Depth 24 | ConvertFrom-Json
        $Payload | Add-Member -NotePropertyName BackupMode -NotePropertyValue $requested -Force
        $Payload | Add-Member -NotePropertyName ServerBackupMode -NotePropertyValue $capability -Force
    }
    $plaintext = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 24 -Compress))
    if ($plaintext.Length -gt 65536) { throw 'The connection payload is too large.' }
    $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $nonce = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
    $ciphertext = [byte[]]::new($plaintext.Length)
    $tag = [byte[]]::new(16)
    $aes = [Security.Cryptography.AesGcm]::new($key, 16)
    $recipient = [Security.Cryptography.RSA]::Create()
    try {
        $aes.Encrypt($nonce, $plaintext, $ciphertext, $tag, [Text.Encoding]::UTF8.GetBytes((ConvertTo-NetCrateCanonicalJson $header)))
        $recipient.ImportFromPem($pending.Request.PublicKey)
        $data = $header
        $data.EncryptedKey = [Convert]::ToBase64String($recipient.Encrypt($key, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
        $data.Nonce = [Convert]::ToBase64String($nonce)
        $data.Ciphertext = [Convert]::ToBase64String($ciphertext)
        $data.Tag = [Convert]::ToBase64String($tag)
        $reply = [pscustomobject]$data
        $reply | Add-Member -NotePropertyName Signature -NotePropertyValue (Get-PairingSignature $Root $data)
        Protect-NetCrateRecord $Root 'outbound-reply' @{ Reply = $reply; Request = $pending.Request }
        return $reply
    } finally { $aes.Dispose(); $recipient.Dispose(); [Array]::Clear($key, 0, $key.Length); [Array]::Clear($plaintext, 0, $plaintext.Length) }
}

function Import-NetCratePairingReply {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Reply, [DateTime]$Now = [DateTime]::UtcNow, [scriptblock]$ValidatePayload)
    $owner = Get-NetCrateOwner $Root
    $pending = Unprotect-NetCrateRecord $Root 'outbound-request'
    $fieldCount = if ($pending.Request.Version -eq 2) { 17 } else { 15 }
    if ($owner.Role -cne 'Source' -or $pending.Consumed -eq $true -or @($Reply.PSObject.Properties).Count -ne $fieldCount -or
        $Reply.Version -ne $pending.Request.Version -or $Reply.Kind -cne 'netcrate-pair-reply' -or $Reply.RecipientId -cne $owner.InstallationId -or
        $Reply.RequestId -cne $pending.Request.RequestId -or $Reply.ServerId -cnotmatch '^[a-f0-9]{32}$' -or
        $Reply.ServerId -ceq $owner.InstallationId -or $Reply.CertificateSHA256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Choose the reply made for this Editing Computer.' }
    Test-PairingExpiry $pending.Request $Now
    Test-PairingExpiry $Reply $Now
    $code = Get-PairingConnectionCode $pending.Request $Reply.ServerPublicKey $Reply.CertificateSHA256
    if ($code -cne $Reply.ConnectionCode) { throw 'The connection code is invalid.' }
    Assert-PairingSignature $Reply.ServerPublicKey (Get-PairingSignedReply $Reply) $Reply.Signature
    $keyRecord = Unprotect-NetCrateRecord $Root 'identity-key'
    $rsa = [Security.Cryptography.RSA]::Create()
    $key = $null; $plaintext = $null; $aes = $null
    try {
        $rsa.ImportFromPem($keyRecord.PrivateKey)
        $key = $rsa.Decrypt([Convert]::FromBase64String($Reply.EncryptedKey), [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        $ciphertext = [Convert]::FromBase64String($Reply.Ciphertext)
        if ($ciphertext.Length -gt 65536 -or $key.Length -ne 32) { throw 'The connection payload is invalid.' }
        $plaintext = [byte[]]::new($ciphertext.Length)
        $aes = [Security.Cryptography.AesGcm]::new($key, 16)
        $aes.Decrypt([Convert]::FromBase64String($Reply.Nonce), $ciphertext, [Convert]::FromBase64String($Reply.Tag), $plaintext,
            [Text.Encoding]::UTF8.GetBytes((ConvertTo-NetCrateCanonicalJson (Get-PairingHeader $Reply))))
        $payload = [Text.Encoding]::UTF8.GetString($plaintext) | ConvertFrom-Json
        if ($payload.CertificateSHA256 -cne $Reply.CertificateSHA256) { throw 'The encrypted certificate binding differs from the connection file.' }
        if ($Reply.Version -eq 2) {
            $requested = Get-NetCrateBackupMode $pending.Request
            $capability = Get-NetCrateBackupMode ([pscustomobject]@{ BackupMode = $Reply.ServerBackupMode })
            if ($payload.BackupMode -cne $requested -or $Reply.BackupMode -cne $requested -or $payload.ServerBackupMode -cne $capability -or ($requested -ceq 'Media' -and $capability -ceq 'Folder')) { throw 'The encrypted backup mode differs from the requested capability.' }
        }
        if($ValidatePayload){$null=& $ValidatePayload $payload $pending.Request $Reply}
        Protect-NetCrateRecord $Root 'pending-reply' @{ Payload = $payload; Reply = $Reply; Confirmed = $false }
        return [pscustomobject]@{ ConnectionCode = $code; ServerId = $Reply.ServerId; WorkerComputer = $payload.WorkerComputer }
    } finally {
        $rsa.Dispose(); if ($aes) { $aes.Dispose() }
        if ($key) { [Array]::Clear($key, 0, $key.Length) }; if ($plaintext) { [Array]::Clear($plaintext, 0, $plaintext.Length) }
    }
}

function Confirm-NetCratePairingReply {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ConnectionCode)
    $pending = Unprotect-NetCrateRecord $Root 'pending-reply'
    $request = Unprotect-NetCrateRecord $Root 'outbound-request'
    if ($pending.Reply.RequestId -cne $request.Request.RequestId -or $pending.Reply.ConnectionCode -cne $ConnectionCode) {
        throw 'Compare the current connection codes on both computers.'
    }
    if ($request.Consumed -eq $true) {
        $established = Unprotect-NetCrateRecord $Root 'paired-peer'
        if ($established.Reply.Signature -cne $pending.Reply.Signature) { throw 'The confirmed pairing differs from this reply.' }
        return [pscustomobject]@{ ServerId = $pending.Reply.ServerId; RequestId = $pending.Reply.RequestId }
    }
    $now=[datetime]::UtcNow
    Test-PairingExpiry $request.Request $now
    Test-PairingExpiry $pending.Reply $now
    Protect-NetCrateRecord $Root 'paired-secrets' $pending.Payload
    Protect-NetCrateRecord $Root 'paired-peer' @{ Reply = $pending.Reply; Request = $request.Request }
    $request.Consumed = $true
    Protect-NetCrateRecord $Root 'outbound-request' $request
    return [pscustomobject]@{ ServerId = $pending.Reply.ServerId; RequestId = $pending.Reply.RequestId }
}

function Get-NetCratePairedSecrets {
    param([Parameter(Mandatory)][string]$Root)
    return Unprotect-NetCrateRecord $Root 'paired-secrets'
}

Export-ModuleMember -Function New-NetCrateIdentity, New-NetCratePairingRequest, Import-NetCratePairingRequest, Confirm-NetCratePairingRequest,
    New-NetCratePairingReply, Import-NetCratePairingReply, Confirm-NetCratePairingReply, Get-NetCratePairedSecrets, Get-PairingSignature, Assert-PairingSignature
