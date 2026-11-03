#requires -Version 5.1
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Configuration.psm1')
function Get-NetCrateNetworkPlan {
 param([string]$Root,[string]$InstallationId)
 $rootPath=Assert-NetCrateLocalPath $Root
 $catalog=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dependencies.json'))|ConvertFrom-Json
 $package=$catalog.NetBird
 if($package.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $package.Version -cnotmatch '^[0-9]+(\.[0-9]+){1,3}$'){throw 'The network software catalog is invalid.'}
 $path=[IO.Path]::Combine($env:ProgramFiles,'NetBird','netbird-ui.exe')
 $installed=[IO.File]::Exists($path);$version='';$digest=''
 if($installed){$null=Assert-NetCrateLocalPath $path;$version=[Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion;$digest=(Get-FileHash -LiteralPath $path).Hash}
 $identity=@('network-v1',$rootPath,$InstallationId,$package.Version,$package.Url,$package.SHA256,[string]$installed,$path,$version,$digest)-join "`n"
 $algorithm=[Security.Cryptography.SHA256]::Create()
 try{$id=([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
 return [pscustomobject]@{PlanId=$id;Installed=$installed;Version=$(if($installed){$version}else{$package.Version});Source=$package.Url;License='BSD 3-Clause';Scope='System';Destination=$path}
}
Export-ModuleMember -Function Get-NetCrateNetworkPlan
