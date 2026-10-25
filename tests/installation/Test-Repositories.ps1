param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\src\shared\NetCrate.Credentials.psm1" -Force
Import-Module "$PSScriptRoot\..\..\install\NetCrate.Repositories.psm1" -Force
$engine=Join-Path $TestRoot 'Engine';$storage=Join-Path $TestRoot 'Storage'
New-Item -ItemType Directory -Path $storage -Force | Out-Null
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$storageAcl = [Security.AccessControl.DirectorySecurity]::new()
$storageAcl.SetAccessRuleProtection($true, $false)
$storageAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
$storageAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($storage), $storageAcl)
$null=New-NetCrateIdentity $engine ('9'*32) Worker
$first=Initialize-NetCrateRepositories -Root $engine -StorageRoot $storage -ResticExe $ResticExe
if($first.PrimaryId -cnotmatch '^[a-f0-9]{64}$' -or $first.ResultsId -cnotmatch '^[a-f0-9]{64}$' -or $first.PrimaryId -ceq $first.ResultsId){throw 'Separate repositories were not initialized.'}
$privateAcl = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($first.RepositoryRoot))
$allowed = @($privateAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object AccessControlType -EQ Allow)
if ($privateAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $user.Value -or -not $privateAcl.AreAccessRulesProtected -or
    $allowed.Count -ne 2 -or @($allowed | Where-Object { $_.IdentityReference.Value -cnotin @($user.Value, $system.Value) -or $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl }).Count) {
    throw 'The repository directory does not retain its private owner and access rules.'
}
$retry=Initialize-NetCrateRepositories -Root $engine -StorageRoot $storage -ResticExe $ResticExe
if($retry.PrimaryId -cne $first.PrimaryId -or $retry.ResultsId -cne $first.ResultsId){throw 'Retry replaced an existing repository.'}
$changed=Join-Path $TestRoot 'OtherStorage';New-Item -ItemType Directory -Path $changed | Out-Null
$rejected=$false;try{Initialize-NetCrateRepositories -Root $engine -StorageRoot $changed -ResticExe $ResticExe | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'An existing repository binding was moved silently.'}
$payload=Get-NetCrateRepositorySecrets -Root $engine
if(-not $payload.PrimaryPassword -or -not $payload.ResultsPassword -or $payload.PrimaryPassword -ceq $payload.ResultsPassword){throw 'Repository passwords were not independently generated.'}
$recovery=Join-Path $TestRoot 'Separate recovery copy.netcrate'
Export-NetCrateRecovery -Root $engine -LiteralPath $recovery
$saved=Get-Content -LiteralPath $recovery -Raw | ConvertFrom-Json
if($saved.Primary.Id -cne $first.PrimaryId -or $saved.Primary.Password -cne $payload.PrimaryPassword){throw 'Recovery material does not unlock the initialized repository.'}
$rejected=$false;try{Export-NetCrateRecovery -Root $engine -LiteralPath (Join-Path $engine 'bad-recovery.netcrate')}catch{$rejected=$true}
if(-not $rejected){throw 'Recovery was saved only inside the application folder.'}
Write-Output 'PASS: repository initialization from Modify-only storage, private access rules, preserved retry, binding checks and independent recovery export.'
