#requires -Version 5.1
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot '../../install/NetCrate.SetupLease.ps1'
if(-not (Test-Path $path)){throw 'The setup lease validator is missing.'}
. $path
$id='1'*32;$lease='2'*32;$program='C:\Temp\Tools\PowerShell\7.6.5\pwsh.exe'
$owner=[pscustomobject]@{InstallationId=$id;Lease=$lease;LocalAddress='100.64.0.1';PeerAddress='100.64.0.2';Program=$program}
$filter=[pscustomobject]@{LocalAddress=$owner.LocalAddress;RemoteAddress=$owner.PeerAddress;LocalPort='8201';RemotePort='Any';Protocol='TCP';Program=$program}
$rule=[pscustomobject]@{Name='NetCrate-Setup-'+$id;Group='NetCrate-Setup-'+$id;Description=(Get-NetCrateLeaseDescription $owner);Direction='Inbound';Action='Allow'}
function Get-NetFirewallAddressFilter {param([Parameter(ValueFromPipeline)]$InputObject) $filter}
function Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline)]$InputObject) $filter}
function Get-NetFirewallApplicationFilter {param([Parameter(ValueFromPipeline)]$InputObject) $filter}
function Assert($c,$m){if(-not $c){throw $m}}
Assert (Test-NetCrateOwnedSetupRule $rule $id $program) 'Matching stale narrow rule was not recognized.'
$filter.RemoteAddress='Any'
Assert (-not (Test-NetCrateOwnedSetupRule $rule $id $program)) 'Accepted a broad address.'
$filter.RemoteAddress=$owner.PeerAddress;$filter.LocalPort='8200'
Assert (-not (Test-NetCrateOwnedSetupRule $rule $id $program)) 'Accepted permanent rest-server rule.'
$filter.LocalPort='8201';$rule.Group='Other'
Assert (-not (Test-NetCrateOwnedSetupRule $rule $id $program)) 'Accepted an unrelated group.'
$rule.Group=$rule.Name;$rule.Description='Other'
Assert (-not (Test-NetCrateOwnedSetupRule $rule $id $program)) 'Accepted an unrelated description.'
Write-Output 'PASS simulated stale setup-rule ownership and filter validation.'
$rule.Description=Get-NetCrateLeaseDescription $owner
$script:simulated=$rule;$script:removed=0;$script:created=0
function Get-NetFirewallRule {param($Name,$ErrorAction) $script:simulated}
function Remove-NetFirewallRule {param($InputObject) $script:removed++;$script:simulated=$null}
function New-NetFirewallRule {param($Name,$DisplayName,$Group,$Description,$Direction,$Action,$Protocol,$LocalPort,$LocalAddress,$RemoteAddress,$Program,$Profile)
    if($LocalPort -ne 8201 -or $Protocol -cne 'TCP' -or $LocalAddress -cne $owner.LocalAddress -or $RemoteAddress -cne $owner.PeerAddress -or $Program -cne $owner.Program){throw 'Creation broadened the lease.'}
    $script:created++;$script:simulated=[pscustomobject]@{Name=$Name;Group=$Group;Description=$Description;Direction=$Direction;Action=$Action}
}
$new=$owner.PSObject.Copy();$new.Lease='3'*32
Open-NetCrateSetupRule $new
Assert ($script:created -eq 1 -and $script:removed -eq 1) 'Stale verified rule was not replaced.'
Close-NetCrateSetupRule $owner
Assert ($script:removed -eq 1) 'Previous guardian removed a newer lease.'
Close-NetCrateSetupRule $new
Assert ($script:removed -eq 2 -and -not $script:simulated) 'Guardian failed to retire its owned narrow rule.'
$script:simulated=$rule;$rule.Group='Unrelated'
try {Open-NetCrateSetupRule $owner;throw 'Expected rejection.'}catch{if($_.Exception.Message -eq 'Expected rejection.'){throw}}
Assert ($script:removed -eq 2 -and $script:created -eq 1) 'An unrelated conflicting rule was modified.'
Write-Output 'PASS simulated stale reconciliation, exact rule creation and ownership-checked cleanup.'
$rejectedImage=$false
try {Assert-NetCrateGuardianProgram ([Diagnostics.Process]::GetCurrentProcess())}catch{
    $rejectedImage=$_.Exception.Message -ceq 'The active helper program differs from its pinned release.'
}
if([IO.Path]::GetFileName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ieq 'powershell.exe'){
    Assert $rejectedImage 'Guardian failed to independently reject the public Windows interpreter as a setup helper.'
}
