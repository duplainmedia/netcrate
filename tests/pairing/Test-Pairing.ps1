param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\src\shared\NetCrate.Pairing.psm1" -Force
$script:assertions = 0
function Assert($Value, $Message) { if (-not $Value) { throw $Message }; $script:assertions++ }
function Reject([scriptblock]$Action) { $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }; Assert $rejected 'Invalid pairing state was accepted.' }
$source = Join-Path $TestRoot 'Editing'
$server = Join-Path $TestRoot 'Server'
$other = Join-Path $TestRoot 'Other'
$null = New-NetCrateIdentity -Root $source -InstallationId ('1'*32) -Role Source
$null = New-NetCrateIdentity -Root $server -InstallationId ('2'*32) -Role Worker
$null = New-NetCrateIdentity -Root $other -InstallationId ('3'*32) -Role Source
$request = New-NetCratePairingRequest -Root $source -SourceComputer 'EDIT-PC' -ProjectRoot 'F:\Video Projects' -NetworkAddress '100.64.0.10'
$accepted = Import-NetCratePairingRequest -Root $server -Request $request
Assert ($accepted.DeviceCode -ceq $request.DeviceCode) 'The two computers display different editing device codes.'
$payload = [ordered]@{ PrimaryPassword='synthetic-primary-secret'; ResultsPassword='synthetic-results-secret'; TransportPassword='synthetic-transport-secret'; CertificateSHA256=('a'*64); PrimaryId=('b'*64); ResultsId=('c'*64); Endpoint='https://100.64.0.20:8200/'; WorkerComputer='BACKUP-PC' }
Reject { New-NetCratePairingReply -Root $server -Payload $payload }
Confirm-NetCratePairingRequest -Root $server -RequestId $request.RequestId -DeviceCode $accepted.DeviceCode
$reply = New-NetCratePairingReply -Root $server -Payload $payload
$wire = $reply | ConvertTo-Json -Depth 16
Assert (-not $wire.Contains('synthetic-primary-secret') -and -not $wire.Contains('synthetic-transport-secret')) 'The connection reply contains plaintext credentials.'
Reject { Import-NetCratePairingReply -Root $other -Reply $reply }
foreach ($field in @('Ciphertext', 'Tag', 'Signature', 'CertificateSHA256', 'ServerId', 'RequestId')) {
    $changed = $wire | ConvertFrom-Json
    if ($field -in @('CertificateSHA256', 'ServerId', 'RequestId')) { $changed.$field = '0' * $changed.$field.Length }
    else { $changed.$field = [Convert]::ToBase64String([byte[]]::new(48)) }
    Reject { Import-NetCratePairingReply -Root $source -Reply $changed }
}
Reject { Import-NetCratePairingReply -Root $source -Reply $reply -Now ([DateTime]::UtcNow.AddDays(2)) }
$pending = Import-NetCratePairingReply -Root $source -Reply $reply
Assert ($pending.ConnectionCode -ceq $reply.ConnectionCode) 'Connection codes differ.'
Reject { Get-NetCratePairedSecrets -Root $source }
Reject { Confirm-NetCratePairingReply -Root $source -ConnectionCode '0000 0000 0000 0000' }
$null = Confirm-NetCratePairingReply -Root $source -ConnectionCode $pending.ConnectionCode
$secrets = Get-NetCratePairedSecrets -Root $source
Assert ($secrets.PrimaryPassword -ceq 'synthetic-primary-secret') 'The recipient did not recover its repository password.'
Reject { Import-NetCratePairingReply -Root $source -Reply $reply }
$null = Confirm-NetCratePairingReply -Root $source -ConnectionCode $pending.ConnectionCode
Assert ((Get-NetCratePairedSecrets -Root $source).PrimaryPassword -ceq 'synthetic-primary-secret') 'Retrying local confirmation lost the established pairing.'
$bad = $wire | ConvertFrom-Json
$bad.Ciphertext = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('tampered'))
Reject { Import-NetCratePairingReply -Root $other -Reply $bad }
$again = New-NetCrateIdentity -Root $source -InstallationId ('1'*32) -Role Source
Assert ($again.PublicKey -ceq $request.PublicKey) 'Retry replaced the original recipient key.'
Reject { New-NetCrateIdentity -Root $source -InstallationId ('4'*32) -Role Source }
Reject { Import-NetCratePairingRequest -Root $server -Request $request -Now ([DateTime]::UtcNow.AddDays(2)) }
$ownerFile = Join-Path $other 'owner.json'
$ownerBefore = Get-Content -LiteralPath $ownerFile -Raw
$badOwner = $ownerBefore | ConvertFrom-Json
$badOwner.UserSid = 'S-1-5-21-100000000-200000000-300000000-1001'
$badOwner | ConvertTo-Json | Set-Content -LiteralPath $ownerFile -Encoding UTF8
Reject { New-NetCrateIdentity -Root $other -InstallationId ('3'*32) -Role Source }
[IO.File]::WriteAllText($ownerFile, $ownerBefore, [Text.UTF8Encoding]::new($false))
$protectedFile = Join-Path $other 'Secrets\identity-key.json'
$protectedBefore = Get-Content -LiteralPath $protectedFile -Raw
$badScope = $protectedBefore | ConvertFrom-Json
$badScope.Scope = 'LocalMachine'
$badScope | ConvertTo-Json | Set-Content -LiteralPath $protectedFile -Encoding UTF8
Reject { New-NetCrateIdentity -Root $other -InstallationId ('3'*32) -Role Source }
[IO.File]::WriteAllText($protectedFile, $protectedBefore, [Text.UTF8Encoding]::new($false))
Write-Output "PASS: $script:assertions recipient-bound pairing assertions."
