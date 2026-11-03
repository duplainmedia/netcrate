#requires -Version 7.4
param([string]$TestRoot = (Join-Path $env:TEMP ('NC-pair-' + [guid]::NewGuid().ToString('N').Substring(0,8))))
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Choose a new disposable TestRoot.'}
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'install/NetCrate.Engine.psm1') -DisableNameChecking
Import-Module (Join-Path $repo 'src/shared/NetCrate.Credentials.psm1')
Import-Module (Join-Path $repo 'src/shared/NetCrate.Configuration.psm1')
Import-Module (Join-Path $repo 'src/shared/NetCrate.Pairing.psm1')
function Assert($condition,$reason){if(-not $condition){throw $reason}}
function Reject([scriptblock]$command){try{& $command | Out-Null}catch{return}; throw 'Unexpectedly accepted invalid input.'}
$source=Join-Path $TestRoot Source
$server=Join-Path $TestRoot Worker
$null=New-NetCrateIdentity $source ('1'*32) Source
$null=New-NetCrateIdentity $server ('2'*32) Worker
$state=[pscustomobject]@{Version=1;Role='EditingComputer';InstallationId='1'*32;BackupMode='Folder';Folder=(Join-Path $TestRoot Project);NetworkAddress='100.64.0.1';Path=''}
$mode='Folder'
$request=Get-NetCrateStableRequest $source $state.Folder $state.NetworkAddress $mode
$repeat=Get-NetCrateStableRequest $source $state.Folder $state.NetworkAddress $mode
Assert ($request.Signature -ceq $repeat.Signature) 'Retry created another signed request.'
Protect-NetCrateRecord $server network-selection @{LocalAddress='100.64.0.20';PeerAddress='100.64.0.15'}
Reject {Receive-NetCrateStableRequest $server $request $mode ''}
Protect-NetCrateRecord $server network-selection @{LocalAddress='100.64.0.20';PeerAddress=$state.NetworkAddress}
$null=Receive-NetCrateStableRequest $server $request $mode $state.NetworkAddress
Reject {Receive-NetCrateStableRequest $server $request $mode '100.64.0.2'}
$other=New-NetCratePairingRequest $source EDIT $state.Folder $state.NetworkAddress -BackupMode Folder
Reject {Receive-NetCrateStableRequest $server $other $mode $state.NetworkAddress}
Reject {Get-NetCrateStableReply $server}
Reject {Confirm-NetCratePairingRequest $server $request.RequestId '0000 0000 0000 0000'}
Confirm-NetCratePairingRequest $server $request.RequestId $request.DeviceCode
$null=Receive-NetCrateStableRequest $server $request $mode $state.NetworkAddress
Assert ((Unprotect-NetCrateRecord $server inbound-request).Confirmed) 'Retry reset device confirmation.'
$bad=$request | ConvertTo-Json | ConvertFrom-Json; $bad.SourceComputer='OTHER'
Reject {Receive-NetCrateStableRequest $server $bad $mode $state.NetworkAddress}
$tls=Get-NetCrateSetupTlsIdentity $server '100.64.0.20'
Assert (-not (Test-Path (Join-Path $server endpoint.json))) 'Setup TLS activated runtime credentials.'
Assert (-not (Test-Path (Join-Path $server TLS/server-key.pem))) 'Setup TLS wrote a plaintext private key.'
$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($tls.Certificate)
try {
 $pin=[Convert]::ToBase64String($cert.RawData)
 Assert-NetCratePresentedCertificate $tls.Certificate $pin
 Reject {Assert-NetCratePresentedCertificate $tls.Certificate ([Convert]::ToBase64String([byte[]]::new(48)))}
} finally {$cert.Dispose()}
Write-Output 'PASS stable requests, peer selection, retry, device confirmation and DER identity.'
Invoke-NetCratePairingLock $server {Reset-NetCratePendingPairing $server}
$replacementTls=Get-NetCrateSetupTlsIdentity $server '100.64.0.21'
Assert ($replacementTls.Certificate -cne $tls.Certificate) 'Explicit reset retained a provisional TLS identity on the old address.'
Write-NetCrateJson (Join-Path $server endpoint.json) @{Address='100.64.0.21'}
Invoke-NetCratePairingLock $server {Reset-NetCratePendingPairing $server}
Assert ((Get-NetCrateSetupTlsIdentity $server '100.64.0.21').Certificate -ceq $replacementTls.Certificate) 'Reset replaced a runtime endpoint certificate.'
