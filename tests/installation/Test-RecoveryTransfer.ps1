param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$repo/src/shared/NetCrate.Credentials.psm1" -Force
Import-Module "$repo/install/NetCrate.Repositories.psm1" -Force
$null=[IO.Directory]::CreateDirectory($TestRoot)
$engine=Join-Path $TestRoot Engine;$storage=Join-Path $TestRoot Storage
$null=[IO.Directory]::CreateDirectory($storage)
$null=New-NetCrateIdentity $engine ('8'*32) Worker
$binding=Initialize-NetCrateRepositories $engine $storage $ResticExe
if(-not (Get-Command Get-NetCrateRecoveryDocument -ErrorAction SilentlyContinue)){throw 'FAIL: no ephemeral recovery document export exists.'}
$document=Get-NetCrateRecoveryDocument $engine
$parsed=$document|ConvertFrom-Json
$secrets=Get-NetCrateRepositorySecrets $engine
if($parsed.Kind -cne 'netcrate-recovery' -or $parsed.Version -ne 1 -or $parsed.Primary.Id -cne $binding.PrimaryId -or $parsed.Results.Id -cne $binding.ResultsId -or $parsed.Primary.Password -cne $secrets.PrimaryPassword -or $parsed.Results.Password -cne $secrets.ResultsPassword){throw 'Ephemeral document is not the complete compatible recovery document.'}
if([IO.File]::Exists("$engine/recovery-export.json")){throw 'Copy claimed a saved recovery file.'}
$save=Join-Path $TestRoot 'Recovery on C.netcrate'
Export-NetCrateRecovery $engine $save
$saved=Get-Content -LiteralPath $save -Raw|ConvertFrom-Json
if($saved.Primary.Password -cne $parsed.Primary.Password -or $saved.Results.Password -cne $parsed.Results.Password){throw 'Saved and copied formats differ.'}
$before=[IO.File]::ReadAllBytes($save)
$rejected=$false;try{Export-NetCrateRecovery $engine $save}catch{$rejected=$true}
if(-not $rejected -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($save)) -cne [Convert]::ToBase64String($before)){throw 'An existing recovery destination was overwritten.'}
foreach($path in @($engine,$storage,"$engine/recovery.netcrate","$storage/recovery.netcrate",(Join-Path $repo 'forbidden-recovery.netcrate'))){
 $rejected=$false;try{Export-NetCrateRecovery $engine $path}catch{$rejected=$true}
 if(-not $rejected){throw 'Recovery destination overlap was accepted.'}
}
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($save))
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object AccessControlType -EQ Allow)
if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid -or $rules.Count -ne 2 -or @($rules|Where-Object {$_.IdentityReference.Value -cnotin @($sid,'S-1-5-18') -or $_.FileSystemRights -ne 'FullControl'}).Count){throw 'Recovery file does not have private permissions at creation.'}
# DPAPI secrets and the explicitly saved destination are the only intentional secret stores.
foreach($file in Get-ChildItem $engine -File -Recurse|Where-Object {$_.Directory.Name -cne 'Secrets'}){
 $text=[IO.File]::ReadAllText($file.FullName)
 if($text.Contains($secrets.PrimaryPassword) -or $text.Contains($secrets.ResultsPassword)){throw 'Recovery plaintext leaked into generic state or logs.'}
}
Write-Output 'PASS: complete ephemeral document, ordinary C-drive save, exact/descendant/repo overlap rejection, no overwrite, private ACL and no generic secret persistence.'
